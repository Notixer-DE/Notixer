import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfEditingController;
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_cos/pdf_cos.dart';
import '../data/notebook.dart';
import '../data/tapes.dart';
import '../data/ink_pdf_controller.dart';
import '../data/ink_pages.dart';
import '../data/ink.dart';
export '../data/tapes.dart' show tapeMarker, isTape;

/// Every page paste is a new learning task, including repeated pastes and
/// independent copies on two offline devices.
Uint8List freshTapeCopies(Uint8List bytes) => freshPageTapeIds(bytes);

void pasteNotebookPages(PdfEditingController editing, {int? at}) {
  if (editing is InkPdfController && editing.pasteEditablePages(at: at)) return;
  final clipboard = editing.pageClipboard;
  final bytes = clipboard.bytes;
  if (bytes == null) return;
  clipboard.setPages(freshTapeCopies(bytes), clipboard.pageCount);
  editing.pastePages(at: at);
}

/// Copy page content, not document-level outlines. Existing bookmarks keep
/// pointing at the original pages; duplication is one undoable transaction.
Future<void> duplicateNotebookPages(
  PdfEditingController editing,
  List<int> pages,
) async {
  if (pages.isEmpty) return;
  editing.finishInk();
  final sorted = pages.toSet().toList()..sort();
  if (editing is InkPdfController) {
    final revision = editing.revisionId;
    final copy = await editing.editablePages(sorted);
    if (editing.revisionId != revision) {
      throw StateError('The pages changed while copying.');
    }
    editing.insertEditablePages(copy, at: sorted.last + 1);
    return;
  }
  final source = PdfDocument.open(freshTapeCopies(editing.exportPages(sorted)));
  editing.insertPagesFrom(source, at: sorted.last + 1);
}

void addTape(
  PdfEditingController editing,
  int page,
  PdfRect rect, {
  int color = 0xF0C55B,
}) {
  editing.finishInk();
  editing.apply(
    (e) => e.addSquare(
      page,
      rect,
      strokeColor: null,
      strokeWidth: 0,
      fillColor: color,
      opacity: 0,
      contents: tapeMarker,
      name: LocalNotebookRepository.newId(),
    ),
  );
}

Uint8List exportPdf(PdfEditingController editing, {bool withTapes = false}) {
  editing.finishInk();
  return exportPdfBytes(
    Uint8List.fromList(editing.bytes),
    withTapes: withTapes,
  );
}

Uint8List exportPdfBytes(Uint8List bytes, {bool withTapes = false}) {
  final document = PdfDocument.open(bytes);
  final editor = PdfEditor(document);
  for (var p = 0; p < document.pageCount; p++) {
    final tapes = document.page(p).annotations.where(isTape).toList();
    for (final tape in tapes) {
      if (withTapes) {
        editor.restyleAnnotation(p, tape, opacity: 1);
      } else {
        editor.removeAnnotation(p, tape);
      }
    }
  }
  return editor.hasChanges ? editor.save() : bytes;
}

Future<Uint8List> exportPdfBytesAsync(Uint8List bytes) =>
    Isolate.run(() => exportPdfBytes(bytes), debugName: 'noter:export-pdf');

