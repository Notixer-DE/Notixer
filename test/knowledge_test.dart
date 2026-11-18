import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/library_backup.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:pdf/widgets.dart' as pw;

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
      await store.completeTask(scan.tasks.first);
      expect(
        (await store.scan(
          const KnowledgeView('', openTasks: true),
        )).tasks.length,
        1,
      );
      await expectLater(
        store.completeTask(scan.tasks.last),
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
        await createPaper('blank'),
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
        expect(
          (await target.templates.list()).any((t) => t.name == 'PDF template'),
          isTrue,
        );
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
