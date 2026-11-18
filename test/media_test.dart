import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/library_backup.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/media.dart';
import 'package:noter/data/media_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'sync_scenarios.dart';

final samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);
final sampleAudio = Uint8List.fromList([
  0,
  0,
  0,
  24,
  ...'ftypM4A '.codeUnits,
  0,
  0,
  0,
  0,
]);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalNotebookRepository a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('notixer-media-');
    a = LocalNotebookRepository(Directory('${root.path}/a'));
    b = LocalNotebookRepository(Directory('${root.path}/b'));
  });
  tearDown(() async {
    await a.flush();
    await b.flush();
    await root.delete(recursive: true);
  });
  test(
    'media survives folders, archive, backup, sync, deletion and restore',
    () async {
      final folder = await a.catalog.ensureFolder('Recordings');
      var note = await a.create('Voice', sampleAudio, paper: 'media:m4a');
      note = await a.save(
        note.copy(folderId: folder.id, tags: ['Lecture']),
        sampleAudio,
      );
      expect(note.isPdf, false);
      expect(note.isMedia, true);
      expect(note.documentPath, endsWith('.m4a'));
      final decoded = await LocalNotebookRepository.decodeValidated(
        await a.exportArchive(note),
      );
      expect(decoded.$1.mediaFormat!.kind, 'audio');
      expect(decoded.$2, sampleAudio);
      final remote = MemoryRemote();
      await NotebookSync(a, remote).run();
      await NotebookSync(b, remote).run();
      final copy = (await b.list()).single;
      expect(copy.tags, ['Lecture']);
      expect(b.catalog.folderName(copy.folderId), 'Recordings');
      expect(await b.load(copy.id), sampleAudio);
      final backup = await LibraryBackup(a).snapshot();
      final restored = await LibraryBackup(b).restore(backup);
      expect(restored, isNotEmpty);
      await a.delete(note.id);
      final trash = await a.recovery();
      final recovered = await a.restore(trash.single);
      expect(recovered.id, isNot(note.id));
      expect(await a.load(recovered.id), sampleAudio);
      final tasks = await KnowledgeStore(
        a,
      ).scan(const KnowledgeView('Tasks', openTasks: true));
      expect(tasks.hits, isEmpty);
      expect(tasks.warnings, isEmpty);
    },
  );
  test(
    'Markdown audio attachments and links to standalone media export and reimport',
    () async {
      var note = await MarkdownLibrary(a).create('Meeting');
      final image = await a.create('Photo', samplePng, paper: 'media:png');
      final (doc, path) = MarkdownDocument(
        '',
      ).withAttachment(sampleAudio, 'm4a');
      note = await a.save(
        note,
        doc
            .copy(
              source:
                  '[Voice]($path)\n\n[Photo](${MarkdownLibrary.linkTo(note, image)})',
            )
            .encode(),
      );
      final bundle = await MarkdownLibrary(a).exportBundle(note);
      final imported = await MarkdownLibrary(b).importBundle(bundle);
      expect(
        imported.where((n) => n.isMedia).single.mediaFormat!.kind,
        'image',
      );
      final text = imported.where((n) => n.isMarkdown).single;
      final restored = MarkdownDocument.decode(await b.load(text.id));
      expect(restored.assets[path], sampleAudio);
      expect(
        MarkdownLibrary.target(
          imported,
          text,
          markdownLinks(restored.source).last.href,
        )?.isMedia,
        true,
      );
    },
  );
  test(
    'media validation rejects renamed data and capture files are consumed safely',
    () async {
      expect(
        () => MediaFormat.of('mp3')!.validate(samplePng),
        throwsFormatException,
      );
      expect(
        () => MarkdownDocument('').withAttachment(Uint8List(0), 'm4a'),
        throwsFormatException,
      );
      final file = File('${root.path}/camera.png');
      await file.writeAsBytes(samplePng);
      final media = await MediaGateway.consumeCapture(file.path);
      expect(media.bytes, samplePng);
      expect(await file.exists(), true);
      await media.release();
      expect(await file.exists(), false);
      await file.writeAsBytes(samplePng);
      await expectLater(
        MediaGateway.consumeCapture(file.path, limit: 1),
        throwsFormatException,
      );
      expect(await file.exists(), false);
    },
  );
}
