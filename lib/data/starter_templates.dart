import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Generated locally, so the initial selection needs no assets or network.
Future<Uint8List> createStarterTemplate(String id) async {
  pw.Widget lines(double height) => pw.CustomPaint(
    size: PdfPoint(500, height),
    painter: (canvas, size) {
      canvas
        ..setStrokeColor(PdfColors.grey300)
        ..setLineWidth(.4);
      for (double y = 0; y < size.y; y += 22) {
        canvas
          ..moveTo(0, y)
          ..lineTo(size.x, y)
          ..strokePath();
      }
    },
  );
  pw.Widget section(String title, double height) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 12),
      lines(height),
      pw.SizedBox(height: 12),
    ],
  );
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) {
        switch (id) {
          case 'starter_cornell':
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Cornell notes',
                  style: const pw.TextStyle(fontSize: 22),
                ),
                pw.SizedBox(height: 16),
                pw.Text('Topic:                                      Date:'),
                pw.SizedBox(height: 24),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(child: section('Keywords / questions', 450)),
                    pw.SizedBox(width: 20),
                    pw.Expanded(flex: 3, child: section('Notes', 450)),
                  ],
                ),
                section('Summary', 100),
              ],
            );
          case 'starter_meeting':
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Meeting', style: const pw.TextStyle(fontSize: 22)),
                pw.SizedBox(height: 16),
                section('Topic / date / participants', 66),
                section('Agenda', 110),
                section('Notes', 220),
                section('Tasks / decisions / dates', 110),
              ],
            );
          case 'starter_week':
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Weekly planner',
                  style: const pw.TextStyle(fontSize: 22),
                ),
                pw.SizedBox(height: 16),
                pw.Text('Week of:'),
                pw.SizedBox(height: 20),
                for (final day in [
                  'Monday',
                  'Tuesday',
                  'Wednesday',
                  'Thursday',
                  'Friday',
                  'Saturday / Sunday',
                ])
                  section(day, 55),
              ],
            );
          default:
            throw const FormatException('Unknown starter template.');
        }
      },
    ),
  );
  return document.save();
}
