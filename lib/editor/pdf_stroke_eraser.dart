import 'dart:ui';
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfEditingController;
import 'package:pdf_document/pdf_document.dart';
import 'operations.dart' show inkPressures;

/// Remove physical InkList strokes, not every glyph in a grouped annotation.
class PdfWholeStrokeEraser {
  PdfWholeStrokeEraser(this.editing, this.page, this.radius)
    : revision = editing.revisionId,
      annotations = editing.document
          .page(page)
          .annotations
          .where(
            (a) =>
                (a.subtype == 'Ink' || a.subtype == 'Highlight') &&
                !a.isHidden &&
                editing.isAnnotationEditable(a),
          )
          .toList();
  final PdfEditingController editing;
  final int page, revision;
  final double radius;
  final List<PdfAnnotation> annotations;
  final _hit = <PdfAnnotation, Set<int>>{};
  Offset? _last;
  void add(Offset point) {
    final from = _last ?? point;
    _last = point;
    final region = Rect.fromPoints(from, point).inflate(radius);
    for (final annotation in annotations) {
      final rect = annotation.rect;
      if (!Rect.fromLTRB(
        rect.left,
        rect.bottom,
        rect.right,
        rect.top,
      ).overlaps(region)) {
        continue;
      }
      final strokes = annotation.inkList;
      if (strokes == null) {
        _hit[annotation] = {};
        continue;
      }
      // Reuse the PDF writer's exact swept-circle intersection rule. We only
      // inspect whether slicing would touch a stroke, never save its pieces.
      for (var i = 0; i < strokes.length; i++) {
        if (_hit[annotation]?.contains(i) == true) continue;
        if (pdfSliceInkStrokes(
              [strokes[i]],
              null,
              (from.dx, from.dy),
              (point.dx, point.dy),
              radius + (annotation.borderWidth ?? 2) / 2,
            ) !=
            null) {
          (_hit[annotation] ??= {}).add(i);
        }
      }
    }
  }

  void finish({bool cancel = false}) {
    if (cancel || _hit.isEmpty) return;
    if (editing.revisionId != revision) {
      throw StateError('The PDF changed while erasing.');
    }
    editing.apply((editor) {
      for (final entry in _hit.entries) {
        final annotation = entry.key, strokes = entry.key.inkList;
        final keep = strokes == null
            ? <int>[]
            : [
                for (var i = 0; i < strokes.length; i++)
                  if (!entry.value.contains(i)) i,
              ];
        final pressure = keep.isEmpty ? null : inkPressures(annotation);
        editor.removeAnnotation(page, annotation);
        if (keep.isNotEmpty) {
          editor.addInk(
            page,
            [for (final i in keep) strokes![i]],
            pressures: pressure == null
                ? null
                : [for (final i in keep) pressure[i]],
            color: annotation.color ?? 0,
            strokeWidth: annotation.borderWidth ?? 2,
            opacity: annotation.appearanceOpacity,
            author: annotation.author,
            contents: annotation.contents,
            name: annotation.name,
          );
        }
      }
    });
  }
}
