// CPU regression probe, not an FPS or physical stylus latency measurement.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/ink_layer.dart';

InkStroke fixture(int i) => InkStroke(
  id: 'fixture-$i',
  page: '1:0',
  order: i,
  color: 0xff123456,
  width: 2,
  points: Float32List.fromList([
    for (var p = 0; p < 64; p++) ...[
      20 + (i % 20) * 25 + p * .25,
      20 + (i % 40) * 18 + math.sin(p * .2) * 4,
      .5 + .3 * math.sin(p * .1),
    ],
  ]),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bytes = await createPaper('blank');
  final prefs = PdfEditingPreferences(store: PdfMemoryPreferencesStore());
  await prefs.ready;
  final legacy = PdfEditingController(bytes, preferences: prefs)
    ..inkCommitDelay = null;
  for (var i = 0; i < 1000; i++) {
    final s = fixture(i), p = s.points;
    legacy.addInkStroke(
      0,
      [for (var j = 0; j < p.length; j += 3) (p[j], p[j + 1])],
      pressures: [for (var j = 2; j < p.length; j += 3) p[j]],
    );
  }
  final watch = Stopwatch()..start();
  legacy.finishInk();
  final oldCommit = watch.elapsedMicroseconds / 1000;
  final oldBytes = legacy.bytes.length;
  legacy.dispose();
  prefs.dispose();
  final results = <Map<String, Object>>[];
  for (final existing in [0, 1000, 10000]) {
    final ink = InkController(
      InkDocument(
        generation: 'benchmark',
        strokes: [for (var i = 0; i < existing; i++) fixture(i)],
      ),
    );
    final live = LiveInk(ink), cache = InkPathCache();
    final times = <double>[];
    var maxTail = 0;
    for (var s = 0; s < 110; s++) {
      watch.reset();
      live.begin('1:0', 0xff123456, 2);
      for (var p = 0; p < 256; p++) {
        live.add(
          30 + p * .2,
          100 + math.sin(p * .2) * 4,
          .5 + .3 * math.sin(p * .1),
        );
        maxTail = math.max(maxTail, live.tailPoints);
        // 240 input samples/s at 60 display frames/s: four samples/frame.
        if (p % 4 == 0) inkRibbon(live.tail!);
      }
      final frozen = ink.preview.strokes.toList();
      for (final chunk in frozen) {
        cache.path(chunk);
      }
      live.finish();
      for (final chunk in frozen) {
        cache.path(chunk);
      }
      if (s >= 10) times.add(watch.elapsedMicroseconds / 1000);
    }
    if (maxTail > 65) throw StateError('Unbounded active stroke tail.');
    times.sort();
    results.add({
      'existing_strokes': existing,
      'existing_points': existing * 64,
      'new_stroke_points': 256,
      'measured_strokes': times.length,
      'p50_cpu_ms_per_stroke': times[times.length ~/ 2],
      'p95_cpu_ms_per_stroke': times[(times.length * .95).floor()],
      'max_cpu_ms_per_stroke': times.last,
      'max_live_tail_points': maxTail,
      'rss_mb': ProcessInfo.currentRss / (1024 * 1024),
    });
    live.dispose();
    ink.dispose();
    cache.clear();
  }
  // ignore: avoid_print
  print(
    'NOTER_INK_PERFORMANCE=${jsonEncode({'mode': 'Headless Flutter JIT CPU probe; no UI/GPU/device FPS measurement', 'dart': Platform.version, 'legacy_1000x64_points_sync_pdf_commit_ms': oldCommit, 'legacy_pdf_bytes': oldBytes, 'unchanged_base_pdf_bytes': bytes.length, 'results': results})}',
  );
  exit(0);
}
