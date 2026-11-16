import 'dart:io';
import 'dart:ui' show GestureSettings;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/input/stylus_eraser.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';

void main() {
  test('touch replay requires the owning pane and never replays a palm', () {
    for (final palm in [false, true]) {
      final replay = CapturedTouchReplay();
      final forwarded = <PointerEvent>[];
      var handled = true;
      int? requested;
      void route(PointerEvent event) => replay.route(
        event,
        intercept: (_) => handled,
        forward: forwarded.add,
        replayPointer: () => requested,
        stylusActive: palm,
      );
      route(const PointerDownEvent(pointer: 1, kind: PointerDeviceKind.touch));
      route(
        const PointerMoveEvent(
          pointer: 1,
          kind: PointerDeviceKind.touch,
          position: Offset(30, 40),
          delta: Offset(30, 40),
        ),
      );
      handled = false;
      route(const PointerDownEvent(pointer: 2, kind: PointerDeviceKind.touch));
      expect(forwarded.map((e) => e.pointer), [2]);
      requested = 1;
      route(const PointerDownEvent(pointer: 3, kind: PointerDeviceKind.touch));
      expect(forwarded.map((e) => e.pointer), palm ? [2, 3] : [2, 1, 3]);
      if (!palm) expect(forwarded[1].position, const Offset(30, 40));
    }
  });

  for (final single in [false, true]) {
    testWidgets('Android touch pans, pinches and writes (single=$single)', (
      tester,
    ) async {
      tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 8);
      addTearDown(tester.view.resetGestureSettings);
      final fixture = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('noter-touch-');
        final repo = LocalNotebookRepository(directory);
        final bytes = await createPaper('blank', pages: 3);
        final note = await repo.create('Touch', bytes);
        return (directory, repo, bytes, note);
      }))!;
      final (directory, repo, bytes, note) = fixture;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: EditorPage(note: note, bytes: bytes, repository: repo),
        ),
      );
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      final session = pane.widget.session;
      Future<void> frames() async {
        for (var i = 0; i < 18; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await frames();
      expect(session.toolsReady, isTrue);
      if (single) {
        pane.toggleSinglePage();
        await frames();
      }
      final router = CapturedTouchReplay();
      void route(PointerEvent event) => router.route(
        event,
        intercept: (event) {
          NoterBinding.replayTouchPointer = null;
          return pane.handleCustomInput(event);
        },
        forward: tester.binding.handlePointerEvent,
        replayPointer: () => NoterBinding.replayTouchPointer,
      );
      final rect = pane.viewer.globalRectOf(
        0,
        pane.editing.document.page(0).cropBox,
      )!;
      var start = rect.center;
      void stroke(int pointer, PointerDeviceKind kind) {
        route(PointerDownEvent(pointer: pointer, kind: kind, position: start));
        route(
          PointerMoveEvent(
            pointer: pointer,
            kind: kind,
            position: start + const Offset(50, -60),
            delta: const Offset(50, -60),
          ),
        );
        route(
          PointerUpEvent(
            pointer: pointer,
            kind: kind,
            position: start + const Offset(50, -60),
          ),
        );
      }

      for (final tool in [
        PdfEditTool.ink,
        PdfEditTool.highlight,
        PdfEditTool.eraser,
        PdfEditTool.select,
      ]) {
        pane.editing.tool = tool;
        pane.viewer.setZoom(pane.viewer.zoom * 1.3);
        await frames();
        start = tester.getCenter(find.byType(EditorPane)) + const Offset(0, 80);
        final before = pane.viewer.globalRectOf(
          0,
          pane.editing.document.page(0).cropBox,
        )!;
        stroke(10 + tool.index, PointerDeviceKind.touch);
        await frames();
        expect(session.ink.index.strokes, isEmpty);
        expect(pane.editing.revisionId, 0);
        final after = pane.viewer.globalRectOf(
          0,
          pane.editing.document.page(0).cropBox,
        )!;
        expect(
          (after.topLeft - before.topLeft).distance,
          greaterThan(1),
          reason: 'One finger must pan with $tool',
        );
      }
      pane.editing.tool = PdfEditTool.ink;
      session.preferences.fingerDrawsInk = true;
      start = tester.getCenter(find.byType(EditorPane)) + const Offset(0, 80);
      stroke(30, PointerDeviceKind.touch);
      await frames();
      expect(session.ink.index.strokes, isNotEmpty);
      final count = session.ink.index.strokes.length;
      final zoom = pane.viewer.zoom;
      route(
        PointerDownEvent(
          pointer: 40,
          kind: PointerDeviceKind.touch,
          position: start - const Offset(30, 0),
        ),
      );
      route(
        PointerDownEvent(
          pointer: 41,
          kind: PointerDeviceKind.touch,
          position: start + const Offset(30, 0),
        ),
      );
      await tester.pump();
      route(
        PointerMoveEvent(
          pointer: 40,
          kind: PointerDeviceKind.touch,
          position: start - const Offset(90, 0),
          delta: const Offset(-60, 0),
        ),
      );
      route(
        PointerMoveEvent(
          pointer: 41,
          kind: PointerDeviceKind.touch,
          position: start + const Offset(90, 0),
          delta: const Offset(60, 0),
        ),
      );
      await tester.pump();
      route(
        PointerUpEvent(
          pointer: 40,
          kind: PointerDeviceKind.touch,
          position: start - const Offset(90, 0),
        ),
      );
      route(
        PointerUpEvent(
          pointer: 41,
          kind: PointerDeviceKind.touch,
          position: start + const Offset(90, 0),
        ),
      );
      await frames();
      expect(pane.viewer.zoom, greaterThan(zoom));
      expect(
        session.ink.index.strokes.length,
        count,
        reason: 'Pinching cancels the provisional finger stroke',
      );
      expect(session.preferences.fingerDrawsInk, isTrue);
      session.preferences.fingerDrawsInk = false;
      stroke(50, PointerDeviceKind.stylus);
      await frames();
      expect(session.ink.index.strokes.length, greaterThan(count));
      expect(tester.takeException(), isNull);
      final saved = session.save();
      var finished = false;
      saved.then((_) => finished = true);
      for (var i = 0; i < 100 && !finished; i++) {
        await frames();
      }
      expect(finished, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => directory.delete(recursive: true));
    });
  }
}
