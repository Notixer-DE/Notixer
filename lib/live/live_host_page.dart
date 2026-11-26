import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf_document/pdf_document.dart' show PdfDocument;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/ink.dart';
import '../data/catalog.dart';
import '../ui/editor_toolbar.dart' show drawingPalette;
import '../data/notebook.dart';
import '../data/paper.dart';
import '../editor/ink_gestures.dart';
import '../input/stylus_input.dart';
import '../sync/sync_controller.dart';
import '../ui/selection_transform_overlay.dart';
import 'live_canvas.dart';
import 'live_channel.dart';
import 'live_sessions.dart';

enum _CanvasTool { pen, marker, eraser, lasso }

class LiveHostPage extends StatefulWidget {
  const LiveHostPage({super.key, required this.repository, required this.sync});
  final LocalNotebookRepository repository;
  final SyncController sync;

  @override
  State<LiveHostPage> createState() => _LiveHostPageState();
}

class _LiveHostPageState extends State<LiveHostPage> {
  final _model = LiveCanvasModel();
  final _queue = Queue<Map<String, Object>>();
  Timer? _flush, _retry;
  WebSocketChannel? _socket;
  LiveChannel? _session;
  LiveSessions? _sharing;
  String? _error;
  String _status = 'Drawing locally';
  int _sequence = 0, _viewers = 0, _attempts = 0;
  int? _pointer;
  bool _fingerDrawing = false;
  bool _pressureSensitive = true;
  _CanvasTool? _contactTool;
  bool _sending = false, _busy = false, _leaving = false;
  int? _savedSequence;
  Notebook? _savedNote;
  _CanvasTool _tool = _CanvasTool.pen;
  final _lasso = <Offset>[];
  InkMoveGesture? _move;
  Offset? _lassoStart;
  bool _transforming = false, _invalidTransform = false;
  bool get _editingCanvas => _pointer != null || _transforming;

  Color _penColor = const Color(0xff17232c);
  Color _markerColor = const Color(0xfff4ca22);
  double _penWidth = 3, _markerWidth = 15;
  double _penOpacity = 1, _markerOpacity = 0x75 / 255;
  final _presetPressure = <_CanvasTool, bool>{};
  InkEraserGesture? _eraser;

  @override
  void initState() {
    super.initState();
    _model.onEvent = _enqueue;
    unawaited(widget.repository.catalog.load().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _eraser?.finish(cancel: true);
    _model.dispose();
    _flush?.cancel();
    _retry?.cancel();
    final socket = _socket;
    if (socket != null) unawaited(socket.sink.close());
    final session = _session;
    final sharing = _sharing;
    if (session != null && sharing != null) {
      unawaited(sharing.end(session.id).catchError((Object _) {}));
    }
    super.dispose();
  }

  void _input(PointerEvent event, Offset point) {
    if (event is PointerDownEvent) {
      if (_editingCanvas) return;
      _pointer = event.pointer;
      _contactTool = null;
    }
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointer = null;
      final cancel = event is PointerCancelEvent;
      if (_eraser case final gesture?) {
        _model.finishErase(gesture, cancel: cancel);
        _eraser = null;
      } else if (_contactTool == _CanvasTool.lasso) {
        _finishLasso(cancel: cancel);
      } else if (cancel) {
        _model.cancel();
      } else {
        _model.finish();
      }
      _contactTool = null;
      setState(() {});
      return;
    }
    if (event is! PointerDownEvent && event is! PointerMoveEvent) return;

    final tool = usesStylusEraser(event) ? _CanvasTool.eraser : _tool;
    if (_contactTool != tool) {
      if (_contactTool == _CanvasTool.lasso) _finishLasso(cancel: true);
      if (_eraser case final gesture?) {
        _model.finishErase(gesture, cancel: false);
        _eraser = null;
      }
      _model.finish();
      _contactTool = tool;
      _pressureSensitive =
          _presetPressure[tool] ??
          widget.repository.catalog.drawingPreferences.pressureSensitive(
            tool == _CanvasTool.marker ? 'highlight' : 'ink',
          );
      switch (tool) {
        case _CanvasTool.pen:
          _model.begin(
            _penColor.withValues(alpha: _penOpacity).toARGB32(),
            _penWidth,
          );
        case _CanvasTool.marker:
          _model.begin(
            _markerColor.withValues(alpha: _markerOpacity).toARGB32(),
            _markerWidth,
          );
        case _CanvasTool.eraser:
          _eraser = InkEraserGesture(
            _model.ink,
            LiveCanvasModel.page,
            11,
            wholeStroke:
                widget.repository.catalog.drawingPreferences.wholeStrokeEraser,
          );
        case _CanvasTool.lasso:
          break;
      }
      setState(() {});
    }
    if (tool == _CanvasTool.lasso) {
      _updateLasso(point);
    } else if (tool == _CanvasTool.eraser) {
      _eraser?.add(point);
    } else {
      _model.point(
        point.dx,
        point.dy,
        drawingPressure(event, sensitive: _pressureSensitive),
      );
      _flush ??= Timer(const Duration(milliseconds: 16), () {
        _flush = null;
        _model.flush();
      });
    }
  }

