import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageGeometry;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect;

void main() {
  testWidgets('outer pinch zoom rerasterizes thin ink at screen resolution', (
    tester,
  ) async {
    final ink = InkController(
      InkDocument(
        generation: 'zoom',
        strokes: [
          InkStroke(
            id: 'thin',
            page: '1:0',
            order: 0,
            color: 0xff000000,
            width: .125,
            points: Float32List.fromList([0, 254, .5, 16, 254, .5]),
          ),
        ],
      ),
    );
    final cache = InkPathCache();
    final key = GlobalKey();
    Widget page(double scale) => MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 64,
            height: 64,
            child: ClipRect(
              child: ColoredBox(
                color: Colors.white,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 256,
                    maxWidth: 256,
                    minHeight: 256,
                    maxHeight: 256,
                    child: InkLayer(
                      controller: ink,
                      page: '1:0',
                      cache: cache,
                      rasterScale: scale,
                      geometry: const PdfPageGeometry(
                        cropBox: PdfRect(0, 0, 256, 256),
                        rotation: 0,
                        viewSize: Size(256, 256),
                      ),
                      visible: Rect.fromLTWH(0, 0, 1 / scale, 1 / scale),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> idle() async {
      for (var i = 0; i < 200 && cache.debugRasterBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(cache.debugRasterBusy, isFalse);
      await tester.pump();
    }

    await tester.pumpWidget(page(1));
    await idle();
    final draws = cache.debugVectorDraws;
    await tester.pumpWidget(page(16));
    await idle();
    expect(cache.debugVectorDraws, greaterThan(draws));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixels = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!;
    }))!;
    int red(int x, int y) => pixels.getUint8((y * 64 + x) * 4);
    expect(red(32, 31), lessThan(30));
    expect(red(32, 32), lessThan(30));
    expect(red(32, 29), 255);
    expect(red(32, 34), 255);
    await tester.pumpWidget(const SizedBox());
    ink.dispose();
    cache.clear();
  });
}
