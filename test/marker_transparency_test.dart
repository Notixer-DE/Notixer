import 'dart:io';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageGeometry;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat, PdfColor;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart'
    show PdfDocument, PdfEditor, PdfAnnotationEditing, PdfRect;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'marker keeps 35 percent alpha during live handoff, caching and zoom',
    (tester) async {
      final ink = InkController(InkDocument(generation: 'marker'));
      final live = LiveInk(ink), cache = InkPathCache();
      final key = GlobalKey();
      Widget page(double scale) => MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 256,
              height: 256,
              child: ColoredBox(
                color: Colors.white,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.center,
                  child: InkLayer(
                    controller: ink,
                    page: '1:0',
                    cache: cache,
                    live: live,
                    rasterScale: scale,
                    geometry: const PdfPageGeometry(
                      cropBox: PdfRect(0, 0, 256, 256),
                      rotation: 0,
                      viewSize: Size(256, 256),
                    ),
                    visible: const Rect.fromLTWH(0, 0, 1, 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<List<int>> pixel(int x, int y) async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final data = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        }))!;
        return [
          for (var c = 0; c < 3; c++) data.getUint8((y * 256 + x) * 4 + c),
        ];
      }

      void expectYellow(List<int> rgb) {
        expect(rgb[0], 255);
        expect(rgb[1], 255);
        expect(
          rgb[2],
          closeTo(166, 2),
          reason: 'A marker must not be opaque or double-composed',
        );
      }

      await tester.pumpWidget(page(1));
      live.begin('1:0', 0xffffff00, 16, opacity: .35);
      for (var i = 0; i < 180; i++) {
        live.add(30 + i.toDouble(), 128, .5);
      }
      await tester.pump();
      for (final x in [60, 92, 93, 94, 154, 155, 180]) {
        expectYellow(await pixel(x, 128));
      }
      live.finish();
      await tester.pump();
      expectYellow(await pixel(93, 128));
      for (var i = 0; i < 150 && cache.debugRasterBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expectYellow(await pixel(93, 128));
      await tester.pumpWidget(page(2));
      expectYellow(await pixel(128, 128));
      await tester.pumpWidget(const SizedBox());
      live.dispose();
      ink.dispose();
      cache.clear();
    },
  );

  test(
    'marker and text-highlight opacity survive save, reopen and independent PDF rasterization',
    () async {
      final directory = await Directory.systemTemp.createTemp('noter-marker-');
      final repo = LocalNotebookRepository(directory);
      try {
        final paper = pw.Document()
          ..addPage(
            pw.Page(
              pageFormat: const PdfPageFormat(256, 256),
              margin: pw.EdgeInsets.zero,
              build: (_) => pw.Stack(
                children: [
                  pw.Positioned(
                    left: 0,
                    top: 120,
                    child: pw.Container(
                      width: 256,
                      height: 16,
                      color: const PdfColor.fromInt(0xff000000),
                    ),
                  ),
                ],
              ),
            ),
          );
        final base = await paper.save();
        final document = PdfDocument.open(base);
        final ink = InkController(InkDocument(generation: 'export'));
        final live = LiveInk(ink);
        live.begin(inkPageId(document, 0), 0xffffff00, 18, opacity: .35);
        for (var i = 0; i < 180; i++) {
          live.add(30 + i.toDouble(), 128, .5);
        }
        live.finish();
        final note = await repo.create('Marker', base);
        await repo.saveWithInk(note, base, ink.snapshot());
        final reopened = LocalNotebookRepository(directory);
        final bytes = await reopened.load(note.id);
        final recovered = (await reopened.openInk(note.id)).$1;
        expect(recovered.strokes.first.color >> 24, 89);
        final exported = pdfWithInk(bytes, recovered);
        final pdf = PdfDocument.open(exported);
        expect(
          pdf.page(0).annotations.single.appearanceOpacity,
          closeTo(89 / 255, .001),
        );
        final editor = PdfEditor(pdf)
          ..addHighlight(
            0,
            const [PdfRect(30, 50, 210, 70)],
            color: 0xffff00,
            opacity: .35,
          );
        final file = File('${directory.path}/export.pdf');
        await file.writeAsBytes(editor.save());
        final rendered = await Process.run('pdftoppm', [
          '-r',
          '72',
          '-singlefile',
          '-png',
          file.path,
          '${directory.path}/page',
        ]);
        expect(rendered.exitCode, 0, reason: '${rendered.stderr}');
        final codec = await ui.instantiateImageCodec(
          await File('${directory.path}/page.png').readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        final data = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        List<int> pixel(int x, int y) => [
          for (var c = 0; c < 3; c++)
            data.getUint8((y * frame.image.width + x) * 4 + c),
        ];
        // Ink is alpha-composited over the black source rectangle, once per
        // physical stroke, including both internal chunk boundaries.
        for (final x in [60, 92, 93, 94, 154, 155, 180]) {
          final rgb = pixel(x, 128);
          expect(rgb[0], closeTo(89, 3));
          expect(rgb[1], closeTo(89, 3));
          expect(rgb[2], lessThan(3));
        }
        final highlighted = pixel(100, 196);
        expect(highlighted[0], 255);
        expect(highlighted[1], 255);
        expect(highlighted[2], closeTo(166, 3));
        frame.image.dispose();
        codec.dispose();
        live.dispose();
        ink.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