  void _updateLasso(Offset point) {
    final start = _lassoStart;
    if (start == null) {
      _lassoStart = point;
      if (_model.selectionBounds?.inflate(4).contains(point) == true) {
        _move = InkMoveGesture(_model.ink);
      } else {
        _model.ink.select([]);
        _lasso.add(point);
      }
    } else if (_move case final move?) {
      final bounds = _model.selectionBounds!;
      final offset = point - start;
      final delta = Offset(
        offset.dx.clamp(
          math.min(0.0, -bounds.left),
          math.max(0.0, PdfPageFormat.a4.width - bounds.right),
        ),
        offset.dy.clamp(
          math.min(0.0, -bounds.top),
          math.max(0.0, PdfPageFormat.a4.height - bounds.bottom),
        ),
      );
      if ((delta - move.delta).distance >= 1) move.update(delta);
    } else if (_lasso.length < 512 && (point - _lasso.last).distance >= 2) {
      _lasso.add(point);
    }
    setState(() {});
  }

  void _finishLasso({required bool cancel}) {
    if (_move case final move?) {
      _model.finishMove(move, cancel: cancel);
    } else if (!cancel) {
      _model.selectWithLasso(_lasso);
    }
    _move = null;
    _lasso.clear();
    _lassoStart = null;
  }

