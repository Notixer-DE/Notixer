import 'dart:typed_data';

import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageGeometry;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf_document/pdf_document.dart' show PdfRect;

import '../data/ink.dart';
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
    ink.onEdit = _record;
    try {
      live.finish();
    } finally {
      ink.onEdit = null;
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

class LiveCanvasSurface extends StatelessWidget {
  const LiveCanvasSurface({super.key, required this.model, this.input});
  final LiveCanvasModel model;
  final void Function(PointerEvent, Offset)? input;

  @override
  Widget build(BuildContext context) {
    final paper = PdfPageFormat.a4;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: AspectRatio(
          aspectRatio: paper.width / paper.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = PdfPageGeometry(
                cropBox: PdfRect(0, 0, paper.width, paper.height),
                rotation: 0,
                viewSize: constraints.biggest,
              );
              void event(PointerEvent event) {
                final position = event.localPosition / geometry.scale;
                input?.call(
                  event,
                  Offset(position.dx, paper.height - position.dy),
                );
              }

              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: event,
                onPointerMove: event,
                onPointerUp: event,
                onPointerCancel: event,
                child: ColoredBox(
                  color: Colors.white,
                  child: ClipRect(
                    child: InkLayer(
                      controller: model.ink,
                      page: LiveCanvasModel.page,
                      geometry: geometry,
                      visible: const Rect.fromLTWH(0, 0, 1, 1),
                      cache: model.cache,
                      live: model.live,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
