import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/learning.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/tapes.dart';
import 'package:noter/data/templates.dart';
import 'package:noter/editor/operations.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect;

class GatedRepository implements NotebookRepository {
  GatedRepository(this.inner);
  final NotebookRepository inner;
  Completer<void>? gate;
  final started = Completer<void>();
  bool fail = false;
  @override
  LibraryCatalog get catalog => inner.catalog;
  @override
  TemplateRepository get templates => inner.templates;
  @override
  Future<Notebook> save(Notebook note, Uint8List pdf) async {
    if (!started.isCompleted) started.complete();
    await gate?.future;
    if (fail) throw const FileSystemException('disk full');
    return inner.save(note, pdf);
  }

  @override
  Future<void> flush() => inner.flush();
  @override
  Future<List<Notebook>> list() => inner.list();
  @override
  Future<Uint8List> load(String id) => inner.load(id);
  @override
  Future<Notebook> create(
    String title,
    Uint8List pdf, {
    String paper = 'pdf',
    int lineColor = 0xDCE4EC,
  }) => inner.create(title, pdf, paper: paper, lineColor: lineColor);
  @override
  Future<void> delete(String id) => inner.delete(id);
  @override
  Future<Uint8List> exportArchive(Notebook note) => inner.exportArchive(note);
  @override
  Future<Notebook> importArchive(Uint8List bytes) => inner.importArchive(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalNotebookRepository repo;
  late DocumentSession session;
  final now = DateTime.utc(2026, 1, 1, 12);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-study-');
    repo = LocalNotebookRepository(root);
    final bytes = await createPaper('blank');
    final note = await repo.create('Lernen', bytes);
    session = DocumentSession(
      note,
      bytes,
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
      autosaveDelay: const Duration(days: 1),
      checkpointInterval: const Duration(days: 1),
      clock: () => now,
    );
    await session.preferences.ready;
    addTape(session.editing, 0, const PdfRect(20, 20, 120, 80));
  });
  tearDown(() async {
    session.dispose();
    await repo.flush();
    await root.delete(recursive: true);
  });

  test(
    'assessments survive restart, archive transfer, recovery and PDF undo',
    () async {
      final id = session.tapes.single.id;
      final revision = session.editing.revisionId;
      expect(await session.rateTape(id, ReviewRating.known), isTrue);
      expect(session.editing.revisionId, revision);
      expect(session.dirty, isFalse);
      final note = (await LocalNotebookRepository(root).list()).single;
      final targets = findTapes(PdfDocument.open(await repo.load(note.id)));
      expect(targets.single.id, id);
      expect(note.learning.schedule(id)!.due, now.add(const Duration(days: 1)));
      final imported = await repo.importArchive(await repo.exportArchive(note));
      expect(
        imported.learning.schedule(id)!.due,
        note.learning.schedule(id)!.due,
      );
      expect(
        findTapes(PdfDocument.open(await repo.load(imported.id))).single.id,
        id,
      );
      await repo.delete(imported.id);
      final restored = await repo.restore((await repo.recovery()).single);
      expect(
        restored.learning.events.single.id,
        note.learning.events.single.id,
      );

      session.editing.selectAnnotation(0, 0);
      session.editing.deleteSelected();
      expect(session.tapes, isEmpty);
      expect(() => session.rateTape(id, ReviewRating.again), throwsStateError);
      session.editing.undo();
      expect(session.tapes.single.id, id);
      expect(session.note.learning.schedule(id)!.count, 1);
      session.editing.redo();
      expect(session.tapes, isEmpty);
      expect(session.note.learning.events.length, 1);
    },
  );

  test(
    'page moves retain identity; page/annotation copies get fresh unrated identities',
    () async {
      final editing = session.editing;
      final id = session.tapes.single.id;
      await session.rateTape(id, ReviewRating.known);
      editing.insertPagesFromBytes(await createPaper('grid'));
      editing.movePage(0, 1);
      expect(session.tapes.single.id, id);
      expect(session.tapes.single.page, 1);
      await duplicateNotebookPages(editing, [1]);
      expect(session.tapes.length, 2);
      expect(session.tapes.map((t) => t.id).toSet().length, 2);
      final duplicate = session.tapes.last.id;
      expect(session.note.learning.schedule(duplicate), isNull);
      editing.copyPages([1]);
      pasteNotebookPages(editing);
      pasteNotebookPages(editing);
      expect(session.tapes.map((t) => t.id).toSet().length, 4);
      editing.selectAnnotation(1, 0);
      editing.copySelectedAnnotations();
      editing.pasteAnnotations(1);
      expect(session.tapes.map((t) => t.id).toSet().length, 5);
      for (final tape in session.tapes.where((t) => t.id != id)) {
        expect(session.note.learning.schedule(tape.id), isNull);
      }
      editing.removePages([1]);
      expect(session.tapes.any((t) => t.id == id), isFalse);
      expect(session.note.learning.schedule(id)!.count, 1);
      editing.undo();
      expect(session.tapes.any((t) => t.id == id), isTrue);
    },
  );

  test(
    'ratings arriving during a save drain without being overwritten',
    () async {
      final gateway = GatedRepository(repo)..gate = Completer<void>();
      final other = DocumentSession(
        session.note,
        session.editing.bytes,
        gateway,
        preferencesStore: PdfMemoryPreferencesStore(),
        clock: () => now,
        autosaveDelay: const Duration(days: 1),
        checkpointInterval: const Duration(days: 1),
      );
      try {
        final id = other.tapes.single.id;
        final first = other.rateTape(id, ReviewRating.known);
        await gateway.started.future;
        final second = other.rateTape(id, ReviewRating.again);
        gateway.gate!.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(other.dirty, isFalse);
        expect((await repo.list()).single.learning.schedule(id)!.count, 2);
        expect(
          (await repo.list()).single.learning.schedule(id)!.interval,
          const Duration(minutes: 10),
        );
      } finally {
        other.dispose();
      }
    },
  );

  test(
    'save failures retain assessments for retry and expose unsaved state',
    () async {
      final gateway = GatedRepository(repo)..fail = true;
      final other = DocumentSession(
        session.note,
        session.editing.bytes,
        gateway,
        preferencesStore: PdfMemoryPreferencesStore(),
        clock: () => now,
      );
      try {
        final id = other.tapes.single.id;
        expect(await other.rateTape(id, ReviewRating.unsure), isFalse);
        expect(other.dirty, isTrue);
        expect(other.error, isNotNull);
        expect(other.note.learning.events.length, 1);
        gateway.fail = false;
        expect(await other.save(), isTrue);
        expect(other.dirty, isFalse);
        expect((await repo.list()).single.learning.schedule(id)!.count, 1);
      } finally {
        other.dispose();
      }
    },
  );

  test(
    'version 1/2 default to no progress; version 3 guards older clients',
    () {
      expect(Notebook.fromJson(session.note.toJson()).learning.isEmpty, isTrue);
      final id = session.tapes.single.id;
      final updated = session.note.copy(
        learning: session.note.learning.assess(
          id,
          ReviewRating.known,
          id: 'review',
          at: now,
        ),
      );
      expect(updated.toJson()['version'], 3);
      final decoded = LocalNotebookRepository.decode(
        LocalNotebookRepository.encode(updated, session.editing.bytes),
      );
      expect(decoded.$1.learning.schedule(id)!.count, 1);
      expect(
        () => Notebook.fromJson(updated.toJson()..['version'] = 2),
        throwsFormatException,
      );
    },
  );
}