  Widget _selectionOverlay(
    Rect bounds,
    Offset Function(Offset) toLocal,
    Offset Function(Offset) toPage,
  ) => SelectionTransformOverlay(
    bounds: bounds,
    toLocal: toLocal,
    toPage: toPage,
    moveEnabled: false,
    onStart: () {
      if (_editingCanvas || _model.ink.selected.isEmpty) return;
      setState(() {
        _transforming = true;
        _invalidTransform = false;
        _move = InkMoveGesture(_model.ink);
      });
    },
    onUpdate: (value) {
      if (!_transforming) return;
      try {
        _move!.update(
          value.delta,
          origin: value.origin,
          scaleX: value.scaleX,
          scaleY: value.scaleY,
          rotation: value.rotation,
        );
        _invalidTransform = false;
      } on FormatException {
        _invalidTransform = true;
      } on ArgumentError {
        _invalidTransform = true;
      }
    },
    onFinish: (_, cancel) {
      if (!_transforming) return;
      final rejected = !cancel && _invalidTransform;
      try {
        _model.finishMove(_move!, cancel: cancel || rejected);
      } finally {
        setState(() {
          _transforming = false;
          _move = null;
        });
      }
      if (rejected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This selection is too large to resize that far.'),
          ),
        );
      }
    },
  );

  void _selectTool(_CanvasTool tool) => setState(() {
    _tool = tool;
    if (tool != _CanvasTool.lasso) _model.ink.select([]);
  });

  Future<void> _work(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() => _work(() async {
    final credentials = await widget.sync.liveCredentials();
    if (credentials == null) {
      throw const FormatException(
        'Connect a Notixer sync server in Settings first.',
      );
    }
    if (!mounted) return;
    final sharing = LiveSessions(credentials);
    final session = await sharing.start();
    if (!mounted) {
      await sharing.end(session.id);
      return;
    }
    _session = session;
    _sharing = sharing;
    _sequence = 0;
    _attempts = 0;
    await _connect(session, credentials.token);
  });

  Future<void> _connect(LiveChannel session, String token) async {
    if (!mounted || _session != session) return;
    setState(() => _status = 'Connecting…');
    try {
      final socket = await session.join('host', token);
      if (!mounted || _session != session) {
        await socket.sink.close();
        return;
      }
      _socket = socket;
      socket.stream.listen(
        (data) {
          if (!mounted || _socket != socket) return;
          if (data == 'ended' || data == 'denied') {
            _clear(data == 'ended' ? 'Session ended' : 'Session access denied');
            return;
          }
          if (data is! String) return;
          final Object? control;
          try {
            control = jsonDecode(data);
          } on FormatException {
            return;
          }
          if (control case {'viewers': final int viewers}) {
            setState(() {
              _viewers = viewers;
              _attempts = 0;
              _status = 'Live · $_viewers watching';
            });
            if (_viewers > 0) _enqueue(_model.snapshot());
          }
        },
        onError: (Object _) => _lost(session, socket),
        onDone: () => _lost(session, socket),
      );
    } catch (_) {
      _lost(session, null);
    }
  }

  void _lost(LiveChannel session, WebSocketChannel? socket) {
    if (!mounted || _session != session || _socket != socket) return;
    _socket = null;
    _viewers = 0;
    _queue.clear();
    if (socket != null) unawaited(socket.sink.close());
    if (++_attempts > 12) {
      unawaited(_stopSharing('Sharing disconnected · Drawing locally'));
      return;
    }
    setState(() => _status = 'Reconnecting…');
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      final token = _sharing?.credentials.token;
      if (token != null) unawaited(_connect(session, token));
    });
  }

  void _enqueue(Map<String, Object> event) {
    final socket = _socket;
    final session = _session;
    if (socket == null || session == null || _viewers == 0) return;
    if (_queue.length >= 128) {
      _queue.clear();
      _queue.add(_model.snapshot());
    } else {
      _queue.add(event);
    }
    if (!_sending) unawaited(_send());
  }

  Future<void> _send() async {
    _sending = true;
    try {
      while (_queue.isNotEmpty) {
        final session = _session;
        final socket = _socket;
        if (session == null || socket == null) break;
        final sequence = _sequence + 1;
        final bytes = await session.encode(_queue.removeFirst(), sequence);
        if (_socket == socket && _session == session) {
          socket.sink.add(bytes);
          _sequence = sequence;
        }
      }
    } catch (_) {
      _queue.clear();
      if (mounted) {
        setState(() => _error = 'The current canvas could not be sent.');
      }
    } finally {
      _sending = false;
    }
  }

  void _clear(String status) {
    _retry?.cancel();
    _queue.clear();
    final socket = _socket;
    _socket = null;
    _session = null;
    _sharing = null;
    _viewers = 0;
    if (socket != null) unawaited(socket.sink.close());
    if (mounted) setState(() => _status = status);
  }

  Future<void> _stop() =>
      _work(() => _stopSharing('Sharing ended · Drawing locally'));

  Future<void> _stopSharing(String status) async {
    final session = _session;
    final sharing = _sharing;
    if (session == null || sharing == null) return;
    _clear(status);
    try {
      await sharing.end(session.id);
    } catch (_) {
      if (mounted && _session == null) {
        setState(
          () => _error = 'The server did not confirm the end of sharing.',
        );
      }
    }
  }

  Future<void> _save() => _work(() async {
    final now = DateTime.now();
    final date = MaterialLocalizations.of(context).formatShortDate(now);
    final bytes = await createPaper('blank');
    final pdf = PdfDocument.open(bytes);
    final revision = _model.ink.sequence;
    _savedNote = await widget.repository.saveWithInk(
      _savedNote ??
          Notebook(
            id: LocalNotebookRepository.newId(),
            title: 'Live Canvas · $date',
            paper: 'blank',
            created: now,
            modified: now,
          ),
      bytes,
      _model.documentForPage(inkPageId(pdf, 0)),
    );
    _savedSequence = revision;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved to your library')));
    }
  });

  Future<void> _leave() async {
    if (_busy || _leaving || _editingCanvas) return;
    if (_session != null ||
        (_model.ink.index.strokes.isNotEmpty &&
            _savedSequence != _model.ink.sequence)) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Close Live Canvas?'),
          content: const Text(
            'Save your drawing to the library before leaving if you want to keep it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    _leaving = true;
    if (mounted) Navigator.pop(context);
  }

  void _setColor(bool marker, Color color) => setState(() {
    if (marker) {
      _markerColor = color;
    } else {
      _penColor = color;
    }
  });

  Future<void> _hexColor(bool marker, Color color) async {
    var hex = (color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0');
    final result = await showDialog<Color>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, update) {
          final parsed = RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)
              ? Color(0xff000000 | int.parse(hex, radix: 16))
              : null;
          return AlertDialog(
            title: const Text('Custom color'),
            content: TextFormField(
              initialValue: hex,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Color (hex)',
                prefixText: '#',
              ),
              onChanged: (value) => update(() => hex = value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: parsed == null
                    ? null
                    : () => Navigator.pop(context, parsed),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && result != null) _setColor(marker, result);
  }

  Widget _colorPicker() {
    final marker = _tool == _CanvasTool.marker;
    final current = marker ? _markerColor : _penColor;
    return PopupMenuButton<int>(
      tooltip: marker ? 'Highlighter color' : 'Pen color',
      enabled: !_editingCanvas,
      onSelected: (color) {
        if (color == -1) {
          unawaited(_hexColor(marker, current));
        } else {
          _setColor(marker, Color(color));
        }
      },
      icon: Icon(Icons.color_lens_outlined, color: current),
      itemBuilder: (_) => [
        for (final (label, color) in drawingPalette)
          PopupMenuItem(
            value: color,
            child: Row(
              children: [
                Icon(Icons.circle, color: Color(color), size: 18),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
        const PopupMenuItem(value: -1, child: Text('Custom color…')),
      ],
    );
  }

  void _applyPreset(PenPreset preset) {
    final marker = preset.tool == 'highlight';
    final tool = marker ? _CanvasTool.marker : _CanvasTool.pen;
    _selectTool(tool);
    setState(() {
      _presetPressure[tool] = preset.pressureSensitive;
      if (marker) {
        _markerColor = Color(preset.color);
        _markerWidth = preset.width;
        _markerOpacity = preset.opacity;
      } else {
        _penColor = Color(preset.color);
        _penWidth = preset.width;
        _penOpacity = preset.opacity;
      }
    });
  }

  Future<void> _editWidth({
    required bool marker,
    required double current,
  }) async {
    final form = GlobalKey<FormState>();
    final controller = TextEditingController(text: current.toString());
    var width = current;
    var opacity = marker ? _markerOpacity : _penOpacity;
    final route = DialogRoute<(double, double)>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, update) {
          void apply() {
            if (form.currentState!.validate()) {
              Navigator.pop(context, (width, opacity));
            }
          }

          return AlertDialog(
            scrollable: true,
            title: Text(marker ? 'Highlighter width' : 'Pen width'),
            content: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Stroke width',
                      suffixText: 'pt',
                    ),
                    onFieldSubmitted: (_) => apply(),
                    onChanged: (text) => update(
                      () => width =
                          double.tryParse(text.replaceAll(',', '.')) ?? width,
                    ),
                    validator: (text) {
                      final value = double.tryParse(
                        text?.trim().replaceAll(',', '.') ?? '',
                      );
                      if (value == null ||
                          !value.isFinite ||
                          value < .5 ||
                          value > 30) {
                        return 'Enter a width from 0.5 to 30 pt.';
                      }
                      width = value;
                      return null;
                    },
                  ),
                  Slider(
                    value: width.isFinite ? width.clamp(.5, 30) : .5,
                    min: .5,
                    max: 30,
                    onChanged: (value) => update(() {
                      width = value;
                      controller.text = value.toStringAsFixed(1);
                    }),
                  ),
                  Text('Opacity: ${(opacity * 100).round()} %'),
                  Slider(
                    value: opacity.clamp(.05, 1),
                    min: .05,
                    max: 1,
                    onChanged: (value) => update(() => opacity = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: apply, child: const Text('Apply')),
            ],
          );
        },
      ),
    );
    final result = await Navigator.of(context).push(route);
    unawaited(route.completed.then((_) => controller.dispose()));
    if (result == null || !mounted) return;
    setState(() {
      if (marker) {
        _markerWidth = result.$1;
        _markerOpacity = result.$2;
      } else {
        _penWidth = result.$1;
        _penOpacity = result.$2;
      }
    });
  }

  Widget _widthPicker() {
    final marker = _tool == _CanvasTool.marker;
    final width = marker ? _markerWidth : _penWidth;
    final value = width % 1 == 0 ? width.toStringAsFixed(0) : width.toString();
    return Tooltip(
      message: marker ? 'Highlighter width' : 'Pen width',
      child: TextButton.icon(
        onPressed: !_editingCanvas
            ? () => _editWidth(marker: marker, current: width)
            : null,
        icon: const Icon(Icons.line_weight),
        label: Text('$value pt'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Live Canvas'),
        leading: BackButton(onPressed: _leave),
        actions: [
          IconButton(
            tooltip: 'Save to library',
            onPressed:
                _busy || _editingCanvas || _model.ink.index.strokes.isEmpty
                ? null
                : _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_session == null)
                  FilledButton.icon(
                    onPressed: _busy ? null : _start,
                    icon: const Icon(Icons.cast),
                    label: const Text('Share live'),
                  )
                else
                  TextButton(
                    onPressed: _busy ? null : _stop,
                    child: const Text('Stop sharing'),
                  ),
                Text(_status),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              children: [
                for (final (tool, label, icon) in [
                  (_CanvasTool.pen, 'Pen', Icons.edit_outlined),
                  (_CanvasTool.marker, 'Highlighter', Icons.highlight_outlined),
                  (_CanvasTool.eraser, 'Eraser', Icons.auto_fix_off),
                  (_CanvasTool.lasso, 'Lasso selection', Icons.gesture),
                ])
                  IconButton(
                    tooltip: label,
                    isSelected: (_contactTool ?? _tool) == tool,
                    onPressed: _editingCanvas ? null : () => _selectTool(tool),
                    icon: Icon(icon),
                  ),
                if (_tool == _CanvasTool.pen ||
                    _tool == _CanvasTool.marker) ...[
                  _colorPicker(),
                  _widthPicker(),
                  ListenableBuilder(
                    listenable: widget.repository.catalog,
                    builder: (_, _) => PopupMenuButton<PenPreset>(
                      tooltip: 'Drawing presets',
                      enabled: !_editingCanvas,
                      onSelected: _applyPreset,
                      itemBuilder: (_) => [
                        for (final preset in widget.repository.catalog.presets)
                          if (preset.tool == 'ink' ||
                              preset.tool == 'highlight')
                            PopupMenuItem(
                              value: preset,
                              child: Text(preset.name),
                            ),
                      ],
                      icon: const Icon(Icons.bookmark_outline),
                    ),
                  ),
                ],
                if (_tool == _CanvasTool.lasso &&
                    _model.ink.selected.isNotEmpty)
                  IconButton(
                    tooltip: 'Delete selection',
                    onPressed: !_editingCanvas
                        ? () => setState(_model.deleteSelection)
                        : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                IconButton(
                  tooltip: _fingerDrawing
                      ? 'Disable finger drawing'
                      : 'Enable finger drawing',
                  isSelected: _fingerDrawing,
                  onPressed: _editingCanvas
                      ? null
                      : () => setState(() => _fingerDrawing = !_fingerDrawing),
                  icon: const Icon(Icons.touch_app_outlined),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Undo',
                  onPressed: !_editingCanvas && _model.canUndo
                      ? () => setState(_model.undo)
                      : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: !_editingCanvas && _model.canRedo
                      ? () => setState(_model.redo)
                      : null,
                  icon: const Icon(Icons.redo),
                ),
              ],
            ),
            Expanded(
              child: LiveCanvasSurface(
                model: _model,
                input: _input,
                fingerDrawing: _fingerDrawing,
                lasso: List.of(_lasso),
                selectionOverlay: _selectionOverlay,
                transforming: _transforming,
                selection: _model.selectionBounds?.shift(
                  _move?.delta ?? Offset.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
