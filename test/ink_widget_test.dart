import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart'
    show PdfPageGeometry, PdfEditTool;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect;
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:noter/ui/eraser_cursor.dart';

void main() {
  for (final color in [0xff123456, 0x80123456]) {
    testWidgets('ink has no tile seams at fractional zoom: $color', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      final ink = InkController(
        InkDocument(
          generation: 'seams',
          strokes: [
            InkStroke(
              id: 'wide',
              page: '1:0',
              order: 0,
              color: color,
              width: 18,
              points: Float32List.fromList([0, 100, .5, 512, 100, .5]),
            ),
          ],
        ),
      );
      final cache = InkPathCache();
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 529.92,
                height: 264.96,
                child: ColoredBox(
                  color: Colors.white,
                  child: InkLayer(
                    controller: ink,
                    page: '1:0',
                    cache: cache,
                    geometry: const PdfPageGeometry(
                      cropBox: PdfRect(0, 0, 512, 256),
                      rotation: 0,
                      viewSize: Size(529.92, 264.96),
                    ),
                    visible: const Rect.fromLTWH(0, 0, 1, 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> checkLine() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.25);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final y = (156 * 1.035 * 1.25).round();
          final expected = data.getUint32((y * image.width + 40) * 4);
          for (var x = 40; x < image.width - 40; x++) {
            expect(
              data.getUint32((y * image.width + x) * 4),
              expected,
              reason:
                  'Ink must stay uniform at pixel $x, including tile edges.',
            );
          }
          image.dispose();
        });
      }

      await checkLine();
      for (var i = 0; i < 250 && cache.debugRasterBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(cache.debugRasterBusy, isFalse);
      await tester.pump();
      await checkLine();
      await tester.pumpWidget(const SizedBox());
      ink.dispose();
      cache.clear();
    });
  }

  testWidgets(
    'adding ink rasterizes only the delta, not the dense tile history',
    (tester) async {
      final ink = InkController(
        InkDocument(
          generation: 'dense',
          strokes: [
            for (var i = 0; i < 1024; i++)
              InkStroke(
                id: 'old-$i',
                page: '1:0',
                order: i,
                color: 0xff000000,
                width: 1,
                points: Float32List.fromList([
                  for (var p = 0; p < 64; p++) ...[20 + p * .3, 80, .5],
                ]),
              ),
          ],
        ),
      );
      final cache = InkPathCache();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 256,
            height: 256,
            child: InkLayer(
              controller: ink,
              page: '1:0',
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
      );
      Future<void> rasterIdle() async {
        for (var i = 0; i < 250 && cache.debugRasterBusy; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(cache.debugRasterBusy, isFalse);
        await tester.pump();
      }

      await rasterIdle();
      final before = cache.debugVectorDraws;
      ink.apply(
        InkEdit(
          add: [
            InkStroke(
              id: 'new',
              page: '1:0',
              order: 1024,
              color: 0xff000000,
              width: 1,
              points: Float32List.fromList([20, 90, .5, 40, 90, .5]),
            ),
          ],
        ),
      );
      await tester.pump();
      await rasterIdle();
      expect(
        cache.debugVectorDraws - before,
        lessThan(10),
        reason: 'Do not replay the 1024 old strokes for a new glyph.',
      );
      await tester.pumpWidget(const SizedBox());
      ink.dispose();
      cache.clear();
    },
  );

  testWidgets(
    'ink remains visible through live handoff, undo and rotation without zoom',
    (tester) async {
      final controller = InkController(InkDocument(generation: 'widget'));
      final live = LiveInk(controller);
      final cache = InkPathCache(), key = GlobalKey();
      addTearDown(() {
        live.dispose();
        controller.dispose();
      });
      Widget page(int rotation) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 256,
                height: 256,
                child: ColoredBox(
                  color: Colors.white,
                  child: InkLayer(
                    controller: controller,
                    page: '1:0',
                    cache: cache,
                    live: live,
                    geometry: PdfPageGeometry(
                      cropBox: const PdfRect(0, 0, 256, 256),
                      rotation: rotation,
                      viewSize: const Size(256, 256),
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
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        });
        return [
          for (var c = 0; c < 3; c++) bytes!.getUint8((y * 256 + x) * 4 + c),
        ];
      }

      await tester.pumpWidget(page(0));
      live.begin('1:0', 0xff123456, 6);
      for (var i = 0; i < 150; i++) {
        live.add(20 + i.toDouble(), 100, .5);
      }
      await tester.pump();
      expect(await pixel(40, 156), [0x12, 0x34, 0x56]);
      final frozen = controller.preview.strokes.first;
      final path = cache.path(frozen);
      live.finish();
      await tester.pump();
      expect(await pixel(40, 156), [0x12, 0x34, 0x56]);
      expect(cache.path(frozen), same(path));
      final removed = controller.index.strokes.toList();
      controller.apply(InkEdit(remove: removed));
      await tester.pump();
      expect(await pixel(40, 156), [255, 255, 255]);
      controller.apply(InkEdit(add: removed));
      await tester.pump();
      expect(await pixel(40, 156), [0x12, 0x34, 0x56]);
      await tester.pumpWidget(page(90));
      expect(await pixel(100, 40), [0x12, 0x34, 0x56]);
      await tester.pumpWidget(page(0));
      live.begin('1:0', 0x80123456, 6);
      for (var i = 0; i < 150; i++) {
        live.add(20 + i.toDouble(), 200, .5);
      }
      live.finish();
      await tester.pump();
      expect(
        await pixel(82, 56),
        await pixel(84, 56),
        reason: 'Chunk boundaries must not double-compose translucent ink.',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the editor routes pressure ink and side-button erasing outside PDF revisions',
    (tester) async {
      final fixture = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'noter-ink-ui-',
        );
        final repo = LocalNotebookRepository(directory);
        final bytes = await createPaper('blank');
        return (
          directory,
          repo,
          bytes,
          await repo.create('Handschrift', bytes),
        );
      });
      final (directory, repo, bytes, note) = fixture!;
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(note: note, bytes: bytes, repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      final session = pane.widget.session;
      for (var i = 0; i < 150 && !session.toolsReady; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(session.toolsReady, isTrue);
      pane.toggleSinglePage();
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(pane.singlePage, isTrue);
      final before = Uint8List.fromList(pane.editing.bytes);
      final bounds = pane.viewer.globalRectOf(
        0,
        pane.editing.document.page(0).cropBox,
      )!;
      final start =
          bounds.topLeft + Offset(bounds.width * .2, bounds.height * .3);
      void feed(PointerEvent event) => session.eraser.handle(event, (e) {
        pane.handleCustomInput(e);
      });
      EraserContact? contact() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<EraserCursorPainter>()
          .single
          .contact
          .value;
      feed(
        PointerDownEvent(
          pointer: 91,
          kind: PointerDeviceKind.stylus,
          position: start,
          pressure: .3,
        ),
      );
      for (var i = 1; i < 180; i++) {
        feed(
          PointerMoveEvent(
            pointer: 91,
            kind: PointerDeviceKind.stylus,
            position: start + Offset(i * .3, 0),
            pressure: .3 + i / 400,
          ),
        );
        if (i % 30 == 0) await tester.pump(const Duration(milliseconds: 16));
      }
      expect(pane.editing.revisionId, 0);
      expect(session.ink.preview.strokes, isNotEmpty);
      feed(
        PointerUpEvent(
          pointer: 91,
          kind: PointerDeviceKind.stylus,
          position: start + const Offset(53.7, 0),
        ),
      );
      await tester.pump();
      expect(session.ink.index.strokes, isNotEmpty);
      expect(pane.editing.bytes, orderedEquals(before));
      pane.editing.undo();
      expect(session.ink.index.strokes, isEmpty);
      pane.editing.redo();
      expect(session.ink.index.strokes, isNotEmpty);
      // The temporary side-button eraser honors both policies and restores
      // the complete multi-chunk physical stroke in one undo.
      for (final whole in [true, false]) {
        await tester.runAsync(
          () => repo.catalog.drawingPreferences.setWholeStrokeEraser(whole),
        );
        feed(
          PointerDownEvent(
            pointer: 92,
            kind: PointerDeviceKind.stylus,
            position: start + const Offset(20, 0),
            buttons: kStylusContact | kPrimaryStylusButton,
          ),
        );
        if (whole) {
          final down = contact()!;
          expect(
            down.radius,
            closeTo(
              session.preferences.eraserRadius *
                  bounds.width /
                  pane.editing.document.page(0).cropBox.width,
              .01,
            ),
          );
          feed(
            PointerMoveEvent(
              pointer: 92,
              kind: PointerDeviceKind.stylus,
              position: start + const Offset(25, 0),
              buttons: kStylusContact | kPrimaryStylusButton,
            ),
          );
          expect(contact()!.center - down.center, const Offset(5, 0));
        }
        feed(
          PointerUpEvent(
            pointer: 92,
            kind: PointerDeviceKind.stylus,
            position: start + const Offset(20, 0),
          ),
        );
        expect(contact(), isNull);
        if (whole) {
          expect(session.ink.index.strokes, isEmpty);
          pane.editing.undo();
        }
        expect(session.ink.index.strokes, isNotEmpty);
      }
      expect(pane.editing.revisionId, 0);
      expect(session.ink.hidden, isEmpty);
      expect(session.ink.preview.strokes, isEmpty);
      await tester.runAsync(
        () => repo.catalog.drawingPreferences.setWholeStrokeEraser(true),
      );
      session.preferences.fingerDrawsInk = true;
      session.eraser.setBaseTool(PdfEditTool.eraser);
      for (final kind in [
        PointerDeviceKind.mouse,
        PointerDeviceKind.touch,
        PointerDeviceKind.invertedStylus,
      ]) {
        final position = start + const Offset(0, 100);
        feed(
          PointerDownEvent(
            pointer: 93,
            kind: kind,
            position: position,
            buttons: kPrimaryButton,
          ),
        );
        final down = contact()!;
        feed(
          PointerMoveEvent(
            pointer: 93,
            kind: kind,
            position: position + const Offset(40, 15),
            buttons: kPrimaryButton,
          ),
        );
        expect(contact()!.center - down.center, const Offset(40, 15));
        feed(
          PointerCancelEvent(
            pointer: 93,
            kind: kind,
            position: position + const Offset(40, 15),
          ),
        );
        expect(contact(), isNull);
      }
      session.eraser.setBaseTool(PdfEditTool.ink);
      for (var i = 0; i < 150 && !session.inkJournalCurrent; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.inkJournalCurrent, isTrue);
      final saving = session.save();
      for (var i = 0; i < 150 && (session.saving || session.dirty); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.saving, isFalse);
      expect(session.dirty, isFalse, reason: session.error);
      expect(await saving, isTrue, reason: session.error);
      final strokes = session.ink.index.strokes.length;
      pane.toggleSinglePage();
      await tester.pumpAndSettle();
      expect(session.ink.index.strokes.length, strokes);
      expect(pane.editing.bytes, orderedEquals(before));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await directory.delete(recursive: true);
      });
    },
  );
}
