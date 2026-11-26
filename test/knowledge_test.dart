import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/library_backup.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/todo_list.dart';
import 'package:noter/data/templates.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/library_extras_sync.dart';
import 'package:pdf/widgets.dart' as pw;
import 'sync_scenarios.dart' show MemoryRemote;

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late KnowledgeStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-knowledge-');
    repository = LocalNotebookRepository(directory);
    store = KnowledgeStore(repository);
    await store.load();
  });
  tearDown(() async {
    await repository.flush();
    await directory.delete(recursive: true);
  });

  test(
    'a document task keeps its own plan when checked and reopened',
    () async {
      final note = await store.capture('Plan', '- [ ] First\n- [ ] Second\n');
      final first = (await store.scan(
        const KnowledgeView('', openTasks: true),
      )).tasks.singleWhere((task) => task.text == 'First');
      await store.planQuickTodo(
        first,
        projectId: null,
        newProject: 'Field work',
        due: DateTime(2026, 12, 1),
      );
      final open = (await store.scan(
        const KnowledgeView('', openTasks: true),
      )).tasks;
      final planned = open.singleWhere((task) => task.text == 'First');
      expect(planned.documentTodo?.project, 'Field work');
      expect(planned.due, '2026-12-01');
      expect(open.singleWhere((task) => task.text == 'Second').due, isNull);
      await store.changeTask(planned);
      final finished = (await store.scan(
        const KnowledgeView('', completedTasks: true),
      )).tasks.singleWhere((task) => task.note.id == note.id);
      expect(finished.due, '2026-12-01');
      await store.changeTask(finished);
      final reopened = (await store.scan(
        const KnowledgeView('', openTasks: true),
      )).tasks.singleWhere((task) => task.text == 'First');
      expect(reopened.documentTodo?.project, 'Field work');
      expect(reopened.due, '2026-12-01');
    },
  );

  test(
    'to-do list identity and literal tasks survive sync, archive import, and backup',
    () async {
      final todo = await createTodoList(repository, 'Supplies');
      expect(todo.isTodoList, isTrue);
      const task = 'Buy [tea] *and* coffee';
      final source = appendTodoItem(appendTodoItem('', task), 'Pick up mail');
      expect(todoListItems(source).map((item) => item.text), [
        task,
        'Pick up mail',
      ]);
      await repository.save(todo, MarkdownDocument(source).encode());
      final scan = await store.scan(
        const KnowledgeView('', openTasks: true, query: '[tea]'),
      );
      expect(scan.hits.single.snippet, task);
      final open = scan.tasksByLocation['${todo.id}:line=1']!;
      expect(open.canPlan, isFalse);
      await store.changeTask(open);

      final remote = MemoryRemote();
      final second = LocalNotebookRepository(
        Directory('${directory.path}/second'),
      );
      await NotebookSync(repository, remote).run();
      await NotebookSync(second, remote).run();
      final imported = await second.importArchive(
        await repository.exportArchive(todo),
      );
      final restoredRepo = LocalNotebookRepository(
        Directory('${directory.path}/restored'),
      );
      final restored = (await LibraryBackup(
        restoredRepo,
      ).restore(await LibraryBackup(repository).snapshot())).single;
      for (final (repo, note) in [
        (
          second,
          (await second.list()).singleWhere((note) => note.id == todo.id),
        ),
        (second, imported),
        (restoredRepo, restored),
      ]) {
        expect(note.isTodoList, isTrue);
        final items = todoListItems(
          MarkdownDocument.decode(await repo.load(note.id)).source,
        );
        expect(items.map((item) => (item.text, item.done)), [
          (task, true),
          ('Pick up mail', false),
        ]);
      }
    },
  );

  test(
    'quick to-dos merge independently and survive library backups',
    () async {
      const view = KnowledgeView('', openTasks: true);
      final first = await store.addQuickTodo('Prepare the slides');
      final other = await store.addQuickTodo('Book a room');
      expect(await repository.list(), isEmpty);
      expect(
        (await store.quickTodos.read()).keys,
        unorderedEquals([first.id, other.id]),
      );
      final original = (await store.scan(
        view,
      )).tasks.singleWhere((task) => task.quickTodo?.id == first.id);
      final remote = MemoryRemote();
      final second = LocalNotebookRepository(
        Directory('${directory.path}/second'),
      );
      final secondStore = KnowledgeStore(second);
      final syncFirst = LibraryExtrasSync(repository, remote);
      final syncSecond = LibraryExtrasSync(second, remote);
      await syncFirst.run();
      await syncSecond.run();
      await store.planQuickTodo(
        original,
        projectId: null,
        newProject: 'Conference',
        text: 'Review the slides',
        due: DateTime(2026, 11, 30),
      );
      await expectLater(
        store.planQuickTodo(original, projectId: null, due: null),
        throwsFormatException,
      );
      final otherTask = (await secondStore.scan(
        view,
      )).tasks.singleWhere((task) => task.quickTodo?.id == other.id);
      await secondStore.changeTask(otherTask);
      final third = await secondStore.addQuickTodo('Send invitations');
      await syncFirst.run();
      await syncSecond.run();
      await syncFirst.run();
      expect(await repository.list(), isEmpty);
      expect(await second.list(), isEmpty);

      final backup = await LibraryBackup(repository).snapshot();
      final restored = LocalNotebookRepository(
        Directory('${directory.path}/restored'),
      );
      expect(await LibraryBackup(restored).restore(backup), isEmpty);
      for (final repo in [repository, second, restored]) {
        final inbox = await KnowledgeStore(repo).quickTodos.read();
        expect(inbox.keys, unorderedEquals([first.id, other.id, third.id]));
        expect(inbox[first.id]!.text, 'Review the slides');
        expect(inbox[first.id]!.due, '2026-11-30');
        expect(repo.catalog.folderName(inbox[first.id]!.project), 'Conference');
        expect(inbox[other.id]!.done, isTrue);
        expect(
          (await KnowledgeStore(repo).scan(view)).tasks.map((t) => t.text),
          unorderedEquals(['Review the slides', 'Send invitations']),
        );
      }
    },
  );

  test('deleting a quick to-do wins over a stale synced edit', () async {
    final remote = MemoryRemote();
    final second = LocalNotebookRepository(
      Directory('${directory.path}/second'),
    );
    final firstStore = KnowledgeStore(repository);
    final secondStore = KnowledgeStore(second);
    const view = KnowledgeView('', openTasks: true);
    final todo = await firstStore.addQuickTodo('Remove from all devices');
    final syncFirst = LibraryExtrasSync(repository, remote);
    final syncSecond = LibraryExtrasSync(second, remote);
    await syncFirst.run();
    await syncSecond.run();

    final firstTask = (await firstStore.scan(view)).tasks.single;
    await firstStore.changeTask(firstTask.forDeletion());
    final stale = (await secondStore.scan(view)).tasks.single;
    await secondStore.changeTask(
      stale.withTimer(workTime: const Duration(minutes: 7)),
    );
    await syncFirst.run();
    await syncSecond.run();
    await syncFirst.run();

    for (final store in [firstStore, secondStore]) {
      expect((await store.quickTodos.read()).containsKey(todo.id), isFalse);
      expect((await store.scan(view)).tasks, isEmpty);
    }
    final backup = await LibraryBackup(repository).snapshot();
    final restored = LocalNotebookRepository(
      Directory('${directory.path}/restored'),
    );
    await LibraryBackup(restored).restore(backup);
    expect(await KnowledgeStore(restored).quickTodos.read(), isEmpty);
  });

  test(
    'migration keeps legacy planning and completion and preserves customized notes',
    () async {
      final folder = await repository.catalog.ensureFolder('Conference');
      final now = DateTime.now();
      Future<Notebook> legacy(String title, String source, List<String> tags) =>
          repository.save(
            Notebook(
              id: LocalNotebookRepository.newId(),
              title: title,
              paper: 'markdown',
              created: now,
              modified: now,
              folderId: folder.id,
              tags: tags,
            ),
            MarkdownDocument(source).encode(),
          );
      final planned = await legacy('Slides', '- [ ] Slides\n', [
        'Quick to-do',
        'Due: 2026-11-30',
      ]);
      final done = await legacy('Room', '- [x] Room\n', [unsortedTodos]);
      final custom = await legacy('Custom', '- [ ] Custom\n\nExtra text\n', [
        unsortedTodos,
      ]);
      expect(
        await store.migrateQuickTodos(
          await repository.list(),
          isOpen: (id) => id == planned.id,
        ),
        isTrue,
      );
      expect(
        await store.migrateQuickTodos(
          await repository.list(),
          isOpen: (_) => false,
        ),
        isTrue,
      );
      expect(
        await store.migrateQuickTodos(
          await repository.list(),
          isOpen: (_) => false,
        ),
        isFalse,
      );
      expect((await repository.list()).map((n) => n.id), [custom.id]);
      final tasks = await store.quickTodos.read();
      expect(tasks.length, 2);
      expect(tasks['legacy-${planned.id}']!.project, folder.id);
      expect(tasks['legacy-${planned.id}']!.due, '2026-11-30');
      expect(tasks['legacy-${done.id}']!.done, isTrue);
    },
  );

  test(
    'task-only scans exclude PDFs with both empty and nonempty queries',
    () async {
      await store.capture('Todo', '- [ ] Review');
      await repository.create('Reference', await createPaper('blank'));
      final result = await store.scan(const KnowledgeView('', openTasks: true));
      expect(result.hits.length, 1);
      expect(result.hits.every((hit) => hit.note.isMarkdown), isTrue);
      expect(
        (await store.scan(
          const KnowledgeView('', openTasks: true, query: 'Review'),
        )).hits.length,
        1,
      );
      expect(
        (await store.scan(
          const KnowledgeView('', openTasks: true, kind: 'pdf'),
        )).hits,
        isEmpty,
      );
    },
  );

  test(
    'unchanged automatic backups remain deduplicated after scheduler restart',
    () async {
      await store.capture('Keep', 'Content');
      final first = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      await first.check();
      first.dispose();
      final second = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      await second.check();
      second.dispose();
      expect((await LibraryBackup(repository).list()).length, 1);
    },
  );

  test(
    'automatic backup status recovers without duplicating an unchanged snapshot',
    () async {
      await store.capture('Keep', 'Content');
      final first = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      await first.check();
      first.dispose();
      final failed = AutomaticBackupScheduler(
        repository,
        prepare: () async => false,
      );
      await failed.check();
      failed.dispose();
      final statusFile = File(
        '${LibraryBackup(repository).directory.path}/status.json',
      );
      expect(jsonDecode(await statusFile.readAsString())['error'], isNotNull);
      final recovered = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      await recovered.check();
      recovered.dispose();
      expect((await LibraryBackup(repository).list()).length, 1);
      expect(jsonDecode(await statusFile.readAsString())['error'], isNull);
    },
  );

  test(
    'restored views with missing folders never broaden to all files',
    () async {
      await store.capture('Original', 'Content');
      final empty = await repository.catalog.ensureFolder('Empty folder');
      store.views = [
        const KnowledgeView('Missing folder', folder: 'removed-folder'),
        KnowledgeView('Empty folder', folder: empty.id),
      ];
      await store.save();
      final bytes = await LibraryBackup(repository).snapshot();
      final targetDirectory = await Directory.systemTemp.createTemp(
        'noter-view-restore-',
      );
      try {
        final target = LocalNotebookRepository(targetDirectory);
        await LibraryBackup(target).restore(bytes);
        final settings = KnowledgeStore(target);
        await settings.load();
        for (final view in settings.views) {
          expect(view.folder, isNotEmpty);
          expect((await settings.scan(view)).hits, isEmpty);
        }
        final restoredEmpty = settings.views.singleWhere(
          (view) => view.name == 'Empty folder',
        );
        expect(target.catalog.folderName(restoredEmpty.folder), 'Empty folder');
      } finally {
        await targetDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'snapshot ordering does not depend on timestamp filename precision',
    () async {
      final backup = LibraryBackup(repository);
      await backup.directory.create(recursive: true);
      final older = File(
        '${backup.directory.path}/library-2026-11-18T10-00-00.123Z.zip',
      );
      final newer = File(
        '${backup.directory.path}/library-2026-11-18T10-00-00.123001Z.zip',
      );
      await older.writeAsBytes([]);
      await newer.writeAsBytes([]);
      await older.setLastModified(DateTime.utc(2026, 11, 18, 10, 0, 0, 123));
      await newer.setLastModified(DateTime.utc(2026, 11, 18, 10, 0, 1, 123));
      expect((await backup.list()).first.path, newer.path);
    },
  );

  test(
    'restoring a backup twice does not duplicate remapped saved views',
    () async {
      final folder = await repository.catalog.ensureFolder('Study');
      final note = await store.capture('Original', 'Content');
      await repository.save(
        note.copy(folderId: folder.id),
        await repository.load(note.id),
      );
      store.views = [KnowledgeView('Study view', folder: folder.id)];
      await store.save();
      final bytes = await LibraryBackup(repository).snapshot();
      final targetDirectory = await Directory.systemTemp.createTemp(
        'noter-repeat-restore-',
      );
      try {
        final target = LocalNotebookRepository(targetDirectory);
        final existing = KnowledgeStore(target);
        await existing.load();
        existing.views = [
          const KnowledgeView('Study view', query: 'unrelated'),
        ];
        await existing.save();
        await LibraryBackup(target).restore(bytes);
        await LibraryBackup(target).restore(bytes);
        final settings = KnowledgeStore(target);
        await settings.load();
        expect(settings.views.length, 2);
        final restored = settings.views.singleWhere(
          (view) => view.name == 'Study view (restored)',
        );
        expect(target.catalog.folderName(restored.folder), 'Study');
        expect((await target.list()).length, 2);
      } finally {
        await targetDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'invalid backup preferences are rejected before restoring any note',
    () async {
      await store.capture('Original', 'Content');
      await store.save();
      final bytes = await LibraryBackup(repository).snapshot();
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, Uint8List>{
        for (final file in archive.files)
          file.name: Uint8List.fromList(file.content),
      };
      final settings =
          jsonDecode(utf8.decode(files['settings/.knowledge.json']!))
              as Map<String, dynamic>;
      settings['automaticBackups'] = 'invalid';
      files['settings/.knowledge.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(settings)),
      );
      final manifest =
          jsonDecode(utf8.decode(files['backup.json']!))
              as Map<String, dynamic>;
      manifest['files'] = {
        for (final entry in files.entries.where(
          (entry) => entry.key != 'backup.json',
        ))
          entry.key: sha256.convert(entry.value).toString(),
      };
      files['backup.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(manifest)),
      );
      final changed = Archive();
      for (final entry in files.entries) {
        changed.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      await expectLater(
        LibraryBackup(
          repository,
        ).restore(Uint8List.fromList(ZipEncoder().encode(changed))),
        throwsFormatException,
      );
      expect((await repository.list()).length, 1);
    },
  );

  test(
    'journal creation is date-stable, serialized and never replaces existing source',
    () async {
      store.templates = [
        const MarkdownTemplate(
          'custom',
          'Daily',
          '# {{title}}\n{{weekday}} {{date}} {{year}}\n- [ ] Review',
        ),
      ];
      store.journalTemplate = 'custom';
      await store.save();
      final date = DateTime(2026, 11, 18);
      final notes = await Future.wait([
        store.journal(date),
        KnowledgeStore(repository).journal(date),
      ]);
      expect(notes.first.id, notes.last.id);
      expect((await repository.list()).length, 1);
      final document = MarkdownDocument.decode(
        await repository.load(notes.first.id),
      );
      expect(document.source, contains('Wednesday 2026-11-18 2026'));
      final renamed = await repository.save(
        notes.first.copy(title: 'A renamed journal'),
        MarkdownDocument('# Keep me\n- [ ] New task').encode(),
      );
      store.templates = [];
      expect((await store.journal(date)).id, renamed.id);
      expect(
        MarkdownDocument.decode(await repository.load(renamed.id)).source,
        '# Keep me\n- [ ] New task',
      );
    },
  );

  test(
    'journal append retries keep one entry and preserve another device-safe revision',
    () async {
      final day = DateTime(2026, 11, 19);
      final recorded = DateTime(2026, 11, 20, 9, 5);
      await Future.wait([
        store.appendJournal(
          day,
          'First',
          entryId: 'first',
          recordedAt: recorded,
        ),
        KnowledgeStore(
          repository,
        ).appendJournal(day, 'First', entryId: 'first', recordedAt: recorded),
        store.appendJournal(
          day,
          'Second',
          entryId: 'second',
          recordedAt: recorded,
        ),
      ]);
      final note = (await repository.list()).single;
      final document = MarkdownDocument.decode(await repository.load(note.id));
      expect(journalEntryDate(note), '2026-11-19');
      expect('First'.allMatches(document.source), hasLength(1));
      expect(document.source, contains('Second'));
      expect(document.source, contains('09:05'));
    },
  );

  test(
    'journal membership survives a changed title, tag and restored namespace',
    () async {
      final note = await store.journal(DateTime(2026, 11, 18));
      await repository.save(
        note.copy(title: 'My renamed day', tags: ['Daily']),
        await repository.load(note.id),
      );
      final current = (await repository.list()).single;
      expect(journalEntryDate(current), '2026-11-18');
      expect((await store.journal(DateTime(2026, 11, 18))).id, note.id);
      final bytes = await LibraryBackup(repository).snapshot();
      final copies = await LibraryBackup(repository).restore(bytes);
      expect(journalEntryDate(copies.single), '2026-11-18');
      expect((await store.journal(DateTime(2026, 11, 18))).id, note.id);
    },
  );

  test(
    'corrupt library entries are reported by search and never silently omitted from a complete backup',
    () async {
      await store.capture('Valid', '- [ ] Task');
      await File(
        '${directory.path}/broken.noter',
      ).writeAsString('Invalid archive');
      final result = await store.scan(const KnowledgeView('', openTasks: true));
      expect(result.tasks.length, 1);
      expect(result.warnings, isNotEmpty);
      await expectLater(
        LibraryBackup(repository).snapshot(),
        throwsFormatException,
      );
    },
  );

  test(
    'open tasks exclude checked boxes and code, and reject stale edits',
    () async {
      final note = await store.capture(
        'Tasks',
        '- [ ] First\n- [x] Done\n\n```\n- [ ] Example\n```\n\n> - [ ] Quoted\n',
      );
      final scan = await store.scan(
        const KnowledgeView('Tasks', openTasks: true),
      );
      expect(scan.tasks.map((t) => t.text), ['First', 'Quoted']);
      expect(scan.hits.map((h) => h.anchor), ['line=1', 'line=8']);
      await store.changeTask(scan.tasks.first);
      expect(
        (await store.scan(
          const KnowledgeView('', openTasks: true),
        )).tasks.length,
        1,
      );
      await expectLater(
        store.changeTask(scan.tasks.last),
        throwsFormatException,
      );
      expect(
        MarkdownDocument.decode(await repository.load(note.id)).source,
        contains('- [x] First'),
      );
    },
  );

  test(
    'global search finds Markdown lines and PDF pages with snippets and filters',
    () async {
      await store.capture(
        'Markdown source',
        '# Heading\n\nThe orbital keyword is here.\n- [ ] Study',
      );
      final pdf = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('A separate orbital example')));
      await repository.create('PDF source', await pdf.save());
      final result = await store.scan(
        const KnowledgeView('Search', query: 'orbital'),
      );
      expect(result.hits.length, 2);
      expect(
        result.hits.map((h) => h.anchor),
        containsAll(['line=3', 'page=1']),
      );
      expect(result.hits.every((h) => h.snippet.contains('orbital')), isTrue);
      final inbox = await store.scan(
        const KnowledgeView('Inbox', tag: 'inbox'),
      );
      expect(inbox.hits.single.note.isMarkdown, isTrue);
      final pdfOnly = await store.scan(
        const KnowledgeView('PDF', kind: 'pdf', query: 'orbital'),
      );
      expect(pdfOnly.hits.single.anchor, 'page=1');
    },
  );

  test('index survives reopening and refreshes only affected notes', () async {
    final note = await store.capture('Markdown', '# Article\n- [ ] Alpha');
    final pdf = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('Another page')))
      ..addPage(pw.Page(build: (_) => pw.Text('ALPHA a.b')));
    final pdfNote = await repository.create('Reference', await pdf.save());
    File indexEntry(Notebook item) =>
        File('${directory.path}/$knowledgeIndexFolderName/${item.id}.json');
    final markdownIndex = indexEntry(note);
    final pdfIndex = indexEntry(pdfNote);
    const alpha = KnowledgeView('', query: 'alpha');
    final cold = await store.scan(alpha);
    expect(
      cold.hits.map((hit) => hit.anchor),
      containsAll(['line=2', 'page=2']),
    );
    expect(cold.warnings, isEmpty);
    final marker = DateTime.utc(2000);
    await markdownIndex.setLastModified(marker);
    await pdfIndex.setLastModified(marker);
    final reopened = KnowledgeStore(LocalNotebookRepository(directory));
    final warm = await reopened.scan(alpha);
    expect(
      warm.hits.map((hit) => (hit.note.id, hit.anchor, hit.snippet)),
      cold.hits.map((hit) => (hit.note.id, hit.anchor, hit.snippet)),
    );
    expect((await markdownIndex.lastModified()).toUtc(), marker);
    expect((await pdfIndex.lastModified()).toUtc(), marker);
    expect(
      (await reopened.scan(
        const KnowledgeView('', query: 'a.b'),
      )).hits.single.anchor,
      'page=2',
    );

    await store.changeTask(
      cold.tasks.single.withTimer(workTime: const Duration(minutes: 3)),
    );
    const open = KnowledgeView('', openTasks: true);
    final tracked = (await reopened.scan(open)).tasks.single;
    expect(tracked.todo!.workMilliseconds, 180000);
    expect(tracked.anchor, 'line=2');
    expect((await markdownIndex.lastModified()).toUtc(), isNot(marker));
    expect((await pdfIndex.lastModified()).toUtc(), marker);

    final current = (await repository.snapshotForSync(note.id))!;
    await repository.applySync(
      note.id,
      current.raw,
      LocalNotebookRepository.encode(
        note,
        MarkdownDocument('# Article\n\n- [x] Beta').encode(),
      ),
    );
    expect((await reopened.scan(open)).hits, isEmpty);
    const completed = KnowledgeView('', query: 'bet', completedTasks: true);
    expect((await reopened.scan(completed)).hits.single.anchor, 'line=3');

    await markdownIndex.writeAsString('invalid index');
    expect((await reopened.scan(completed)).hits.single.snippet, 'Beta');
    expect(jsonDecode(await markdownIndex.readAsString()), isA<List>());

    await repository.delete(note.id);
    expect(await markdownIndex.exists(), isFalse);
    expect((await reopened.scan(completed)).hits, isEmpty);
    final restored = await repository.restore(
      (await repository.recovery()).single,
    );
    expect((await reopened.scan(completed)).hits.single.note.id, restored.id);
    await File('${directory.path}/${restored.id}.noter').delete();
    expect((await reopened.scan(completed)).hits, isEmpty);
    expect(await indexEntry(restored).exists(), isFalse);
  });

  test('scan publishes partial matches and stops between batches', () async {
    final now = DateTime.utc(2026);
    for (var i = 0; i < 130; i++) {
      final note = Notebook(
        id: 'batch-$i',
        title: 'Note $i',
        created: now,
        modified: now,
        paper: 'markdown',
      );
      File('${directory.path}/${note.id}.noter').writeAsBytesSync(
        LocalNotebookRepository.encode(
          note,
          MarkdownDocument('- [ ] Learn $i').encode(),
        ),
      );
    }
    var cancelled = false;
    final partials = <KnowledgeScan>[];
    final result = await store.scan(
      const KnowledgeView('', openTasks: true),
      cancelled: () => cancelled,
      onPartial: (partial) {
        partials.add(partial);
        cancelled = true;
      },
    );
    expect(partials.single.hits.length, inInclusiveRange(1, 64));
    expect(result.hits, partials.single.hits);
    expect(result.warnings, isEmpty);

    final index = Directory('${directory.path}/$knowledgeIndexFolderName');
    await index.delete(recursive: true);
    await File(index.path).writeAsString('No writable index directory');
    final retry = await store.scan(const KnowledgeView('', openTasks: true));
    expect(retry.hits, hasLength(130));
    expect(retry.warnings, isEmpty);
  });

  test(
    'tag merging deduplicates and updates saved filters without losing source',
    () async {
      final note = await store.capture('Tagged', '# Original');
      await repository.save(
        note.copy(tags: ['Exam', 'Study', 'study']),
        await repository.load(note.id),
      );
      store.views = [
        const KnowledgeView('Review', tag: 'Exam', openTasks: true),
      ];
      await store.renameTag('exam', 'Study');
      expect((await repository.list()).single.tags, ['Study']);
      expect(store.views.single.tag, 'Study');
      expect(
        MarkdownDocument.decode(await repository.load(note.id)).source,
        '# Original',
      );
      final reloaded = KnowledgeStore(repository);
      await reloaded.load();
      expect(reloaded.views.single.openTasks, isTrue);
      await reloaded.renameTag('Study', '');
      expect((await repository.list()).single.tags, isEmpty);
    },
  );

  test(
    'wiki links resolve titles, heading fragments and ambiguity without parsing code examples',
    () async {
      final a = await store.capture(
        'Alpha',
        '[[Beta#Target section|Read this]]\n\n`[[Ignored]]`\n\n```\n[[Ignored too]]\n```',
      );
      final b = await store.capture('Beta', '## Target section');
      final links = markdownLinks(
        MarkdownDocument.decode(await repository.load(a.id)).source,
      );
      expect(links.length, 1);
      expect(Uri.parse(links.single.href).fragment, 'target-section');
      expect(MarkdownLibrary.target([a, b], a, links.single.href)?.id, b.id);
      final duplicate = await store.capture('Beta', 'Ambiguous');
      expect(
        MarkdownLibrary.target([a, b, duplicate], a, links.single.href),
        isNull,
      );
    },
  );

  test(
    'source note quotes selection and links to a searchable PDF page',
    () async {
      final pdf = await repository.create(
        'Reference',
        await createPaper('blank', pages: 3),
      );
      final note = await store.sourceNote(
        pdf,
        2,
        'A useful\npassage & evidence',
      );
      final source = MarkdownDocument.decode(
        await repository.load(note.id),
      ).source;
      final link = markdownLinks(source).single.href;
      expect(source, contains('> A useful\n> passage & evidence'));
      expect(MarkdownLibrary.target([note, pdf], note, link)?.id, pdf.id);
      expect(markdownPdfPage(Uri.parse(link).fragment), 2);
      expect(
        markdownPdfQuote(Uri.parse(link).fragment),
        'A useful passage & evidence',
      );
      expect(note.tags, containsAll(['Source', 'Inbox']));
    },
  );

  test(
    'library backup restores linked copies, Markdown and PDF templates, and views',
    () async {
      final b = await store.capture('Destination', '# Target');
      final a = await store.capture(
        'Origin',
        '[B](<${b.documentPath}#target>)',
      );
      store.templates.add(
        const MarkdownTemplate(
          'meeting',
          'Meeting',
          '# {{title}}\n- [ ] Discuss',
        ),
      );
      store.views = [
        const KnowledgeView('Inbox tasks', tag: 'Inbox', openTasks: true),
      ];
      await store.save();
      await repository.templates.save(
        'PDF template',
        await createPaper('blank', pages: 2),
        page: 1,
      );
      final bytes = await LibraryBackup(repository).snapshot();
      final targetDirectory = await Directory.systemTemp.createTemp(
        'noter-restored-',
      );
      try {
        final target = LocalNotebookRepository(targetDirectory);
        await KnowledgeStore(target).capture('Existing', 'Never replace me');
        final restored = await LibraryBackup(target).restore(bytes);
        expect(restored.length, 2);
        final origin = restored.singleWhere((n) => n.title == a.title);
        final destination = restored.singleWhere((n) => n.title == b.title);
        final link = markdownLinks(
          MarkdownDocument.decode(await target.load(origin.id)).source,
        ).single.href;
        expect(
          MarkdownLibrary.target(restored, origin, link)?.id,
          destination.id,
        );
        expect((await target.list()).length, 3);
        final settings = KnowledgeStore(target);
        await settings.load();
        expect(settings.templates.any((t) => t.name == 'Meeting'), isTrue);
        expect(settings.views.single.name, 'Inbox tasks');
        final template = (await target.templates.list()).singleWhere(
          (t) => t.name == 'PDF template',
        );
        expect(template.kind, TemplateKind.page);
        expect(template.pageCount, 1);
        await target.flush();
      } finally {
        await targetDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'backup checksum or unsafe paths fail before restoring any note',
    () async {
      await store.capture('Safe', '# Content');
      final bytes = await LibraryBackup(repository).snapshot();
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.files.firstWhere(
        (file) => file.name.startsWith('notes/'),
      );
      final changed = Archive();
      for (final file in archive.files) {
        final data = file == entry ? utf8.encode('bad') : file.content;
        changed.addFile(ArchiveFile(file.name, data.length, data));
      }
      final before = (await repository.list()).length;
      await expectLater(
        LibraryBackup(
          repository,
        ).restore(Uint8List.fromList(ZipEncoder().encode(changed))),
        throwsFormatException,
      );
      expect((await repository.list()).length, before);
    },
  );

  test(
    'automatic backup includes quick to-dos in a library without notes',
    () async {
      final scheduler = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      addTearDown(scheduler.dispose);
      final backup = LibraryBackup(repository);
      await store.addQuickTodo('First');
      await scheduler.check();
      expect(await backup.list(), hasLength(1));
      await store.addQuickTodo('Second');
      await scheduler.check();
      expect(await backup.list(), hasLength(2));
      await scheduler.check();
      expect(await backup.list(), hasLength(2));
    },
  );

  test('an empty Markdown task hides its inline timer metadata', () {
    const source = '- [ ] <!-- notixer-task eyJsaW5rSWQiOiJ0YXNrIn0= -->\r\n';
    expect(markdownOpenTasks(source).single.text, isEmpty);
  });

  test(
    'automatic backup skips unchanged libraries, honors disable, and records errors',
    () async {
      await store.capture('Keep', 'Content');
      final scheduler = AutomaticBackupScheduler(
        repository,
        prepare: () async => true,
      );
      await scheduler.check();
      expect((await LibraryBackup(repository).list()).length, 1);
      await scheduler.check();
      expect((await LibraryBackup(repository).list()).length, 1);
      store.automaticBackups = false;
      await store.save();
      await store.capture('New', 'Changed');
      await scheduler.check();
      expect((await LibraryBackup(repository).list()).length, 1);
      scheduler.dispose();
    },
  );
}
