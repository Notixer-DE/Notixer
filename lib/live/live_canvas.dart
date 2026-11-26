import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageGeometry;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf_document/pdf_document.dart' show PdfRect;

import '../data/ink.dart';
import '../editor/ink_gestures.dart';
import '../editor/operations.dart' show strokeHitsPolygon;
import '../input/stylus_eraser.dart';
import '../ui/ink_layer.dart';

class LiveCanvasModel {
  static const page = '1:0';
  final ink = InkController(InkDocument(generation: newInkId()));
  final cache = InkPathCache();
  late final live = LiveInk(ink);
  final _points = <double>[];
  final _pending = <double>[];
  final _undo = <InkEdit>[];
  final _redo = <InkEdit>[];
  void Function(Map<String, Object>)? onEvent;
  bool _oversizedStroke = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void begin(int color, double width, {bool send = true}) {
    live.begin(page, color, width);
    _oversizedStroke = false;
    _points.clear();
    _pending.clear();
    if (send) onEvent?.call({'type': 'begin', 'color': color, 'width': width});
  }

  void point(double x, double y, double pressure, {bool send = true}) {
    if (!live.active || _oversizedStroke) return;
    final point = [
      x.clamp(0.0, PdfPageFormat.a4.width),
      y.clamp(0.0, PdfPageFormat.a4.height),
      pressure.clamp(0.0, 1.0),
    ];
    if (_points.length >= 24000) {
      _oversizedStroke = true;
      return;
    }
    live.add(point[0], point[1], point[2]);
    _points.addAll(point);
    if (send) _pending.addAll(point);
  }

  void flush() {
    if (_pending.isEmpty) return;
    final batch = List<double>.of(_pending);
    _pending.clear();
    onEvent?.call({'type': 'points', 'points': batch});
  }

  void _record(InkEdit edit) {
    _undo.add(edit);
    if (_undo.length > 80) _undo.removeAt(0);
    _redo.clear();
    onEvent?.call({'type': 'edit', ...edit.toJson()});
  }

  void finish() {
    if (!live.active) return;
    flush();
    try {
      _recordEdits(live.finish);
    } finally {
      _points.clear();
      onEvent?.call({'type': 'cancel'});
    }
  }

  void cancel({bool send = true}) {
    live.cancel();
    _points.clear();
    _pending.clear();
    if (send) onEvent?.call({'type': 'cancel'});
  }

  void erase(Offset point, double radius) {
    final area = Rect.fromCircle(center: point, radius: radius);
    final groups = ink.index
        .query(page, area)
        .where((stroke) => stroke.pointsAtMostDistance(point, radius))
        .map((stroke) => stroke.group)
        .toSet();
    if (groups.isEmpty) return;
    final edit = InkEdit(remove: groups.expand(ink.index.group));
    ink.apply(edit);
    _record(edit);
  }

  void _recordEdits(VoidCallback edit) {
    ink.onEdit = _record;
    try {
      edit();
    } finally {
      ink.onEdit = null;
    }
  }

  Rect? get selectionBounds {
    Rect? bounds;
    for (final id in ink.selected) {
      final stroke = ink.index[id];
      if (stroke != null) {
        bounds = bounds?.expandToInclude(stroke.bounds) ?? stroke.bounds;
      }
    }
    return bounds;
  }

  void selectWithLasso(List<Offset> polygon) {
    if (polygon.length < 3) {
      ink.select([]);
      return;
    }
    final bounds = polygon.fold(
      Rect.fromCircle(center: polygon.first, radius: .01),
      (rect, point) =>
          rect.expandToInclude(Rect.fromCircle(center: point, radius: .01)),
    );
    final groups = ink.index
        .query(page, bounds)
        .where((stroke) {
          return strokeHitsPolygon([
            for (var i = 0; i < stroke.points.length; i += 3)
              (stroke.points[i], stroke.points[i + 1]),
          ], polygon);
        })
        .map((stroke) => stroke.group)
        .toSet();
    ink.select([
      for (final group in groups)
        for (final stroke in ink.index.group(group)) stroke.id,
    ]);
  }

  void finishMove(InkMoveGesture gesture, {required bool cancel}) =>
      _recordEdits(() => gesture.finish(cancel: cancel));

  void deleteSelection() => _recordEdits(ink.deleteSelection);

  void undo() {
    if (!canUndo || live.active) return;
    final edit = _undo.removeLast();
    _redo.add(edit);
    ink.apply(edit.inverse);
    onEvent?.call({'type': 'edit', ...edit.inverse.toJson()});
  }

