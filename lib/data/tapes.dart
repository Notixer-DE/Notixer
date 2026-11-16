import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pdf_document/pdf_document.dart';

const tapeMarker = 'Noter:Lernabdeckung:v1';
bool isTape(PdfAnnotation annotation) =>
    annotation.subtype == 'Square' && annotation.contents == tapeMarker;

class TapeTarget {
  const TapeTarget(this.id, this.page, this.index, this.rect);
  final String id;
  final int page, index;
  final PdfRect rect;
}

String? tapeIdentity(PdfDocument document, int page, int index) {
  final model = document.page(page);
  final annotation = model.annotations[index];
  final pageRef = document.cos.referenceTo(model.dict);
  final ref = document.cos.referenceTo(annotation.dict);
  if (pageRef == null || (ref == null && annotation.name == null)) return null;
  return sha256
      .convert(
        utf8.encode(
          '${pageRef.objectNumber}:${pageRef.generation}:'
          '${ref?.objectNumber}:${ref?.generation}:${annotation.name ?? ""}',
        ),
      )
      .toString();
}

/// No page indexes in durable IDs. Object references survive our incremental
/// saves, moves and undo. /NM also distinguishes objects recreated after undo.
/// Page/annotation copies receive fresh names before insertion.
List<TapeTarget> findTapes(PdfDocument document) {
  final result = <TapeTarget>[];
  for (final (pageIndex, page) in document.pages.indexed) {
    for (final (index, annotation) in page.annotations.indexed) {
      if (!isTape(annotation)) continue;
      final id = tapeIdentity(document, pageIndex, index);
      if (id == null) continue;
      result.add(TapeTarget(id, pageIndex, index, annotation.rect));
    }
  }
  return List.unmodifiable(result);
}

Future<List<TapeTarget>> scanTapes(Uint8List bytes) =>
    Isolate.run(() => findTapes(PdfDocument.open(bytes)));
