import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/live/live_canvas.dart';
import 'package:noter/live/live_host_page.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/live/live_channel.dart';
import 'package:noter/sync/sync_crypto.dart';

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
