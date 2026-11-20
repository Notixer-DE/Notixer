import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/live/live_canvas.dart';
import 'package:noter/live/live_host_page.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/live/live_channel.dart';
import 'package:noter/sync/sync_crypto.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;

void main() {
  testWidgets('stylus pressure and the momentary eraser work on Live Canvas', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('notixer-live-stylus-');
    addTearDown(() => root.deleteSync(recursive: true));
    final repository = LocalNotebookRepository(root);
    final sync = SyncController(repository);
    addTearDown(sync.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveHostPage(repository: repository, sync: sync),
      ),
    );
    final surface = find.byType(LiveCanvasSurface);
    final model = tester.widget<LiveCanvasSurface>(surface).model;
    final center = tester.getCenter(surface);
    final finger = TestPointer(1, PointerDeviceKind.touch);
    await tester.sendEventToBinding(finger.down(center));
    await tester.sendEventToBinding(finger.up());
    expect(model.ink.index.strokes, isEmpty);

    final pen = TestPointer(2, PointerDeviceKind.stylus);
    await tester.sendEventToBinding(pen.down(center));
    final move = pen.move(center + const Offset(12, 0));
    await tester.sendEventToBinding(
      PointerMoveEvent(
        viewId: move.viewId,
        pointer: move.pointer,
        device: move.device,
        kind: move.kind,
        position: move.position,
        delta: move.delta,
        buttons: move.buttons,
        pressure: .25,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    await tester.sendEventToBinding(pen.up());
    expect(model.ink.index.strokes.single.points.last, .25);

    await tester.sendEventToBinding(
      pen.down(center, buttons: kPrimaryStylusButton),
    );
    expect(model.ink.index.strokes, isEmpty);
    await tester.sendEventToBinding(
      pen.move(center + const Offset(12, 0), buttons: kPrimaryButton),
    );
    await tester.sendEventToBinding(pen.up());
    expect(model.ink.index.strokes, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pinch and zoom controls keep ink input aligned and colors separate',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('notixer-live-tools-');
      addTearDown(() => root.deleteSync(recursive: true));
      final repository = LocalNotebookRepository(root);
      final sync = SyncController(repository);
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveHostPage(repository: repository, sync: sync),
        ),
      );
      final surface = find.byType(LiveCanvasSurface);
      final layer = find.byType(InkLayer);
      final model = tester.widget<LiveCanvasSurface>(surface).model;
      final pen = TestPointer(10, PointerDeviceKind.stylus);
      final center = tester.getCenter(layer);
      final initialWidth = tester.getSize(layer).width;
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(tester.getSize(layer).width, greaterThan(initialWidth));

      await tester.tap(find.byTooltip('Pen color'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blue'));
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(pen.down(center));
      await tester.sendEventToBinding(pen.up());
      final stroke = model.ink.index.strokes.single;
      expect(stroke.color, 0xff3572db);
      expect(stroke.points[0], closeTo(PdfPageFormat.a4.width / 2, .1));
      expect(stroke.points[1], closeTo(PdfPageFormat.a4.height / 2, .1));

      await tester.tap(find.byTooltip('Fit page'));
      await tester.pump();
      expect(tester.getSize(layer).width, initialWidth);
      await tester.tap(find.byTooltip('Enable finger drawing'));
      await tester.pump();
      final first = TestPointer(11, PointerDeviceKind.touch);
      final second = TestPointer(12, PointerDeviceKind.touch);
      await tester.sendEventToBinding(first.down(center - const Offset(28, 0)));
      await tester.sendEventToBinding(
        second.down(center + const Offset(28, 0)),
      );
      await tester.sendEventToBinding(
        second.move(center + const Offset(70, 0)),
      );
      await tester.sendEventToBinding(first.up());
      await tester.sendEventToBinding(second.up());
      await tester.pump();
      expect(tester.getSize(layer).width, greaterThan(initialWidth));
      expect(model.ink.index.strokes, hasLength(1));

      await tester.tap(find.byTooltip('Marker'));
      await tester.pump();
      await tester.tap(find.byTooltip('Marker color'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Green'));
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(pen.down(center));
      await tester.sendEventToBinding(pen.up());
      expect(model.ink.index.strokes.map((ink) => ink.color), [
        0xff3572db,
        0x753bae67,
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the lasso moves and deletes selected ink on both devices', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('notixer-live-lasso-');
    addTearDown(() => root.deleteSync(recursive: true));
    final repository = LocalNotebookRepository(root);
    final sync = SyncController(repository);
    final viewer = LiveCanvasModel();
    addTearDown(sync.dispose);
    addTearDown(viewer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveHostPage(repository: repository, sync: sync),
      ),
    );
    final model = tester
        .widget<LiveCanvasSurface>(find.byType(LiveCanvasSurface))
        .model;
    model.onEvent = viewer.receive;
    final center = tester.getCenter(find.byType(InkLayer));
    final pen = TestPointer(10, PointerDeviceKind.stylus);
    Future<void> gesture(List<Offset> points) async {
      await tester.sendEventToBinding(pen.down(points.first));
      for (final point in points.skip(1)) {
        await tester.sendEventToBinding(pen.move(point));
      }
      await tester.sendEventToBinding(pen.up());
      await tester.pump();
    }

    await gesture([center, center + const Offset(20, 0)]);
    final original = model.ink.index.strokes.single;
    await tester.tap(find.byTooltip('Lasso selection'));
    await tester.pump();
    await gesture([
      center - const Offset(20, 20),
      center + const Offset(40, -20),
      center + const Offset(40, 20),
      center + const Offset(-20, 20),
    ]);
    expect(model.ink.selected, [original.id]);
    await gesture([center, center + const Offset(36, 10)]);
    final moved = model.ink.index.strokes.single;
    expect(moved.points[0], greaterThan(original.points[0]));
    expect(viewer.ink.index.strokes.single.points, moved.points);

    await tester.tap(find.byTooltip('Delete selection'));
    await tester.pump();
    expect(model.ink.index.strokes, isEmpty);
    expect(viewer.ink.index.strokes, isEmpty);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(viewer.ink.index.strokes.single.points, moved.points);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(viewer.ink.index.strokes.single.points, original.points);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'live and finished ink cross chunk boundaries at fractional zoom',
    (tester) async {
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = LiveCanvasModel();
      addTearDown(model.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 531,
                height: 359,
                child: LiveCanvasSurface(model: model),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      final paper = tester.getRect(find.byType(InkLayer));
      final boundary = tester.getRect(find.byKey(capture));
      final y = ((paper.center.dy - boundary.top) * 1.25).round();
      final left = ((paper.left - boundary.left) * 1.25).ceil() + 15;
      final right = ((paper.right - boundary.left) * 1.25).floor() - 15;
      Future<void> checkStroke() async {
        await tester.pump();
        final render =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: 1.25);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final expected = bytes.getUint32((y * image.width + left) * 4);
          expect(expected, isNot(0xffffffff));
          for (var x = left; x <= right; x++) {
            expect(
              bytes.getUint32((y * image.width + x) * 4),
              expected,
              reason: 'The stroke must stay uniform across pixel $x.',
            );
          }
          image.dispose();
        });
      }

      for (final color in [0xff234571, 0x75234571]) {
        model.begin(color, 14);
        for (var i = 0; i <= 144; i++) {
          model.point(
            PdfPageFormat.a4.width * i / 144,
            PdfPageFormat.a4.height / 2,
            .5,
          );
        }
        await checkStroke();
        model.finish();
        await checkStroke();
        model.undo();
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'devices derive the same live key without sharing the vault key',
    () async {
      final recovery = await SyncCrypto.generateRecoveryKey();
      final host = await SyncCrypto.create(recovery, 'account');
      final viewer = await SyncCrypto.create(recovery, 'account');
      final foreign = await SyncCrypto.create(recovery, 'another-account');
      expect(host.liveRoomKey('room'), viewer.liveRoomKey('room'));
      expect(host.liveRoomKey('room'), isNot(foreign.liveRoomKey('room')));
      expect(host.liveRoomKey('room'), isNot(host.liveRoomKey('other-room')));
      expect(host.liveRoomKey('room'), isNot(recovery));
    },
  );

  test('a spectator sees in-flight ink and catches up from a snapshot', () {
    final host = LiveCanvasModel();
    final viewer = LiveCanvasModel();
    final late = LiveCanvasModel();
    addTearDown(host.dispose);
    addTearDown(viewer.dispose);
    addTearDown(late.dispose);
    host.onEvent = viewer.receive;
    host.begin(0xff1d3b50, 3);
    host.point(10, 20, 0.2);
    host.point(20, 30, 0.8);
    host.flush();
    expect(viewer.live.active, isTrue);
    expect(viewer.ink.index.strokes, isEmpty);
    expect(viewer.live.tail!.pointCount, 2);
    late.receive(host.snapshot());
    expect(late.live.tail!.pointCount, 2);
    host.onEvent = (event) {
      viewer.receive(event);
      late.receive(event);
    };
    host.point(30, 40, 0.8);
    host.finish();
    expect(
      viewer.ink.index.strokes.single.points,
      host.ink.index.strokes.single.points,
    );
    expect(
      late.ink.index.strokes.single.points,
      host.ink.index.strokes.single.points,
    );
    expect(late.live.active, isFalse);
    host.erase(const Offset(20, 30), 3);
    expect(late.ink.index.strokes, isEmpty);
    host.undo();
    expect(viewer.ink.index.strokes.single.pointCount, 3);
    host.redo();
    expect(viewer.ink.index.strokes, isEmpty);
  });

  test(
    'encrypted events authenticate the session and carry a sequence',
    () async {
      final server = Uri.parse('https://example.test');
      final key = await SyncCrypto.generateRecoveryKey();
      final channel = LiveChannel(
        server,
        'room',
        await SyncCrypto.create(key, 'room'),
      );
      final other = LiveChannel(
        server,
        'other',
        await SyncCrypto.create(key, 'other'),
      );
      final frame = await channel.encode({'type': 'cancel'}, 42);
      expect(await channel.decode(frame), {
        'type': 'cancel',
        'v': 1,
        'seq': 42,
      });
      await expectLater(other.decode(frame), throwsA(isA<Exception>()));
    },
  );
}
