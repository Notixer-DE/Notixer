import "dart:typed_data";
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/drawing_preferences.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/library_extras_sync.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/sync_revision.dart';
import 'sync_scenarios.dart';

class CountingRemote extends MemoryRemote {
  int downloads = 0, discoveries = 0;
  @override
  Future<List<SyncRevision>> list() {
    discoveries++;
    return super.list();
  }

  @override
  Future<Uint8List> download(SyncRevision revision) {
    downloads++;
    return super.download(revision);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalNotebookRepository a, b;
  late CountingRemote remote;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('notixer-extras-');
    a = LocalNotebookRepository(Directory('${root.path}/a'));
    b = LocalNotebookRepository(Directory('${root.path}/b'));
    remote = CountingRemote();
  });
  tearDown(() async {
    await a.flush();
    await b.flush();
    await root.delete(recursive: true);
  });
  Future<SyncReport> sync(LocalNotebookRepository repo) async {
    final session = SyncSessionRemote(remote);
    await NotebookSync(repo, session).run();
    return LibraryExtrasSync(repo, session).run();
  }

  test(
    'full sync includes templates, empty folders, views, tool state, reading and display choices',
    () async {
      final folder = await a.catalog.ensureFolder('Empty folder');
      await a.catalog.setPreset(
        0,
        const PenPreset('Fine', 'ink', 0xff123456, 1.5, .8),
      );
      await a.catalog.drawingPreferences.setWholeStrokeEraser(true);
      a.catalog.drawingPreferences.rememberTool(
        const DrawingToolChoice('ink', 0xff123456, 3, .7),
      );
      await a.catalog.readingPositions.save({'some-note': 5});
      await a.catalog.displayPreferences.set('readingZoom', 1.4);
      final store = KnowledgeStore(a);
      await store.load();
      store.templates.add(
        const MarkdownTemplate('meeting', 'Meeting', '## Agenda\n- [ ] Talk'),
      );
      store.journalTemplate = 'meeting';
      store.views.add(KnowledgeView('Folder view', folder: folder.id));
      await store.save();
      final pdf = await a.templates.save(
        'PDF page',
        await createPaper('blank'),
        page: 0,
      );
      await sync(a);
      await sync(b);
      final copy = KnowledgeStore(b);
      await copy.load();
      expect(copy.templates.map((t) => t.id), contains('meeting'));
      expect(copy.journalTemplate, 'meeting');
      expect(b.catalog.folderName(copy.views.single.folder), 'Empty folder');
      expect(b.catalog.presets.first.name, 'Fine');
      expect(b.catalog.drawingPreferences.wholeStrokeEraser, true);
      expect(b.catalog.drawingPreferences.lastTool!.width, 3);
      expect(b.catalog.readingPositions.pageFor('some-note', 20), 5);
      expect(b.catalog.displayPreferences.zoom('readingZoom'), 1.4);
      expect(
        (await b.templates.list()).where((t) => !t.builtIn).single.id,
        pdf.id,
      );
      expect(
        await b.list(),
        isEmpty,
        reason: 'Staging records are not library documents',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      remote.downloads = 0;
      remote.discoveries = 0;
      final result = await sync(b);
      expect(result.uploaded, 0);
      expect(result.downloaded, 0);
      expect(remote.downloads, 0);
      expect(remote.discoveries, 1);
    },
  );
  test(
    'independent settings merge and template deletions reach the other device',
    () async {
      final store = KnowledgeStore(a);
      await store.load();
      store.templates.add(const MarkdownTemplate('custom', 'Custom', 'Hello'));
      await store.save();
      await sync(a);
      await sync(b);
      await a.catalog.drawingPreferences.setWholeStrokeEraser(true);
      await b.catalog.drawingPreferences.setStraightStrokes(true);
      await sync(a);
      await sync(b);
      await sync(a);
      expect(a.catalog.drawingPreferences.straightStrokes, true);
      expect(b.catalog.drawingPreferences.wholeStrokeEraser, true);
      await store.reload();
      store.templates.removeWhere((t) => t.id == 'custom');
      await store.save();
      await sync(a);
      await sync(b);
      final copy = KnowledgeStore(b);
      await copy.load();
      expect(copy.templates.any((t) => t.id == 'custom'), false);
    },
  );
  test(
    'concurrent template edits preserve both variants without exposing staging notes',
    () async {
      final initial = KnowledgeStore(a);
      await initial.load();
      initial.templates = [const MarkdownTemplate('x', 'Shared', 'Original')];
      await initial.save();
      await sync(a);
      await sync(b);
      final aa = KnowledgeStore(a), bb = KnowledgeStore(b);
      await aa.load();
      await bb.load();
      aa.templates = [const MarkdownTemplate('x', 'Shared', 'From A')];
      bb.templates = [const MarkdownTemplate('x', 'Shared', 'From B')];
      await aa.save();
      await bb.save();
      await sync(a);
      await sync(b);
      await sync(a);
      await sync(b);
      await aa.reload();
      await bb.reload();
      expect(aa.templates.map((t) => t.source).toSet(), {'From A', 'From B'});
      expect(bb.templates.map((t) => t.source).toSet(), {'From A', 'From B'});
      expect(await a.list(), isEmpty);
      expect(await b.list(), isEmpty);
    },
  );
  test(
    'settings-only automatic sync skips discovery when the local fingerprint is unchanged',
    () async {
      await a.catalog.readingPositions.saveMarkdown('a', 125);
      await LibraryExtrasSync(a, remote).run();
      remote.discoveries = 0;
      await LibraryExtrasSync(a, remote).run(onlyIfChanged: true);
      expect(remote.discoveries, 0);
      await a.catalog.readingPositions.saveMarkdown('a', 250);
      await LibraryExtrasSync(a, remote).run(onlyIfChanged: true);
      expect(remote.discoveries, 1);
      await LibraryExtrasSync(b, remote).run();
      expect(b.catalog.readingPositions.markdownOffset('a'), 250);
    },
  );
  test(
    'concurrent setting values remain visible as conflict notes and retries settle',
    () async {
      a.catalog.drawingPreferences.rememberTool(
        const DrawingToolChoice('ink', 0xff000000, 1, 1),
      );
      await sync(a);
      await sync(b);
      a.catalog.drawingPreferences.rememberTool(
        const DrawingToolChoice('ink', 0xff000000, 2, 1),
      );
      b.catalog.drawingPreferences.rememberTool(
        const DrawingToolChoice('ink', 0xff000000, 3, 1),
      );
      await sync(a);
      await sync(b);
      await sync(a);
      await sync(b);
      expect(
        a.catalog.drawingPreferences.lastTool,
        b.catalog.drawingPreferences.lastTool,
      );
      expect(
        (await a.list()).where((n) => n.tags.contains('Sync conflict')),
        isNotEmpty,
      );
      final result = await sync(b);
      expect(result.uploaded, 0);
      expect(result.conflicts, 0);
    },
  );
  test(
    'an external settings write aborts application and a retry retains both template edits',
    () async {
      final aa = KnowledgeStore(a);
      await aa.load();
      aa.templates = [const MarkdownTemplate('x', 'Shared', 'Original')];
      await aa.save();
      await sync(a);
      await sync(b);
      aa.templates = [const MarkdownTemplate('x', 'Shared', 'Remote edit')];
      await aa.save();
      await sync(a);
      final bb = KnowledgeStore(b);
      await bb.load();
      remote.beforeDownload = () async {
        remote.beforeDownload = null;
        bb.templates = [
          const MarkdownTemplate('x', 'Shared', 'External local edit'),
        ];
        await bb.save();
      };
      await expectLater(
        LibraryExtrasSync(b, remote).run(),
        throwsA(isA<SyncFailure>()),
      );
      expect(
        jsonDecode(await bb.file.readAsString())['templates'][0]['source'],
        'External local edit',
      );
      await sync(b);
      await sync(a);
      await aa.reload();
      await bb.reload();
      expect(bb.templates.map((t) => t.source).toSet(), {
        'External local edit',
        'Remote edit',
      });
      expect(aa.templates.map((t) => t.source).toSet(), {
        'External local edit',
        'Remote edit',
      });
    },
  );
  test(
    'unchanged document sync reuses the local winner and transfers no payload',
    () async {
      await a.create('PDF', await createPaper('blank'));
      await NotebookSync(a, remote).run();
      expect(
        remote.downloads,
        0,
        reason: 'Do not download a document just uploaded by this device',
      );
      await NotebookSync(b, remote).run();
      remote.downloads = 0;
      await NotebookSync(a, remote).run();
      await NotebookSync(b, remote).run();
      expect(remote.downloads, 0);
    },
  );
  test(
    'corrupt or missing optional preferences never delete synced choices or folders',
    () async {
      await a.catalog.ensureFolder('Keep this folder');
      await a.catalog.displayPreferences.set('readingZoom', 1.5);
      await a.catalog.drawingPreferences.setWholeStrokeEraser(true);
      await a.catalog.readingPositions.saveMarkdown('note', 180);
      await sync(a);
      await sync(b);
      await File(
        '${b.directory.path}/.display-preferences.json',
      ).writeAsString('{broken');
      await File(
        '${b.directory.path}/.drawing-preferences.json',
      ).writeAsString('{broken');
      await File(
        '${b.directory.path}/.reading-positions.json',
      ).writeAsString('{broken');
      b = LocalNotebookRepository(b.directory);
      await sync(b);
      await sync(a);
      expect(b.catalog.folders.single.name, 'Keep this folder');
      expect(b.catalog.displayPreferences.zoom('readingZoom'), 1.5);
      expect(b.catalog.drawingPreferences.wholeStrokeEraser, true);
      expect(b.catalog.readingPositions.markdownOffset('note'), 180);
      expect(
        await File(
          '${b.directory.path}/.display-preferences.json.invalid',
        ).exists(),
        true,
      );
      expect(a.catalog.displayPreferences.zoom('readingZoom'), 1.5);
    },
  );
  test(
    'folder casing converges and does not generate repeated preference revisions',
    () async {
      await a.catalog.ensureFolder('Studies');
      await b.catalog.ensureFolder('studies');
      await sync(a);
      await sync(b);
      await sync(a);
      await sync(b);
      await sync(a);
      expect(a.catalog.folders.single.name, b.catalog.folders.single.name);
      final report = await sync(b);
      expect(report.uploaded, 0);
      expect(report.conflicts, 0);
    },
  );
}
