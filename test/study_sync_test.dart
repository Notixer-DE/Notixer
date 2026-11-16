import 'dart:convert';
import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/learning.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/tapes.dart';
import 'package:noter/editor/operations.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect;
import 'sync_scenarios.dart' show MemoryRemote;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2026, 1, 1, 12);
  late Directory root;
  late LocalNotebookRepository a, b, c;
  late MemoryRemote remote;
  late String tapeId;
  Future<SyncReport> sync(LocalNotebookRepository repo) =>
      NotebookSync(repo, remote).run();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-review-sync-');
    a = LocalNotebookRepository(Directory('${root.path}/a'));
    b = LocalNotebookRepository(Directory('${root.path}/b'));
    c = LocalNotebookRepository(Directory('${root.path}/c'));
    remote = MemoryRemote();
    final bytes = await createPaper('blank');
    final note = await a.create('Skript', bytes);
    final session = DocumentSession(
      note,
      bytes,
      a,
      preferencesStore: PdfMemoryPreferencesStore(),
      clock: () => start,
    );
    addTape(session.editing, 0, const PdfRect(20, 20, 140, 80));
    tapeId = session.tapes.single.id;
    await session.rateTape(tapeId, ReviewRating.known);
    session.dispose();
    await sync(a);
    await sync(b);
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> rate(
    LocalNotebookRepository repo,
    ReviewRating rating,
    String eventId,
  ) async {
    final note = (await repo.list()).single;
    await repo.save(
      note.copy(
        learning: note.learning.assess(
          tapeId,
          rating,
          id: eventId,
          at: start.add(const Duration(days: 1)),
        ),
      ),
      await repo.load(note.id),
    );
  }

  test(
    'concurrent offline reviews converge on all devices without conflict copies',
    () async {
      await rate(a, ReviewRating.known, 'tablet');
      await rate(b, ReviewRating.again, 'laptop');
      remote.frozenList = await remote.list();
      await sync(a);
      await sync(b);
      remote.frozenList = null;
      final result = await sync(a);
      expect(result.conflicts, 0);
      await sync(b);
      await sync(c);
      final reference = (await a.list()).single.learning;
      for (final repo in [a, b, c]) {
        final note = (await repo.list()).single;
        expect(
          jsonEncode(note.learning.toJson()),
          jsonEncode(reference.toJson()),
        );
        expect(note.learning.schedule(tapeId)!.count, 3);
        expect(note.learning.schedule(tapeId)!.concurrent, isTrue);
        expect(
          note.learning.schedule(tapeId)!.due,
          start.add(const Duration(days: 1, minutes: 10)),
        );
        expect(
          findTapes(PdfDocument.open(await repo.load(note.id))).single.id,
          tapeId,
        );
      }
      final count = remote.revisions.length;
      await sync(a);
      await sync(b);
      expect(remote.revisions.length, count);
      await rate(b, ReviewRating.unsure, 'after_merge');
      await sync(b);
      await sync(a);
      expect((await a.list()).single.learning.schedule(tapeId)!.count, 4);
      expect(
        (await a.list()).single.learning.schedule(tapeId)!.concurrent,
        isFalse,
      );
    },
  );

  test(
    'actual document conflicts retain the union of assessments in both versions',
    () async {
      await rate(a, ReviewRating.known, 'tablet');
      final note = (await a.list()).single;
      await a.save(
        note.copy(title: 'Bearbeitetes Skript'),
        await a.load(note.id),
      );
      await rate(b, ReviewRating.again, 'laptop');
      remote.frozenList = await remote.list();
      await sync(a);
      await sync(b);
      remote.frozenList = null;
      final report = await sync(a);
      expect(report.conflicts, 1);
      await sync(b);
      await sync(c);
      for (final repo in [a, b, c]) {
        final notes = await repo.list();
        expect(notes.length, 2);
        for (final note in notes) {
          expect(note.learning.schedule(tapeId)!.count, 3);
        }
      }
    },
  );

  test(
    'offline and racing writes preserve assessments for a later sync',
    () async {
      await rate(a, ReviewRating.again, 'offline');
      remote.offline = true;
      await expectLater(sync(a), throwsA(isA<SocketException>()));
      expect((await a.list()).single.learning.schedule(tapeId)!.count, 2);
      remote.offline = false;
      await sync(a);
      remote.beforeDownload = () async {
        remote.beforeDownload = null;
        await rate(b, ReviewRating.unsure, 'during_download');
      };
      await expectLater(sync(b), throwsStateError);
      expect(
        (await b.list()).single.learning.events.any(
          (e) => e.id == 'during_download',
        ),
        isTrue,
      );
      await sync(b);
      await sync(a);
      expect((await a.list()).single.learning.schedule(tapeId)!.count, 3);
      expect((await b.list()).single.learning.schedule(tapeId)!.count, 3);
    },
  );
}
