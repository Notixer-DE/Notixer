import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> createPaper(
  String pattern, {
  int pages = 1,
  int lineColor = 0xDCE4EC,
}) async {
  if (lineColor < 0 || lineColor > 0xFFFFFF) {
    throw ArgumentError.value(lineColor, 'lineColor');
  }
  final doc = pw.Document();
  for (var page = 0; page < pages; page++) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.CustomPaint(
          size: PdfPoint(PdfPageFormat.a4.width, PdfPageFormat.a4.height),
          painter: (canvas, size) {
            if (pattern == 'blank') return;
            canvas
              ..setStrokeColor(PdfColor.fromInt(0xFF000000 | lineColor))
              ..setLineWidth(0.4);
            final step = pattern == 'grid' ? 14.17 : 22.68;
            for (double y = 36; y < size.y - 24; y += step) {
              canvas
                ..moveTo(24, y)
                ..lineTo(size.x - 24, y)
                ..strokePath();
            }
            if (pattern == 'grid') {
              for (double x = 24; x < size.x - 24; x += step) {
                canvas
                  ..moveTo(x, 24)
                  ..lineTo(x, size.y - 24)
                  ..strokePath();
              }
            }
          },
        ),
      ),
    );
  }
  return doc.save();
}
