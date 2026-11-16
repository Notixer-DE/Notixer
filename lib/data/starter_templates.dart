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
                  'Cornell-Notizen',
                  style: const pw.TextStyle(fontSize: 22),
                ),
                pw.SizedBox(height: 16),
                pw.Text('Thema:                                      Datum:'),
                pw.SizedBox(height: 24),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(child: section('Stichworte / Fragen', 450)),
                    pw.SizedBox(width: 20),
                    pw.Expanded(flex: 3, child: section('Notizen', 450)),
                  ],
                ),
                section('Zusammenfassung', 100),
              ],
            );
          case 'starter_meeting':
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Besprechung', style: const pw.TextStyle(fontSize: 22)),
                pw.SizedBox(height: 16),
                section('Thema / Datum / Teilnehmende', 66),
                section('Agenda', 110),
                section('Notizen', 220),
                section('Aufgaben / Entscheidungen / Termine', 110),
              ],
            );
          case 'starter_week':
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Wochenplanung',
                  style: const pw.TextStyle(fontSize: 22),
                ),
                pw.SizedBox(height: 16),
                pw.Text('Woche vom:'),
                pw.SizedBox(height: 20),
                for (final day in [
                  'Montag',
                  'Dienstag',
                  'Mittwoch',
                  'Donnerstag',
                  'Freitag',
                  'Samstag / Sonntag',
                ])
                  section(day, 55),
              ],
            );
          default:
            throw const FormatException('Unbekannte Startvorlage.');
        }
      },
    ),
  );
  return document.save();
}