  void redo() {
    if (!canRedo || live.active) return;
    final edit = _redo.removeLast();
    _undo.add(edit);
    ink.apply(edit);
    onEvent?.call({'type': 'edit', ...edit.toJson()});
  }

  Map<String, Object> snapshot() {
    // The snapshot already contains buffered points at this position.
    _pending.clear();
    return {
      'type': 'snapshot',
      'add': [for (final stroke in ink.index.strokes) stroke.toJson()],
      if (live.active) ...{
        'color': live.color,
        'width': live.width,
        'points': List<double>.of(_points),
      },
    };
  }

  void receive(Map<String, dynamic> event) {
    void points() {
      final points = event['points'] as List;
      if (points.length % 3 != 0 || points.length > 24000) {
        throw const FormatException('Invalid Live Canvas points.');
      }
      for (var i = 0; i < points.length; i += 3) {
        point(
          (points[i] as num).toDouble(),
          (points[i + 1] as num).toDouble(),
          (points[i + 2] as num).toDouble(),
          send: false,
        );
      }
    }

    switch (event['type']) {
      case 'snapshot' || 'edit':
        final snapshot = event['type'] == 'snapshot';
        cancel(send: false);
        ink.apply(
          InkEdit(
            add: (event['add'] as List).map(
              (value) => InkStroke.fromJson(value as Map<String, dynamic>),
            ),
            remove: snapshot
                ? ink.index.strokes
                : [
                    for (final id in event['remove'] as List)
                      ?ink.index[id as String],
                  ],
          ),
        );
        if (snapshot && event.containsKey('points')) {
          begin(
            event['color'] as int,
            (event['width'] as num).toDouble(),
            send: false,
          );
          points();
        }
      case 'begin':
        begin(
          event['color'] as int,
          (event['width'] as num).toDouble(),
          send: false,
        );
      case 'points':
        points();
      case 'cancel':
        cancel(send: false);
      default:
        throw const FormatException('Unknown Live Canvas event.');
    }
  }

  InkDocument documentForPage(String actual) {
    final snapshot = ink.snapshot();
    return InkDocument(
      generation: snapshot.generation,
      strokes: snapshot.strokes.map(
        (stroke) => InkStroke(
          id: stroke.id,
          group: stroke.group,
          page: actual,
          order: stroke.order,
          color: stroke.color,
          width: stroke.width,
          points: Float32List.fromList(stroke.points),
          capStart: stroke.capStart,
          capEnd: stroke.capEnd,
          startDirection: stroke.startDirection,
          endDirection: stroke.endDirection,
        ),
      ),
    );
  }

  void dispose() {
    live.dispose();
    ink.dispose();
  }
}

extension on InkStroke {
  bool pointsAtMostDistance(Offset center, double radius) {
    for (var i = 0; i < points.length; i += 3) {
      final previous = i == 0 ? i : i - 3;
      final a = Offset(points[previous], points[previous + 1]);
      final b = Offset(points[i], points[i + 1]);
      final line = b - a;
      final delta = center - a;
      final t = line.distanceSquared == 0
          ? 0.0
          : ((line.dx * delta.dx + line.dy * delta.dy) / line.distanceSquared)
                .clamp(0.0, 1.0);
      if ((center - (a + line * t)).distance <= radius + width / 2) return true;
    }
    return false;
  }
}

class LiveCanvasSurface extends StatefulWidget {
  const LiveCanvasSurface({
    super.key,
    required this.model,
    this.input,
    this.fingerDrawing = false,
    this.lasso = const [],
    this.selection,
    this.selectionOverlay,
    this.transforming = false,
  });
  final LiveCanvasModel model;
  final void Function(PointerEvent, Offset)? input;
  final bool fingerDrawing;
  final List<Offset> lasso;
  final Rect? selection;
  final Widget Function(
    Rect bounds,
    Offset Function(Offset) toLocal,
    Offset Function(Offset) toPage,
  )?
  selectionOverlay;
  final bool transforming;

  @override
  State<LiveCanvasSurface> createState() => _LiveCanvasSurfaceState();
}

class _LiveCanvasSurfaceState extends State<LiveCanvasSurface> {
  static const _maximumZoom = 6.0;
  static const _paper = PdfPageFormat.a4;
  final _touches = <int, Offset>{};
  double _zoom = 1, _trackpadScale = 1;
  Offset _offset = Offset.zero;
  int? _inkPointer, _mousePanPointer;
  PointerDownEvent? _pendingTouch;
  bool _fingerInk = false, _touchNavigation = false;

