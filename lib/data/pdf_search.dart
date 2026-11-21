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
  return Isolate.run(
    () => searchPdfPageTexts(
      extractPdfSearchPageTexts(PdfDocument.open(bytes)),
      term,
      limit: limit,
    ),
    debugName: 'noter:search-pdf',
  );
}

/// Lazily extract searchable page text, retaining blank pages for navigation.
Iterable<String> extractPdfSearchPageTexts(PdfDocument document) sync* {
  for (var page = 0; page < document.pageCount; page++) {
    yield PdfTextExtractor.extract(document, page).text;
  }
}

/// Use the PDF library's literal matching rules for both indexed and live text.
/// Geometry is unnecessary here because these results open at a page.
PdfSearchPageResult searchPdfPageTexts(
  Iterable<String> pages,
  String term, {
  required int limit,
}) {
  final hits = <PdfSearchHit>[];
  var hasText = false, page = 0;
  for (final source in pages) {
    hasText = hasText || source.trim().isNotEmpty;
    final text = PdfPageText(pageIndex: page, text: source, runs: const []);
    for (final match in text.findAll(term, caseSensitive: false)) {
      if (hits.length == limit) {
        return PdfSearchPageResult(hits, truncated: true, hasText: true);
      }
      final from = (match.start - 40).clamp(0, source.length);
      final to = (match.end + 60).clamp(0, source.length);
      hits.add(
        PdfSearchHit(
          page,
          '${from > 0 ? '… ' : ''}'
          '${source.substring(from, to).replaceAll(RegExp(r'\s+'), ' ')}'
          '${to < source.length ? ' …' : ''}',
        ),
      );
    }
    page++;
  }
  return PdfSearchPageResult(hits, truncated: false, hasText: hasText);
}