bool _inside(Offset p, List<Offset> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

bool _intersects(Offset a, Offset b, Offset c, Offset d) {
  double cross(Offset x, Offset y) => x.dx * y.dy - x.dy * y.dx;
  final r = b - a, s = d - c;
  final divisor = cross(r, s);
  if (divisor.abs() < 1e-9) return false;
  final t = cross(c - a, s) / divisor, u = cross(c - a, r) / divisor;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}

bool strokeHitsPolygon(List<(double, double)> stroke, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  if (stroke.any((p) => _inside(Offset(p.$1, p.$2), polygon))) return true;
  for (var s = 1; s < stroke.length; s++) {
    for (var p = 0; p < polygon.length; p++) {
      if (_intersects(
        Offset(stroke[s - 1].$1, stroke[s - 1].$2),
        Offset(stroke[s].$1, stroke[s].$2),
        polygon[p],
        polygon[(p + 1) % polygon.length],
      )) {
        return true;
      }
    }
  }
  return false;
}

/// Recover per-segment widths from our PDF appearances before separating
/// grouped strokes. This uses the same documented pressure/width relation as
/// pdf_document, so a lasso does not turn pressure ink into constant-width ink.
List<List<double>?>? inkPressures(PdfAnnotation annotation) {
  final strokes = annotation.inkList!;
  final baseWidth = annotation.borderWidth ?? 1;
  var form = annotation.normalAppearance;
  if (form == null || baseWidth <= 0) return null;
  final cos = annotation.document.cos;
  try {
    for (var depth = 0; depth < 4; depth++) {
      final ops = ContentStreamParser.parse(cos.decodeStreamData(form!));
      final draws = ops.where((o) => o.operator == 'Do').toList();
      if (draws.length == 1 && draws.single.operands.single is CosName) {
        final resources = cos.resolve(form.dictionary['Resources']);
        final objects = resources is CosDictionary
            ? cos.resolve(resources['XObject'])
            : null;
        final inner = objects is CosDictionary
            ? cos.resolve(
                objects[(draws.single.operands.single as CosName).value],
              )
            : null;
        if (inner is CosStream) {
          form = inner;
          continue;
        }
      }
      var width = baseWidth;
      final widths = <double>[];
      for (final op in ops) {
        if (op.operator == 'w') {
          final number = op.operands.single;
          if (number is CosReal) width = number.value;
          if (number is CosInteger) width = number.value.toDouble();
        }
        if (['l', 'c', 'v', 'y'].contains(op.operator)) widths.add(width);
      }
      if (widths.length !=
          strokes.fold<int>(
            0,
            (count, s) => count + math.max(1, s.length - 1),
          )) {
        return null;
      }
      var offset = 0;
      return [
        for (final stroke in strokes)
          (() {
            final segmentWidths = widths.sublist(
              offset,
              offset + math.max(1, stroke.length - 1),
            );
            offset += segmentWidths.length;
            if (segmentWidths.every((w) => (w - baseWidth).abs() < 0.001)) {
              return null;
            }
            final p = segmentWidths
                .map((w) => ((w / baseWidth - 0.4) / 1.2).clamp(0.0, 1.0))
                .toList();
            if (stroke.length > 1) {
              // Widths encode adjacent pressure averages, not point values.
              // Invert that recurrence within [0,1] so re-exporting untouched
              // strokes retains every segment's original visible width.
              var low = 0.0, high = 1.0, c = 0.0;
              final constants = [0.0];
              for (var i = 0; i < p.length; i++) {
                c = 2 * p[i] - c;
                constants.add(c);
                if ((i + 1).isEven) {
                  low = math.max(low, -c);
                  high = math.min(high, 1 - c);
                } else {
                  low = math.max(low, c - 1);
                  high = math.min(high, c);
                }
              }
              if (low <= high) {
                final first = p.first.clamp(low, high);
                return [
                  for (var i = 0; i < constants.length; i++)
                    ((i.isEven ? first : -first) + constants[i]).clamp(
                      0.0,
                      1.0,
                    ),
                ];
              }
            }
            return stroke.length == 1
                ? [p.first]
                : [
                    p.first,
                    for (var i = 1; i < p.length; i++) (p[i - 1] + p[i]) / 2,
                    p.last,
                  ];
          })(),
      ];
    }
  } catch (_) {
    return null;
  }
  return null;
}

int lassoSelect(
  PdfEditingController editing,
  int pageIndex,
  List<Offset> polygon,
) {
  if (polygon.length < 3) return 0;
  editing.finishInk();
  editing.clearAnnotationSelection();
  final chosen = <String>{};
  final annotations = List<PdfAnnotation>.of(
    editing.document.page(pageIndex).annotations,
  );
  editing.apply((editor) {
    for (final annotation in annotations) {
      if (!editing.isAnnotationEditable(annotation) || annotation.isHidden) {
        continue;
      }
      final strokes = annotation.inkList;
      if (strokes != null && strokes.isNotEmpty) {
        final selected = [
          for (var i = 0; i < strokes.length; i++)
            if (strokeHitsPolygon(strokes[i], polygon)) i,
        ];
        if (selected.isEmpty) continue;
        if (selected.length == strokes.length) {
          final name = annotation.name ?? LocalNotebookRepository.newId();
          if (annotation.name == null) {
            editor.setAnnotationName(pageIndex, annotation, name);
          }
          chosen.add(name);
          continue;
        }
        final pressures = inkPressures(annotation);
        editor.removeAnnotation(pageIndex, annotation);
        for (final selecting in [false, true]) {
          final indices = [
            for (var i = 0; i < strokes.length; i++)
              if (selected.contains(i) == selecting) i,
          ];
          final name = LocalNotebookRepository.newId();
          editor.addInk(
            pageIndex,
            [for (final i in indices) strokes[i]],
            pressures: pressures == null
                ? null
                : [for (final i in indices) pressures[i]],
            color: annotation.color ?? 0,
            strokeWidth: annotation.borderWidth ?? 2,
            opacity: annotation.appearanceOpacity,
            author: annotation.author,
            contents: annotation.contents,
            name: name,
          );
          if (selecting) chosen.add(name);
        }
      } else if (annotation.behavior.resizable) {
        final r = annotation.rect;
        if (!_inside(
          Offset((r.left + r.right) / 2, (r.bottom + r.top) / 2),
          polygon,
        )) {
          continue;
        }
        final name = annotation.name ?? LocalNotebookRepository.newId();
        if (annotation.name == null) {
          editor.setAnnotationName(pageIndex, annotation, name);
        }
        chosen.add(name);
      }
    }
  });
  final current = editing.document.page(pageIndex).annotations;
  return editing.selectAnnotationSlots([
    for (var i = 0; i < current.length; i++)
      if (chosen.contains(current[i].name)) (pageIndex, i),
  ]);
}

/// Transforms the complete mixed lasso selection about one shared origin.
/// PDF edits form one revision; the caller groups it with vector ink history.
void transformNotebookSelection(
  PdfEditingController editing,
  InkController ink, {
  double scale = 1,
  double rotation = 0,
  double scaleX = 1,
  double scaleY = 1,
  Offset delta = Offset.zero,
  Offset? anchor,
}) {
  if (![scale, scaleX, scaleY].every((v) => v.isFinite && v > 0) ||
      !rotation.isFinite ||
      !delta.dx.isFinite ||
      !delta.dy.isFinite ||
      (anchor != null && (!anchor.dx.isFinite || !anchor.dy.isFinite))) {
    throw ArgumentError('Invalid transformation.');
  }
  final slots = editing.selectedAnnotationSlots.toList();
  final annotations = [
    for (final slot in slots)
      (slot.$1, editing.document.page(slot.$1).annotations[slot.$2]),
  ];
  final strokes = [for (final id in ink.selected) ?ink.index[id]];
  final bounds = [
    for (final s in strokes) s.bounds,
    for (final (_, a) in annotations)
      Rect.fromLTRB(a.rect.left, a.rect.bottom, a.rect.right, a.rect.top),
  ];
  if (bounds.isEmpty) return;
  final origin = anchor ?? bounds.reduce((a, b) => a.expandToInclude(b)).center;
  final cosine = math.cos(rotation), sine = math.sin(rotation);
  Offset target(Offset point) {
    final x = (point.dx - origin.dx) * scale * scaleX;
    final y = (point.dy - origin.dy) * scale * scaleY;
    return origin +
        Offset(x * cosine - y * sine, x * sine + y * cosine) +
        delta;
  }

  final changedInk = [
    for (final stroke in strokes)
      stroke.transform(
        origin: origin,
        scale: scale,
        scaleX: scaleX,
        scaleY: scaleY,
        rotation: rotation,
        delta: delta,
      ),
  ];
  if (rotation != 0 &&
      annotations.any((entry) => entry.$2.normalAppearance == null)) {
    throw StateError('A selected PDF annotation has no rotatable appearance.');
  }
  editing.apply((editor) {
    for (final (page, annotation) in annotations) {
      final rect = annotation.rect;
      final center = Offset(
        (rect.left + rect.right) / 2,
        (rect.bottom + rect.top) / 2,
      );
      final next = target(center);
      if (scale != 1 || scaleX != 1 || scaleY != 1) {
        final quad = annotation.appearanceQuad;
        final width = quad == null
            ? rect.width
            : (Offset(quad[1].$1, quad[1].$2) - Offset(quad[0].$1, quad[0].$2))
                  .distance;
        final height = quad == null
            ? rect.height
            : (Offset(quad[3].$1, quad[3].$2) - Offset(quad[0].$1, quad[0].$2))
                  .distance;
        if (scaleX != scaleY) {
          editor.resizeAnnotation(
            page,
            annotation,
            PdfRect(
              center.dx - rect.width * scale * scaleX / 2,
              center.dy - rect.height * scale * scaleY / 2,
              center.dx + rect.width * scale * scaleX / 2,
              center.dy + rect.height * scale * scaleY / 2,
            ),
          );
        } else {
          editor.resizeAnnotationLocal(
            page,
            annotation,
            PdfRect(
              center.dx - width * scale * scaleX / 2,
              center.dy - height * scale * scaleY / 2,
              center.dx + width * scale * scaleX / 2,
              center.dy + height * scale * scaleY / 2,
            ),
          );
        }
      }
      if (rotation != 0) {
        editor.rotateAnnotation(
          page,
          PdfAnnotation.fromDict(annotation.document, annotation.dict),
          rotation * 180 / math.pi,
        );
      }
      editor.moveAnnotation(
        page,
        PdfAnnotation.fromDict(annotation.document, annotation.dict),
        next.dx - center.dx,
        next.dy - center.dy,
      );
    }
  });
  if (strokes.isNotEmpty) {
    ink.apply(InkEdit(add: changedInk, remove: strokes));
    ink.select(changedInk.map((stroke) => stroke.id));
  }
}