  bool get _navigationLocked => _inkPointer != null || widget.transforming;

  Rect _pageRect(Rect fit, Size viewport) {
    final size = fit.size * _zoom;
    double edge(double desired, double space, double extent) => extent < space
        ? (space - extent) / 2
        : desired.clamp(space - extent, 0.0);
    return Offset(
          edge(fit.left + _offset.dx, viewport.width, size.width),
          edge(fit.top + _offset.dy, viewport.height, size.height),
        ) &
        size;
  }

  void _transform(
    Rect fit,
    Size viewport,
    Offset before,
    Offset after,
    double factor,
  ) {
    final rect = _pageRect(fit, viewport);
    final zoom = (_zoom * factor).clamp(1.0, _maximumZoom);
    if (zoom == _zoom && before == after) return;
    final origin = after - (before - rect.topLeft) * (zoom / _zoom);
    setState(() {
      _zoom = zoom;
      _offset = origin - fit.topLeft;
      _offset = _pageRect(fit, viewport).topLeft - fit.topLeft;
    });
  }

  void _deliver(PointerEvent event, Rect page) {
    final x = (event.localPosition.dx - page.left) / page.width * _paper.width;
    final y =
        (page.bottom - event.localPosition.dy) / page.height * _paper.height;
    widget.input?.call(event, Offset(x, y));
  }

  void _cancelFinger(Rect page) {
    if (!_fingerInk) return;
    final pointer = _inkPointer;
    if (_pendingTouch == null && pointer != null) {
      _deliver(PointerCancelEvent(pointer: pointer), page);
    }
    _inkPointer = null;
    _pendingTouch = null;
    _fingerInk = false;
  }

  (Offset, double) _touchFocus() {
    final points = _touches.values.take(2).toList();
    if (points.length == 1) return (points.first, 0);
    return ((points[0] + points[1]) / 2, (points[0] - points[1]).distance);
  }

