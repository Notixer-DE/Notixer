import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf_document/pdf_document.dart' show PdfDocument;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/ink.dart';
import '../data/notebook.dart';
import '../data/paper.dart';
import '../sync/server_remote.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_crypto.dart';
import 'live_canvas.dart';
import 'live_channel.dart';

enum _CanvasTool { pen, marker, eraser }

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
  Uri? _invite;
  String? _token, _error;
  String _status = 'Drawing locally';
  int _sequence = 0, _viewers = 0, _attempts = 0;
  int? _pointer;
  bool _sending = false, _busy = false, _leaving = false;
  int? _savedSequence;
  Notebook? _savedNote;
  _CanvasTool _tool = _CanvasTool.pen;

  @override
  void initState() {
    super.initState();
    _model.onEvent = _enqueue;
  }

  @override
  void dispose() {
    _model.dispose();
    _flush?.cancel();
    _retry?.cancel();
    final socket = _socket;
    if (socket != null) unawaited(socket.sink.close());
    final session = _session;
    final token = _token;
    if (session != null && token != null) {
      unawaited(_endRemote(session, token).catchError((Object _) {}));
    }
    super.dispose();
  }

  void _input(PointerEvent event, Offset point) {
    if (event is PointerDownEvent && _pointer == null) {
      _pointer = event.pointer;
      switch (_tool) {
        case _CanvasTool.pen:
          _model.begin(0xff17232c, 3);
        case _CanvasTool.marker:
          _model.begin(0x75f4ca22, 15);
        case _CanvasTool.eraser:
          _model.erase(point, 11);
      }
    }
    if (event.pointer != _pointer) return;
    if (event is PointerDownEvent || event is PointerMoveEvent) {
      if (_tool == _CanvasTool.eraser) {
        if (event is PointerMoveEvent) _model.erase(point, 11);
        return;
      }
      final range = event.pressureMax - event.pressureMin;
      final pressure = range > 0
          ? (event.pressure - event.pressureMin) / range
          : 0.5;
      _model.point(point.dx, point.dy, pressure);
      _flush ??= Timer(const Duration(milliseconds: 16), () {
        _flush = null;
        _model.flush();
      });
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointer = null;
      if (event is PointerCancelEvent) {
        _model.cancel();
      } else {
        _model.finish();
      }
      setState(() {});
    }
  }

  Future<void> _work(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
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
    final server = validateServerUrl(credentials.server.toString());
    final response = await _request(
      'POST',
      server.resolve('/api/v1/live'),
      credentials.token,
    );
    if (response.statusCode != 200) {
      throw const FormatException(
        'The server could not start a Live Canvas session. Check that it is up to date.',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = body['id'] as String;
    final invite = body['invite'] as String;
    if (!liveTokenPattern.hasMatch(id) || !liveTokenPattern.hasMatch(invite)) {
      throw const FormatException('Invalid Live Canvas session.');
    }
    final key = await SyncCrypto.generateRecoveryKey();
    final session = LiveChannel(server, id, await SyncCrypto.create(key, id));
    if (!mounted) {
      await _endRemote(session, credentials.token);
      return;
    }
    _session = session;
    _token = credentials.token;
    _sequence = 0;
    _attempts = 0;
    _invite = server.replace(
      path: '/',
      fragment:
          'live?${Uri(queryParameters: {'room': id, 'invite': invite, 'key': key}).query}',
    );
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
          final control = jsonDecode(data);
          if (control is Map && control['viewers'] is int) {
            setState(() {
              _viewers = control['viewers'] as int;
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
      _clear('Sharing disconnected · Drawing locally');
      return;
    }
    setState(() => _status = 'Reconnecting…');
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      final token = _token;
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
        final bytes = await session.encode(_queue.removeFirst(), ++_sequence);
        if (_socket == socket) socket.sink.add(bytes);
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

  Future<http.Response> _request(String method, Uri url, String token) async {
    final client = http.Client();
    try {
      final request = http.Request(method, url)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token';
      return await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
  }

  Future<void> _endRemote(LiveChannel session, String token) async {
    final response = await _request(
      'DELETE',
      session.server.resolve('/api/v1/live/${session.id}'),
      token,
    );
    if (response.statusCode != 204) {
      throw const FormatException('Could not end the sharing session.');
    }
  }

  void _clear(String status) {
    _retry?.cancel();
    _queue.clear();
    final socket = _socket;
    _socket = null;
    _session = null;
    _token = null;
    _invite = null;
    if (socket != null) unawaited(socket.sink.close());
    if (mounted) setState(() => _status = status);
  }

  Future<void> _stop() => _work(() async {
    await _endRemote(_session!, _token!);
    _clear('Sharing ended · Drawing locally');
  });

  Future<void> _copyLink() async {
    final invite = _invite;
    if (invite == null) return;
    await Clipboard.setData(ClipboardData(text: invite.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Viewer link copied')));
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
    if (_busy || _leaving) return;
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
            onPressed: _busy || _model.ink.index.strokes.isEmpty ? null : _save,
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
                else ...[
                  OutlinedButton.icon(
                    onPressed: _copyLink,
                    icon: const Icon(Icons.link),
                    label: const Text('Copy viewer link'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _stop,
                    child: const Text('Stop sharing'),
                  ),
                ],
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
                  (_CanvasTool.pen, 'Pen', Icons.draw_outlined),
                  (_CanvasTool.marker, 'Marker', Icons.border_color_outlined),
                  (_CanvasTool.eraser, 'Eraser', Icons.auto_fix_off),
                ])
                  IconButton(
                    tooltip: label,
                    isSelected: _tool == tool,
                    onPressed: _pointer != null
                        ? null
                        : () => setState(() => _tool = tool),
                    icon: Icon(icon),
                  ),
                IconButton(
                  tooltip: 'Undo',
                  onPressed: _model.canUndo
                      ? () => setState(_model.undo)
                      : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: _model.canRedo
                      ? () => setState(_model.redo)
                      : null,
                  icon: const Icon(Icons.redo),
                ),
              ],
            ),
            Expanded(
              child: LiveCanvasSurface(model: _model, input: _input),
            ),
          ],
        ),
      ),
    ),
  );
}
