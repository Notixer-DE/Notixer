import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

class PdfSearchHit {
  const PdfSearchHit(this.pageIndex, this.snippet);
  final int pageIndex;
  final String snippet;
}

class PdfSearchPageResult {
  const PdfSearchPageResult(
    this.hits, {
    required this.truncated,
    this.hasText = false,
  });
  final List<PdfSearchHit> hits;
  final bool truncated, hasText;
}

/// Extract and match away from the UI isolate. Only one document is loaded by
/// the caller at a time; bound the returned snippets even for common queries.
Future<PdfSearchPageResult> searchPdf(
  Uint8List bytes,
  String query, {
  int limit = 500,
}) async {
  if (limit < 1) throw ArgumentError.value(limit, 'limit');
  final term = query.trim();
  if (term.isEmpty) {
    return const PdfSearchPageResult([], truncated: false);
  }
  return Isolate.run(() {
    final document = PdfDocument.open(bytes);
    final hits = <PdfSearchHit>[];
    var hasText = false;
    for (var page = 0; page < document.pageCount; page++) {
      final text = PdfTextExtractor.extract(document, page);
      hasText = hasText || text.text.trim().isNotEmpty;
      for (final match in text.findAll(term, caseSensitive: false)) {
        if (hits.length == limit) {
          return PdfSearchPageResult(hits, truncated: true, hasText: true);
        }
        final from = (match.start - 40).clamp(0, text.text.length);
        final to = (match.end + 60).clamp(0, text.text.length);
        hits.add(
          PdfSearchHit(
            page,
            '${from > 0 ? '… ' : ''}'
            '${text.text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ')}'
            '${to < text.text.length ? ' …' : ''}',
          ),
        );
      }
    }
    return PdfSearchPageResult(hits, truncated: false, hasText: hasText);
  });
}
