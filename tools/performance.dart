// Comparable storage/input-event-loop benchmark, not a device FPS measurement.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../test/fixtures/large_pdf.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';

Future<Map<String, Object>> measure(
  String name,
  Future<void> Function() action,
) async {
  var previous = DateTime.now().microsecondsSinceEpoch;
  var worst = 0, ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final gap = now - previous;
    if (gap > worst) worst = gap;
    previous = now;
    ticks++;
  });
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final watch = Stopwatch()..start();
  await action();
  watch.stop();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  timer.cancel();
  return {
    'operation': name,
    'milliseconds': watch.elapsedMicroseconds / 1000,
    'worst_event_loop_gap_ms': worst / 1000,
    'ticks': ticks,
    'rss_mb': ProcessInfo.currentRss / (1024 * 1024),
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await Directory.systemTemp.createTemp('noter-perf-');
  try {
    final pdf = largeScan();
    final repo = LocalNotebookRepository(directory);
    late Notebook note;
    final results = <Map<String, Object>>[];
    results.add(
      await measure('create_500_pages_48MiB', () async {
        note = await repo.create('Large scan', pdf);
      }),
    );
    results.add(
      await measure('save_48MiB', () async {
        note = await repo.save(note, pdf);
      }),
    );
    results.add(
      await measure('list_metadata_only', () async {
        await repo.list();
      }),
    );
    results.add(
      await measure('load_48MiB', () async {
        await repo.load(note.id);
      }),
    );
    final session = DocumentSession(
      note,
      pdf,
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
    );
    await session.preferences.ready;
    results.add(
      await measure('commit_100_pressure_strokes', () async {
        for (var i = 0; i < 100; i++) {
          session.editing.addInkStroke(
            0,
            [(30.0 + i, 30), (60.0 + i, 60), (90.0 + i, 70)],
            pressures: [.1, .5, .9],
          );
        }
        session.editing.finishInk();
      }),
    );
    session.eraser.handle(
      const PointerDownEvent(
        pointer: 1,
        kind: PointerDeviceKind.stylus,
        position: Offset(40, 40),
        buttons: kStylusContact,
      ),
      (_) {},
    );
    results.add(
      await measure('active_stylus_autosave_window', () async {
        await Future<void>.delayed(const Duration(milliseconds: 2600));
      }),
    );
    session.eraser.handle(
      const PointerUpEvent(
        pointer: 1,
        kind: PointerDeviceKind.stylus,
        position: Offset(40, 40),
      ),
      (_) {},
    );
    await session.save();
    session.dispose();
    results.add({
      'pdf_bytes': pdf.length,
      'archive_bytes': await File(
        '${directory.path}/${note.id}.noter',
      ).length(),
    });
    // ignore: avoid_print
    print(
      'NOTER_PERFORMANCE=${jsonEncode({'mode': 'Flutter standalone JIT engine; storage/event-loop benchmark', 'platform': Platform.operatingSystemVersion, 'dart': Platform.version, 'logical_processors': Platform.numberOfProcessors, 'fixture': '500 A4 pages sharing one deterministic 4096x4096 RGB scan', 'results': results})}',
    );
    await directory.delete(recursive: true);
    exit(0);
  } catch (e, stack) {
    stderr.writeln('$e\n$stack');
    exit(1);
  }
}
