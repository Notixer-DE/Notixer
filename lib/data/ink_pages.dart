import 'dart:isolate';
import 'dart:typed_data';
import 'package:pdf_document/pdf_document.dart';
import 'ink.dart';
import 'tapes.dart';

/// Internal page interchange keeps ink editable. Only explicit PDF exports
/// flatten it into PDF annotations.
class InkPages {
  const InkPages(this.bytes, this.ink);
  final Uint8List bytes;
  final InkDocument ink;
}

Uint8List freshPageTapeIds(Uint8List bytes) {
  final document = PdfDocument.open(bytes);
  final editor = PdfEditor(document);
  for (final (p, page) in document.pages.indexed) {
    for (final tape in page.annotations.where(isTape)) {
      editor.setAnnotationName(p, tape, newInkId());
    }
  }
  return editor.hasChanges ? editor.save() : bytes;
}

List<InkStroke> copiedPageInk(
  InkDocument ink,
  PdfDocument source,
  List<int> indices,
  PdfDocument target, {
  int at = 0,
  int order = 0,
}) {
  final strokes = <InkStroke>[];
  for (var i = 0; i < indices.length; i++) {
    final sourcePage = inkPageId(source, indices[i]);
    final targetPage = inkPageId(target, at + i);
    final groups = <String, String>{};
    final selected = ink.strokes.where((s) => s.page == sourcePage).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final stroke in selected) {
      strokes.add(
        stroke.transform(
          id: newInkId(),
          page: targetPage,
          order: order++,
          group: groups.putIfAbsent(stroke.group, newInkId),
        ),
      );
    }
  }
  return strokes;
}

InkPages extractInkPages(Uint8List bytes, InkDocument ink, List<int> indices) {
  final source = PdfDocument.open(bytes);
  final extractedBytes = source.extractPages(indices);
  final result = freshPageTapeIds(extractedBytes);
  final target = PdfDocument.open(result);
  return InkPages(
    result,
    InkDocument(
      generation: newInkId(),
      strokes: copiedPageInk(ink, source, indices, target),
    ),
  );
}

Future<InkPages> extractInkPagesAsync(
  Uint8List bytes,
  InkDocument ink,
  List<int> indices,
) {
  final transfer = TransferableTypedData.fromList([bytes]);
  return Isolate.run(
    () => extractInkPages(transfer.materialize().asUint8List(), ink, indices),
    debugName: 'noter:copy-editable-pages',
  );
}
