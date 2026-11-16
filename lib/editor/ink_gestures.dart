import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import '../data/ink.dart';
import 'package:pdf_document/pdf_document.dart' show pdfSliceInkStrokes;

double _distance(Offset p, Offset a, Offset b) {
  final v = b - a, length = v.distanceSquared;
  if (length < 1e-12) return (p - a).distance;
  final t = (((p - a).dx * v.dx + (p - a).dy * v.dy) / length).clamp(0.0, 1.0);
  return (p - (a + v * t)).distance;
}

double _segmentDistance(Offset a, Offset b, Offset c, Offset d) {
  final r = b - a, s = d - c;
  final cross = r.dx * s.dy - r.dy * s.dx;
  if (cross.abs() > 1e-12) {
    final v = c - a;
    final t = (v.dx * s.dy - v.dy * s.dx) / cross;
    final u = (v.dx * r.dy - v.dy * r.dx) / cross;
    if (t >= 0 && t <= 1 && u >= 0 && u <= 1) return 0;
  }
  return [
    _distance(a, c, d),
    _distance(b, c, d),
    _distance(c, a, b),
    _distance(d, a, b),
  ].reduce(math.min);
}

bool inkHitsSegment(InkStroke s, Offset a, Offset b, double radius) {
  final p = s.points;
  if (s.pointCount == 1) {
    return _distance(Offset(p[0], p[1]), a, b) <= radius + s.width;
  }
  for (var i = 3; i < p.length; i += 3) {
    if (_segmentDistance(
          Offset(p[i - 3], p[i - 2]),
          Offset(p[i], p[i + 1]),
          a,
          b,
        ) <=
        radius + s.width) {
      return true;
    }
  }
  return false;
}

/// Provisional remainders live in the overlay, not PDF revisions or the journal.
/// A complete eraser gesture lands as one durable/undoable edit.
class InkEraserGesture {
  InkEraserGesture(
    this.controller,
    this.page,
    this.radius, {
    this.wholeStroke = false,
  });
  final InkController controller;
  final String page;
  final double radius;
  final bool wholeStroke;
  final _original = <String, InkStroke>{}, _pieces = <String, InkStroke>{};
  Offset? _last;
  void add(Offset point) {
    final from = _last ?? point;
    _last = point;
    final rect = Rect.fromPoints(from, point).inflate(radius);
    final candidates = [
      ...controller.index
          .query(page, rect)
          .where((s) => !controller.hidden.contains(s.id)),
      ...controller.preview
          .query(page, rect)
          .where((s) => _pieces.containsKey(s.id)),
    ];
    for (final s in candidates) {
      if (_original.containsKey(s.id)) continue;
      if (!inkHitsSegment(s, from, point, radius)) continue;
      if (wholeStroke) {
        for (final part in controller.index.group(s.group)) {
          _original[part.id] = part;
          controller.hide(part, true);
        }
        continue;
      }
      final p = s.points;
      final sliced = pdfSliceInkStrokes(
        [
          [for (var i = 0; i < p.length; i += 3) (p[i], p[i + 1])],
        ],
        [
          [for (var i = 2; i < p.length; i += 3) p[i]],
        ],
        (from.dx, from.dy),
        (point.dx, point.dy),
        radius + s.width * .8,
      );
      if (sliced != null) {
        if (_pieces.remove(s.id) != null) {
          controller.clearPreview([s.id]);
        } else {
          _original[s.id] = s;
          controller.hide(s, true);
        }
        for (var i = 0; i < sliced.strokes.length; i++) {
          final points = sliced.strokes[i], pressures = sliced.pressures?[i];
          final atStart = points.first == (p[0], p[1]);
          final atEnd = points.last == (p[p.length - 3], p[p.length - 2]);
          final fragment = InkStroke(
            id: newInkId(),
            page: s.page,
            order: s.order,
            color: s.color,
            width: s.width,
            group: s.group,
            capStart: atStart ? s.capStart : true,
            capEnd: atEnd ? s.capEnd : true,
            startDirection: atStart ? s.startDirection : null,
            endDirection: atEnd ? s.endDirection : null,
            points: Float32List.fromList([
              for (var j = 0; j < points.length; j++) ...[
                points[j].$1,
                points[j].$2,
                pressures?[j] ?? .5,
              ],
            ]),
          );
          _pieces[fragment.id] = fragment;
          controller.showPreview(fragment);
        }
      }
    }
  }

  void finish({bool cancel = false}) {
    if (!cancel && _original.isNotEmpty) {
      controller.apply(
        InkEdit(
          add: _pieces.values.toList(),
          remove: _original.values.toList(),
        ),
      );
    }
    controller.clearPreview(_pieces.keys);
    for (final s in _original.values) {
      controller.hide(s, false);
    }
    _pieces.clear();
    _original.clear();
  }
}

class InkMoveGesture {
  InkMoveGesture(this.controller)
    : original = [for (final id in controller.selected) ?controller.index[id]] {
    for (final s in original) {
      controller.hide(s, true);
    }
    update(Offset.zero);
  }
  final InkController controller;
  final List<InkStroke> original;
  List<InkStroke> moved = [];
  Offset delta = Offset.zero;
  void update(Offset value) {
    delta = value;
    controller.clearPreview(moved.map((s) => s.id));
    moved = value == Offset.zero
        ? original
        : [for (final s in original) s.transform(delta: value)];
    for (final s in moved) {
      controller.showPreview(s);
    }
  }

  void finish({bool cancel = false}) {
    if (!cancel && delta != Offset.zero) {
      controller.apply(InkEdit(add: moved, remove: original));
      controller.select(moved.map((s) => s.id));
    }
    controller.clearPreview(moved.map((s) => s.id));
    for (final s in original) {
      controller.hide(s, false);
    }
  }
}