  void _pointer(PointerEvent event, Rect fit, Size viewport) {
    final page = _pageRect(fit, viewport);
    final touch = event.kind == PointerDeviceKind.touch;
    final position = event.localPosition;
    if (event is PointerDownEvent) {
      if (widget.transforming) return;
      if (touch) {
        if (NoterBinding.stylusContactActive ||
            (_inkPointer != null && !_fingerInk)) {
          return;
        }
        _touches[event.pointer] = position;
        if (_touches.length > 1 ||
            _touchNavigation ||
            !widget.fingerDrawing ||
            widget.input == null) {
          _cancelFinger(page);
          _touchNavigation = true;
          return;
        }
        if (!page.contains(position)) return;
        _inkPointer = event.pointer;
        _fingerInk = true;
        _pendingTouch = event;
        return;
      }
      if (_inkPointer != null) {
        if (!_fingerInk || event.kind == PointerDeviceKind.mouse) return;
        _cancelFinger(page);
        _touchNavigation = _touches.isNotEmpty;
      }
      if (event.kind == PointerDeviceKind.mouse &&
          (widget.input == null || event.buttons != kPrimaryMouseButton)) {
        _mousePanPointer = event.pointer;
        return;
      }
      if (!page.contains(position) || widget.input == null) return;
      _inkPointer = event.pointer;
      _deliver(event, page);
      return;
    }

    if (event is PointerMoveEvent) {
      if (touch && _touches.containsKey(event.pointer)) {
        final (before, distance) = _touchFocus();
        _touches[event.pointer] = position;
        if (_touchNavigation &&
            !_navigationLocked &&
            !NoterBinding.stylusContactActive) {
          final (after, nextDistance) = _touchFocus();
          _transform(
            fit,
            viewport,
            before,
            after,
            distance > 1 ? nextDistance / distance : 1,
          );
          return;
        }
      }
      if (_mousePanPointer == event.pointer && !_navigationLocked) {
        _transform(fit, viewport, position - event.localDelta, position, 1);
        return;
      }
      if (_inkPointer != event.pointer) return;
      final pending = _pendingTouch;
      if (pending != null) {
        if ((position - pending.localPosition).distance < 6) return;
        _pendingTouch = null;
        _deliver(pending, page);
      }
      _deliver(event, page);
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_mousePanPointer == event.pointer) _mousePanPointer = null;
      if (touch) {
        _touches.remove(event.pointer);
        if (_touches.isEmpty) _touchNavigation = false;
      }
      if (_inkPointer != event.pointer) return;
      final pending = _pendingTouch;
      _inkPointer = null;
      _pendingTouch = null;
      _fingerInk = false;
      if (pending != null) {
        if (event is PointerCancelEvent) return;
        _deliver(pending, page);
      }
      _deliver(event, page);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      if (viewport.isEmpty) return const SizedBox.shrink();
      final scale = math.min(
        viewport.width / _paper.width,
        viewport.height / _paper.height,
      );
      final fit = Rect.fromCenter(
        center: viewport.center(Offset.zero),
        width: _paper.width * scale,
        height: _paper.height * scale,
      );
      final page = _pageRect(fit, viewport);
      final visible = page.intersect(Offset.zero & viewport);
      final geometry = PdfPageGeometry(
        cropBox: PdfRect(0, 0, _paper.width, _paper.height),
        rotation: 0,
        viewSize: page.size,
      );
      final center = viewport.center(Offset.zero);
      void pointer(PointerEvent event) => _pointer(event, fit, viewport);
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: pointer,
                onPointerMove: pointer,
                onPointerUp: pointer,
                onPointerCancel: pointer,
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent && !_navigationLocked) {
                    _transform(
                      fit,
                      viewport,
                      event.localPosition,
                      event.localPosition,
                      math.pow(1.002, -event.scrollDelta.dy).toDouble(),
                    );
                  }
                },
                onPointerPanZoomStart: (_) => _trackpadScale = 1,
                onPointerPanZoomUpdate: (event) {
                  if (_navigationLocked ||
                      !event.scale.isFinite ||
                      event.scale <= 0) {
                    return;
                  }
                  final focus = event.localPosition + event.localPan;
                  _transform(
                    fit,
                    viewport,
                    focus - event.localPanDelta,
                    focus,
                    event.scale / _trackpadScale,
                  );
                  _trackpadScale = event.scale;
                },
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: page,
                      child: ColoredBox(
                        color: Colors.white,
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              InkLayer(
                                controller: widget.model.ink,
                                page: LiveCanvasModel.page,
                                geometry: geometry,
                                visible: Rect.fromLTRB(
                                  (visible.left - page.left) / page.width,
                                  (visible.top - page.top) / page.height,
                                  (visible.right - page.left) / page.width,
                                  (visible.bottom - page.top) / page.height,
                                ),
                                continuous: true,
                                cache: widget.model.cache,
                                live: widget.model.live,
                              ),
                              if (widget.lasso.isNotEmpty)
                                IgnorePointer(
                                  child: CustomPaint(
                                    painter: _LassoPainter(
                                      geometry,
                                      widget.lasso,
                                      Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.selection case final bounds?
                when widget.selectionOverlay != null)
              Positioned.fill(
                child: widget.selectionOverlay!(
                  Rect.fromCenter(
                    center: bounds.center,
                    width: math.max(bounds.width, 112 / geometry.scale),
                    height: math.max(bounds.height, 112 / geometry.scale),
                  ),
                  (point) =>
                      geometry.toViewOffset(point.dx, point.dy) + page.topLeft,
                  (point) {
                    final (x, y) = geometry.toPagePoint(point - page.topLeft);
                    return Offset(x, y);
                  },
                ),
              ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const StadiumBorder(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Zoom out',
                      onPressed: _zoom <= 1 || _navigationLocked
                          ? null
                          : () => _transform(
                              fit,
                              viewport,
                              center,
                              center,
                              1 / 1.4,
                            ),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Fit page',
                      onPressed: _zoom == 1 || _navigationLocked
                          ? null
                          : () => _transform(
                              fit,
                              viewport,
                              center,
                              center,
                              1 / _zoom,
                            ),
                      icon: const Icon(Icons.fit_screen_outlined),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      onPressed: _zoom >= _maximumZoom || _navigationLocked
                          ? null
                          : () =>
                                _transform(fit, viewport, center, center, 1.4),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _LassoPainter extends CustomPainter {
  const _LassoPainter(this.geometry, this.points, this.color);
  final PdfPageGeometry geometry;
  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (points.length > 1) {
      final path = Path()
        ..addPolygon([
          for (final point in points) geometry.toViewOffset(point.dx, point.dy),
        ], true);
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .1));
      canvas.drawPath(path, outline);
    }
  }

  @override
  bool shouldRepaint(_LassoPainter old) =>
      old.points != points || old.geometry != geometry || old.color != color;
}
