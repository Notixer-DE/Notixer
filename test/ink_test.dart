import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart'
    show PdfMemoryPreferencesStore;
import 'package:noter/data/ink.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/ink_gestures.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'sync_scenarios.dart' show MemoryRemote;

InkStroke stroke(
  String page, {
  String id = 'test',
  int order = 0,
  double y = 100,
}) => InkStroke(
  id: id,
  page: page,
  order: order,
  color: 0xff123456,
  width: 2,
  points: Float32List.fromList([
    for (var i = 0; i < 64; i++) ...[20.0 + i * 2, y, .2 + i / 100],
  ]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repo;
  late DocumentSession session;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-ink-test-');
    repo = LocalNotebookRepository(directory);
    final bytes = await createPaper('blank', pages: 2);
    final note = await repo.create('Ink', bytes);
    session = DocumentSession(
      note,
      bytes,
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
      autosaveDelay: const Duration(days: 1),
      checkpointInterval: const Duration(days: 1),
    );
    await session.ready;
    expect(session.error, isNull, reason: 'Own ink must load before editing.');
  });
  tearDown(() async {
    session.dispose();
    await repo.flush();
    await directory.delete(recursive: true);
  });

  test(
    'ink on a new PDF page checkpoints its base before journal-only writes',
    () async {
      session.editing.apply((e) => e.insertBlankPage(at: 0));
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      for (var i = 0; i < 300 && session.saving; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(session.saving, isFalse);
      expect(session.error, isNull);
      expect(session.inkJournalCurrent, isTrue);
      final base = PdfDocument.open(await repo.load(session.note.id));
      expect(base.pageCount, 3);
      expect(inkPageId(base, 0), page);
      expect(
        (await repo.openInk(session.note.id)).$1.strokes.single.page,
        page,
      );
    },
  );

  test('ordinary metadata saves preserve journal ink on reopen', () async {
    final page = inkPageId(session.editing.document, 0);
    session.ink.apply(InkEdit(add: [stroke(page)]));
    await repo.flush();
    await repo.save(
      session.note.copy(title: 'Umbenannt'),
      Uint8List.fromList(session.editing.bytes),
    );
    final reopened = LocalNotebookRepository(directory);
    expect((await reopened.list()).single.title, 'Umbenannt');
    expect((await reopened.openInk(session.note.id)).$1.strokes, hasLength(1));
  });

  test('live ink combines tool opacity and existing color alpha', () {
    final page = inkPageId(session.editing.document, 0);
    final live = LiveInk(session.ink)
      ..begin(page, 0x80123456, 2, opacity: .5)
      ..add(10, 10, .5)
      ..finish();
    expect(session.ink.index.strokes.single.color, 0x40123456);
    live.dispose();
  });

  test('ribbon fill does not cancel when a stroke reverses direction', () {
    final ribbon = inkRibbon(
      InkStroke(
        id: 'reverse',
        page: '1:0',
        order: 0,
        color: 0x80123456,
        width: 6,
        points: Float32List.fromList([10, 10, .5, 100, 10, .5, 10, 10, .5]),
      ),
    );
    expect(ribbon.contains(const Offset(50, 10)), isTrue);
    expect(ribbon.contains(const Offset(50, 30)), isFalse);
  });

  test(
    'failed journal appends block later sequences until a checkpoint',
    () async {
      final page = inkPageId(session.editing.document, 0);
      final first = stroke(page), second = stroke(page, id: 'second', order: 1);
      final journal = Directory(
        '${directory.path}/.ink/${session.note.id}.jsonl',
      );
      await journal.create(recursive: true);
      await expectLater(
        repo.appendInk(
          session.note.id,
          '',
          session.ink.generation,
          1,
          InkEdit(add: [first]),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await journal.delete();
      await expectLater(
        repo.appendInk(
          session.note.id,
          '',
          session.ink.generation,
          2,
          InkEdit(add: [second]),
        ),
        throwsStateError,
      );
      await repo.checkpointInk(
        session.note,
        InkDocument(
          generation: session.ink.generation,
          sequence: 1,
          strokes: [first],
        ),
      );
      await repo.appendInk(
        session.note.id,
        '',
        session.ink.generation,
        2,
        InkEdit(add: [second]),
      );
      expect((await repo.openInk(session.note.id)).$1.strokes, hasLength(2));
    },
  );

  test(
    'internal page copies retain editable ink with fresh page and group IDs',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      final copy = await session.editing.editablePages([0]);
      expect(PdfDocument.open(copy.bytes).page(0).annotations, isEmpty);
      expect(copy.ink.strokes, hasLength(1));
      session.editing.insertEditablePages(copy);
      final added = session.ink.index.strokes.singleWhere(
        (s) => s.id != 'test',
      );
      expect(added.page, inkPageId(session.editing.document, 2));
      expect(added.group, isNot('test'));
      expect(added.points, orderedEquals(stroke(page).points));
      session.undo();
      expect(session.editing.document.pageCount, 2);
      expect(session.ink.index.strokes, hasLength(1));
      session.redo();
      expect(session.editing.document.pageCount, 3);
      expect(session.ink.index.strokes, hasLength(2));
    },
  );

  test(
    'templates preserve sidecar ink across rename and repeated insertion',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      final template = await repo.templates.save(
        'Handschrift',
        Uint8List.fromList(session.editing.bytes),
        page: 0,
        ink: session.ink.snapshot(),
      );
      await repo.templates.rename(template.id, 'Umbenannt');
      final first = await repo.templates.instantiateEditable(template.id);
      final second = await repo.templates.instantiateEditable(template.id);
      expect(PdfDocument.open(first.bytes).page(0).annotations, isEmpty);
      expect(first.ink.strokes, hasLength(1));
      expect(first.ink.strokes.single.id, isNot(second.ink.strokes.single.id));
      expect(
        first.ink.strokes.single.group,
        isNot(second.ink.strokes.single.group),
      );
      session.editing.insertEditablePages(first);
      session.editing.insertEditablePages(second);
      expect(
        session.ink.index.strokes.map((s) => s.page).toSet(),
        hasLength(3),
      );
      expect(
        PdfDocument.open(
          await repo.templates.preview(template.id),
        ).page(0).annotations,
        hasLength(1),
      );
    },
  );

  test('mixed PDF and ink actions undo and redo as a single command', () {
    final page = inkPageId(session.editing.document, 0);
    session.transaction(() {
      session.editing.apply(
        (e) => e.addSquare(0, const PdfRect(10, 10, 30, 30)),
      );
      session.ink.apply(InkEdit(add: [stroke(page)]));
    });
    session.undo();
    expect(session.ink.index.strokes, isEmpty);
    expect(session.editing.document.page(0).annotations, isEmpty);
    expect(session.editing.canUndo, isFalse);
    session.redo();
    expect(session.ink.index.strokes, hasLength(1));
    expect(session.editing.document.page(0).annotations, hasLength(1));
  });

  test('page deletion removes orphan ink and undo restores it', () {
    final page = inkPageId(session.editing.document, 0);
    session.ink.apply(InkEdit(add: [stroke(page)]));
    session.editing.apply((e) => e.removePage(0));
    expect(session.ink.index.strokes, isEmpty);
    session.undo();
    expect(session.editing.document.pageCount, 2);
    expect(session.ink.index.strokes.single.page, page);
    session.redo();
    expect(session.ink.index.strokes, isEmpty);
  });

  test('ink clipboard belongs to its PDF controller, not another pane', () {
    final page = inkPageId(session.editing.document, 0);
    session.ink.apply(InkEdit(add: [stroke(page)]));
    session.ink.select(['test']);
    session.editing.copySelectedAnnotations();
    final other = DocumentSession(
      session.note,
      Uint8List.fromList(session.editing.bytes),
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
    );
    expect(other.editing.hasAnnotationClipboard, isFalse);
    other.dispose();
  });

  test(
    'ink selection styling and clipboard remain independent of PDF revisions',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      session.ink.select(['test']);
      expect(session.editing.canRestyleSelected, isTrue);
      expect(
        session.editing.restyleSelected(
          color: const Color(0xff445566),
          strokeWidth: 4,
          opacity: .25,
        ),
        isTrue,
      );
      final styled = session.ink.index['test']!;
      expect(styled.color & 0xffffff, 0x445566);
      expect(styled.width, 4);
      expect(session.editing.copySelectedAnnotations(), 1);
      expect(session.editing.pasteAnnotations(1), isTrue);
      expect(session.ink.index.strokes, hasLength(2));
      final copy = session.ink.index.strokes.singleWhere((s) => s.id != 'test');
      expect(copy.page, inkPageId(session.editing.document, 1));
      expect(copy.group, isNot(styled.group));
      expect(copy.points.first, closeTo(styled.points.first + 12, .001));
      expect(session.editing.revisionId, 0);
      session.editing.undo();
      expect(session.ink.index.strokes, hasLength(1));
      session.editing.undo();
      expect(session.ink.index['test']!.width, 2);
      expect(session.ink.index['test']!.color, 0xff123456);
    },
  );

  test('the chronological history is bounded without losing document data', () {
    final page = inkPageId(session.editing.document, 0);
    for (var i = 0; i < 300; i++) {
      session.ink.apply(
        InkEdit(
          add: [stroke(page, id: 'history-$i', order: i)],
        ),
      );
    }
    for (var i = 0; i < 300; i++) {
      session.editing.undo();
    }
    expect(session.ink.index.strokes, hasLength(44));
    expect(session.editing.canUndo, isFalse);
    session.ink.apply(
      InkEdit(add: [stroke(page, id: 'new-branch', order: 300)]),
    );
    expect(session.editing.canRedo, isFalse);
    expect(session.ink.index.strokes, hasLength(45));
  });

  test(
    'corrupt completed journal records never overwrite the last archive',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      await repo.flush();
      final file = File('${directory.path}/${session.note.id}.noter');
      final before = await file.readAsBytes();
      final journal = File('${directory.path}/.ink/${session.note.id}.jsonl');
      await journal.writeAsString(
        '{"sequence":99,"add":[],"remove":[]}\n',
        mode: FileMode.append,
        flush: true,
      );
      await expectLater(repo.openInk(session.note.id), throwsFormatException);
      expect(await file.readAsBytes(), orderedEquals(before));
      // The still-open editor can replace the damaged journal with its complete
      // in-memory snapshot; a failed replay itself never erases anything.
      expect(await session.save(), isTrue, reason: session.error);
      expect((await repo.openInk(session.note.id)).$1.strokes, hasLength(1));
    },
  );

  test(
    'drawing, saving and journal recovery do not revise or enlarge the PDF',
    () async {
      final before = Uint8List.fromList(session.editing.bytes);
      final page = inkPageId(session.editing.document, 0);
      final revision = session.editing.revisionId;
      session.ink.apply(InkEdit(add: [stroke(page)]));
      expect(session.editing.revisionId, revision);
      expect(session.editing.bytes, orderedEquals(before));
      await repo.flush();
      final recovered = await repo.openInk(session.note.id);
      expect(recovered.$1.strokes.single.id, 'test');
      expect(recovered.$1.sequence, 1);
      expect(recovered.$3, 0);
      expect(await session.save(), isTrue, reason: session.error);
      expect(await repo.load(session.note.id), orderedEquals(before));
      final reopened = await repo.openInk(session.note.id);
      expect(
        reopened.$1.strokes.single.points,
        orderedEquals(stroke(page).points),
      );
      expect(reopened.$3, 1);
      final exported = PdfDocument.open(await session.exportSnapshot());
      expect(exported.page(0).annotations.single.inkList, isNotEmpty);
      expect(exported.page(1).annotations, isEmpty);
      expect(
        PdfDocument.open(
          await repo.loadPdf(session.note.id),
        ).page(0).annotations,
        hasLength(1),
      );
    },
  );

  test(
    'ink and PDF edits share chronological undo and preserve page identity',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      session.editing.movePage(0, 1);
      expect(inkPageId(session.editing.document, 1), page);
      session.editing.undo();
      expect(inkPageId(session.editing.document, 0), page);
      expect(session.ink.index.strokes, hasLength(1));
      session.editing.undo();
      expect(session.ink.index.strokes, isEmpty);
      session.editing.redo();
      session.editing.redo();
      expect(inkPageId(session.editing.document, 1), page);
      final pdf = PdfDocument.open(await session.exportSnapshot());
      expect(pdf.page(0).annotations, isEmpty);
      expect(pdf.page(1).annotations, hasLength(1));
      final copy = PdfDocument.open(session.editing.exportPages([1]));
      expect(copy.page(0).annotations, hasLength(1));
    },
  );

  test(
    'eraser slices only indexed neighbours and is one undoable operation',
    () {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(
        InkEdit(
          add: [
            stroke(page),
            stroke(page, id: 'other', order: 1, y: 300),
          ],
        ),
      );
      final erase = InkEraserGesture(session.ink, page, 4)
        ..add(const Offset(80, 100));
      erase.finish();
      final parts = session.ink.index.strokes.toList();
      expect(parts.where((s) => s.id == 'other'), hasLength(1));
      expect(parts.where((s) => s.id != 'other'), hasLength(2));
      expect(parts.every((s) => s.color == 0xff123456 && s.width == 2), isTrue);
      session.editing.undo();
      expect(
        session.ink.index.strokes.map((s) => s.id),
        unorderedEquals(['test', 'other']),
      );
    },
  );

  test(
    'active tails and cached geometry stay bounded over a very long gesture',
    () {
      final page = inkPageId(session.editing.document, 0);
      final live = LiveInk(session.ink)..begin(page, 0xff123456, 2);
      for (var i = 0; i < 10000; i++) {
        live.add(20 + i * .01, 100 + i * .01, .5);
        expect(live.tailPoints, lessThanOrEqualTo(65));
      }
      final cache = InkPathCache();
      for (final chunk in session.ink.preview.strokes) {
        cache.path(chunk);
      }
      final builds = cache.builds;
      live.finish();
      for (final chunk in session.ink.index.strokes.where(
        (s) => s.pointCount == 64,
      )) {
        cache.path(chunk);
      }
      expect(cache.builds, builds);
      expect(session.editing.revisionId, 0);
      session.editing.undo();
      expect(session.ink.index.strokes, isEmpty);
      live.dispose();
    },
  );

  test(
    'checkpoints retain later queued edits and a truncated journal can resume',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      final saving = session.save();
      session.ink.apply(
        InkEdit(add: [stroke(page, id: 'second', order: 1, y: 200)]),
      );
      expect(await saving, isTrue, reason: session.error);
      await repo.flush();
      expect((await repo.openInk(session.note.id)).$1.strokes, hasLength(2));
      session.ink.apply(
        InkEdit(add: [stroke(page, id: 'third', order: 2, y: 300)]),
      );
      await repo.flush();
      final journal = File('${directory.path}/.ink/${session.note.id}.jsonl');
      await journal.writeAsString(
        '{"sequence":',
        mode: FileMode.append,
        flush: true,
      );
      final recovered = await repo.openInk(session.note.id);
      expect(recovered.$1.strokes, hasLength(3));
      session.ink.apply(
        InkEdit(add: [stroke(page, id: 'fourth', order: 3, y: 400)]),
      );
      await repo.flush();
      expect((await repo.openInk(session.note.id)).$1.strokes, hasLength(4));
    },
  );

  test(
    'archives, conflict copies and recovery include journal-only handwriting',
    () async {
      final page = inkPageId(session.editing.document, 0);
      session.ink.apply(InkEdit(add: [stroke(page)]));
      await repo.flush();
      final archive = await repo.exportArchive(session.note);
      expect(
        LocalNotebookRepository.decodeWithInk(archive).$3!.strokes,
        hasLength(1),
      );
      final imported = await repo.importArchive(archive);
      expect((await repo.openInk(imported.id)).$1.strokes, hasLength(1));
      await repo.delete(imported.id);
      final restored = await repo.restore((await repo.recovery()).single);
      expect((await repo.openInk(restored.id)).$1.strokes, hasLength(1));

      final remote = MemoryRemote();
      await NotebookSync(repo, remote).run();
      final secondRoot = await Directory.systemTemp.createTemp(
        'noter-ink-sync-',
      );
      final second = LocalNotebookRepository(secondRoot);
      try {
        await NotebookSync(second, remote).run();
        final other = await second.openInk(session.note.id);
        expect(
          other.$1.strokes.single.points,
          orderedEquals(stroke(page).points),
        );
        final ink = InkController(other.$1)
          ..apply(InkEdit(add: [stroke(page, id: 'remote', order: 1, y: 350)]));
        await second.saveWithInk(
          session.note,
          await second.load(session.note.id),
          ink.snapshot(),
        );
        ink.dispose();
        session.ink.apply(
          InkEdit(add: [stroke(page, id: 'local', order: 1, y: 250)]),
        );
        await session.save();
        await NotebookSync(second, remote).run();
        final report = await NotebookSync(repo, remote).run();
        expect(report.conflicts, 1);
        final notes = await repo.list();
        final conflict = notes.singleWhere((n) => n.title.contains('Konflikt'));
        expect((await repo.openInk(conflict.id)).$1.strokes, hasLength(2));
      } finally {
        await second.flush();
        await secondRoot.delete(recursive: true);
      }
    },
  );
}
