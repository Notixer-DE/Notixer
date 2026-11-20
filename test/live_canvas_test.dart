import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/live/live_canvas.dart';
import 'package:noter/live/live_channel.dart';
import 'package:noter/sync/sync_crypto.dart';

void main() {
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
