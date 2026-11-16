import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/markdown_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/notebook_sync.dart';

import 'sync_scenarios.dart' show MemoryRemote;

Uint8List textBytes(String text) => Uint8List.fromList(utf8.encode(text));
Uint8List zipFiles(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalNotebookRepository repo;
  late MarkdownLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-markdown-');
    repo = LocalNotebookRepository(Directory('${root.path}/notes'));
    library = MarkdownLibrary(repo);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'Markdown, unknown syntax and binary images round trip losslessly',
    () async {
      const source =
          '# Grüße\n\n**Fett** und *kursiv*\n\n- [ ] Aufgabe\n\n'
          '[Link][ref]\n\n[ref]: https://example.org\n\n'
          '<custom data-value="keep">Unbekannt</custom>\n\n![Bild](assets/a.png)\n';
      final document = MarkdownDocument(source, {
        'assets/a.png': Uint8List.fromList([1, 2, 3]),
      });
      final decoded = MarkdownDocument.decode(document.encode());
      expect(decoded.source, source);
      expect(decoded.assets['assets/a.png'], [1, 2, 3]);
      final note = await repo.create(
        'Notiz',
        document.encode(),
        paper: 'markdown',
      );
      final (imported, bytes) = await LocalNotebookRepository.decodeValidated(
        await repo.exportArchive(note),
      );
      expect(imported.isMarkdown, true);
      expect(imported.toJson()['version'], 4);
      expect(MarkdownDocument.decode(bytes).source, source);
      expect((await repo.list()).single.title, 'Notiz');
      expect(MarkdownDocument.decode(await repo.load(note.id)).source, source);
    },
  );

  test(
    'task offsets exclude code and handle nested, quoted and ordered tasks',
    () {
      const source =
          '- [ ] oben\n'
          '  - [x] Kind\n'
          '> - [ ] Zitat\n\n'
          '1. [X] Nummer\n\n'
          '```\n- [ ] kein Task\n```\n\n'
          '    - [ ] auch Code\n\n'
          '- [ ]\n';
      final offsets = markdownTaskOffsets(source);
      expect(offsets.map((i) => source[i]).toList(), [' ', 'x', ' ', 'X', ' ']);
      for (final i in offsets) {
        expect(source[i - 1], '[');
        expect(source[i + 1], ']');
      }
    },
  );

  test(
    'parser discovers reference links, not fenced examples; headings are stable',
    () {
      const source =
          '# Grüße!\n\n# Grüße!\n\n[Notiz][n]\n\n[n]: other.md#abschnitt\n\n'
          '```\n[kein Link](code.md)\n```\n![Bild](assets/p.png)';
      expect(markdownLinks(source).map((l) => l.href), [
        'other.md#abschnitt',
        'assets/p.png',
      ]);
      expect(markdownHeadings(source), ['grüße', 'grüße-1']);
      expect(
        resolveMarkdownPath('gruppe/note.md', '../other.md#abschnitt'),
        'other.md',
      );
      expect(resolveMarkdownPath('note.md', '../../secret'), isNull);
      expect(resolveMarkdownPath('note.md', 'file:///secret'), isNull);
      expect(resolveMarkdownPath('note.md', 'https://example.org'), isNull);
      expect(
        resolveMarkdownPath('kurs/a.md', 'andere%20notiz.md'),
        'kurs/andere notiz.md',
      );
    },
  );

  test(
    'malicious paths, malformed UTF-8 and oversized Markdown are rejected',
    () async {
      for (final path in [
        '../escape',
        '/absolute',
        r'assets\escape',
        'assets/../bad',
      ]) {
        expect(
          () => MarkdownDocument('x', {path: Uint8List(1)}).encode(),
          throwsFormatException,
        );
      }
      expect(
        () => MarkdownDocument.decode(
          zipFiles({
            'document.md': Uint8List.fromList([255]),
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => MarkdownDocument(
          'x' * (MarkdownDocument.maxTextBytes + 1),
        ).encode(),
        throwsFormatException,
      );
      await expectLater(
        library.importBundle(zipFiles({'../escape.md': textBytes('x')})),
        throwsFormatException,
      );
      expect(await repo.list(), isEmpty);
    },
  );

  test(
    'rename and organization preserve relative links and backlinks',
    () async {
      final a = await library.create('A');
      final b = await library.create('B');
      final source = '[B](<${MarkdownLibrary.linkTo(a, b)}>)';
      await repo.save(a, MarkdownDocument(source).encode());
      final folder = await repo.catalog.ensureFolder('Studium');
      final renamed = await repo.save(
        b.copy(title: 'Neuer Titel', folderId: folder.id),
        await repo.load(b.id),
      );
      final notes = await repo.list();
      expect(
        MarkdownLibrary.target(notes, a, MarkdownLibrary.linkTo(a, b))?.title,
        'Neuer Titel',
      );
      expect((await library.backlinks(renamed)).single.id, a.id);
    },
  );

  test(
    'cyclic bundle with PDFs and local images reimports without link rewrites',
    () async {
      final image = Uint8List.fromList([137, 80, 78, 71]);
      final notes = await library.importBundle(
        zipFiles({
          'kurs/a.md': textBytes(
            '# A\n\n[B](b.md#grundlagen)\n![Bild](assets/p.png)\n[PDF](skript.pdf)',
          ),
          'kurs/b.md': textBytes('# B\n\n## Grundlagen\n\n[Zurück](a.md)'),
          'kurs/assets/p.png': image,
          'kurs/skript.pdf': await createPaper('blank'),
        }),
      );
      final a = notes.firstWhere((n) => n.title == 'A');
      final b = notes.firstWhere((n) => n.title == 'B');
      expect(MarkdownLibrary.target(await repo.list(), a, 'b.md')?.id, b.id);
      final exported = await library.exportBundle(a);
      final other = LocalNotebookRepository(Directory('${root.path}/other'));
      final imported = await MarkdownLibrary(other).importBundle(exported);
      final newA = imported.firstWhere((n) => n.title == 'A');
      final newB = imported.firstWhere((n) => n.title == 'B');
      expect(newA.id, isNot(a.id));
      expect(
        MarkdownLibrary.target(imported, newA, 'b.md#grundlagen')?.id,
        newB.id,
      );
      final document = MarkdownDocument.decode(await other.load(newA.id));
      expect(document.source, contains('[B](b.md#grundlagen)'));
      expect(document.assets['assets/p.png'], image);
      expect(imported.where((n) => !n.isMarkdown).length, 1);
      // The same import twice uses a new namespace, never ambiguous live paths.
      await MarkdownLibrary(other).importBundle(exported);
      expect(
        MarkdownLibrary.target(await other.list(), newA, 'b.md')?.id,
        newB.id,
      );
    },
  );

  test(
    'missing links survive import/export; unsupported bundle files fail before saving',
    () async {
      final note = await library.importText(
        'a.md',
        textBytes('[Fehlt](missing.md)\n'),
      );
      final exported = ZipDecoder().decodeBytes(
        await library.exportBundle(note),
      );
      expect(
        utf8.decode(exported.find(note.documentPath)!.content),
        '[Fehlt](missing.md)\n',
      );
      await expectLater(
        library.importBundle(
          zipFiles({'ok.md': textBytes('ok'), 'unknown.bin': Uint8List(4)}),
        ),
        throwsFormatException,
      );
      expect((await repo.list()).length, 1);
    },
  );

  test(
    'unused attachments do not make exported bundles unimportable',
    () async {
      final note = await repo.create(
        'Ohne Bild',
        MarkdownDocument('Text', {
          'assets/unused.png': Uint8List.fromList([1, 2]),
        }).encode(),
        paper: 'markdown',
      );
      final bundle = await library.exportBundle(note);
      final other = LocalNotebookRepository(Directory('${root.path}/clean'));
      final imported = await MarkdownLibrary(other).importBundle(bundle);
      expect(
        MarkdownDocument.decode(await other.load(imported.single.id)).source,
        'Text',
      );
    },
  );

  test(
    'history and trash restore Markdown and attachments as new identities',
    () async {
      final note = await library.create('Historie');
      await repo.save(note, MarkdownDocument('Neuer Stand').encode());
      final history = await repo.recovery(id: note.id);
      expect(history, isNotEmpty);
      final old = await repo.restore(history.first);
      expect(MarkdownDocument.decode(await repo.load(old.id)).source, '');
      await repo.delete(note.id);
      final trash = (await repo.recovery()).single;
      final restored = await repo.restore(trash);
      expect(restored.id, isNot(note.id));
      expect(
        MarkdownDocument.decode(await repo.load(restored.id)).source,
        'Neuer Stand',
      );
    },
  );

  test('Markdown sync and offline conflicts preserve each source', () async {
    final remote = MemoryRemote();
    final b = LocalNotebookRepository(Directory('${root.path}/b'));
    final note = await library.create('Synchronisiert');
    await NotebookSync(repo, remote).run();
    await NotebookSync(b, remote).run();
    expect((await b.list()).single.isMarkdown, true);
    await repo.save(note, MarkdownDocument('Stand A').encode());
    await b.save((await b.list()).single, MarkdownDocument('Stand B').encode());
    await NotebookSync(repo, remote).run();
    await NotebookSync(b, remote).run();
    await NotebookSync(repo, remote).run();
    final sources = <String>{};
    for (final n in await repo.list()) {
      sources.add(MarkdownDocument.decode(await repo.load(n.id)).source);
    }
    expect(sources, {'Stand A', 'Stand B'});
  });

  test(
    'autosave drains edits made during a write and retries without losing source',
    () async {
      final note = await library.create('Speichern');
      final delayed = _DelayedRepository(repo);
      final session = MarkdownSession(note, MarkdownDocument(''), delayed);
      session.update(MarkdownDocument('Erster Stand'));
      final saving = session.save();
      await delayed.started.future;
      session.update(MarkdownDocument('Zweiter Stand'));
      delayed.release.complete();
      expect(await saving, true);
      expect(session.dirty, false);
      expect(
        MarkdownDocument.decode(await repo.load(note.id)).source,
        'Zweiter Stand',
      );
      delayed.fail = true;
      session.update(MarkdownDocument('Bleibt erhalten'));
      expect(await session.save(), false);
      expect(session.document.source, 'Bleibt erhalten');
      expect(session.dirty, true);
      delayed.fail = false;
      expect(await session.save(), true);
      session.dispose();
    },
  );
}

class _DelayedRepository implements NotebookRepository {
  _DelayedRepository(this.delegate);
  final NotebookRepository delegate;
  final started = Completer<void>(), release = Completer<void>();
  bool fail = false, first = true;
  @override
  Future<Notebook> save(Notebook note, Uint8List bytes) async {
    if (first) {
      first = false;
      started.complete();
      await release.future;
    }
    if (fail) throw const FileSystemException('Disk full');
    return delegate.save(note, bytes);
  }

  @override
  Future<void> flush() => delegate.flush();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
