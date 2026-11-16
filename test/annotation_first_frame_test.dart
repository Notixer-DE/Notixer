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
  testWidgets(
    'newly visible dense annotations paint before asynchronous raster caches',
    (tester) async {
      final ink = InkController(
        InkDocument(
          generation: 'pages',
          strokes: [
            for (final page in ['1:0', '2:0'])
              for (var i = 0; i < 128; i++)
                InkStroke(
                  id: '$page-$i',
                  page: page,
                  order: i,
                  color: 0xff000000,
                  width: 4,
                  points: Float32List.fromList([20, 128, .5, 230, 128, .5]),
                ),
          ],
        ),
      );
      final cache = InkPathCache();
      final key = GlobalKey();
      for (final page in ['1:0', '2:0', '1:0']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 256,
                  height: 256,
                  child: ColoredBox(
                    color: Colors.white,
                    child: InkLayer(
                      controller: ink,
                      page: page,
                      cache: cache,
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
        // Read the first painted frame, without waiting for a raster worker or
        // zooming to wake the page. Rapid page changes must behave identically.
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final bytes = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        }))!;
        expect(
          bytes.getUint8((128 * 256 + 100) * 4),
          lessThan(10),
          reason: 'Missing first-frame annotations on $page',
        );
      }
      await tester.pumpWidget(const SizedBox());
      ink.dispose();
      cache.clear();
    },
  );
}
