import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'sync_scenarios.dart' show MemoryRemote;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repository;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-recovery-');
    now = DateTime.utc(2026, 1, 1);
    repository = LocalNotebookRepository(directory, clock: () => now);
  });
  tearDown(() async {
    await repository.flush();
    await directory.delete(recursive: true);
  });

  test(
    'trash survives restart and restores PDF, tags and folder as a new copy',
    () async {
      final pdf = await createPaper('grid', pages: 3);
      final folder = await repository.catalog.ensureFolder('Studium');
      var note = await repository.create('Analysis', pdf, paper: 'grid');
      note = await repository.save(
        note.copy(folderId: folder.id, tags: ['Mathe', 'Prüfung']),
        pdf,
      );
      await repository.delete(note.id);
      final reopened = LocalNotebookRepository(directory);
      expect(await reopened.list(), isEmpty);
      expect(await reopened.syncIds(), isEmpty);
      final entry = (await reopened.recovery()).single;
      expect(entry.note.id, note.id);
      expect(await reopened.recoveryPdf(entry), pdf);
      final restored = await reopened.restore(entry);
      expect(restored.id, isNot(note.id));
      expect(restored.paper, 'grid');
      expect(restored.tags, ['Mathe', 'Prüfung']);
      expect(reopened.catalog.folderName(restored.folderId), 'Studium');
      expect(await reopened.load(restored.id), pdf);
      expect((await reopened.recovery()).single.note.id, note.id);
      expect((await reopened.list()).single.id, restored.id);
    },
  );

  test(
    'history checkpoints the previous complete archive every five minutes',
    () async {
      final first = await createPaper('blank');
      final second = await createPaper('lined', pages: 2);
      final note = await repository.create('Anfang', first);
      expect(await repository.recovery(id: note.id), isEmpty);
      await repository.save(note.copy(title: 'Zweiter Stand'), second);
      var history = await repository.recovery(id: note.id);
      expect(history.single.note.title, 'Anfang');
      expect(history.single.recorded.toUtc(), now);
      expect(await repository.recoveryPdf(history.single), first);
      now = now.add(const Duration(minutes: 1));
      await repository.save(note.copy(title: 'Dritter Stand'), first);
      expect(await repository.recovery(id: note.id), hasLength(1));
      now = now.add(const Duration(minutes: 4));
      await repository.save(note.copy(title: 'Aktuell'), second);
      final reopened = LocalNotebookRepository(directory);
      history = await reopened.recovery(id: note.id);
      expect(history.map((e) => e.note.title), ['Dritter Stand', 'Anfang']);
      final restored = await reopened.restore(history.last);
      expect(restored.id, isNot(note.id));
      expect(await reopened.load(restored.id), first);
      expect(await reopened.load(note.id), second);
      expect(
        (await reopened.list()).firstWhere((n) => n.id == note.id).title,
        'Aktuell',
      );
    },
  );

  test('retention keeps at most twenty checkpoints across restarts', () async {
    final pdf = await createPaper('blank');
    final note = await repository.create('Stand 0', pdf);
    for (var i = 1; i <= 25; i++) {
      now = now.add(LocalNotebookRepository.historyInterval);
      await repository.save(note.copy(title: 'Stand $i'), pdf);
    }
    final history = await LocalNotebookRepository(
      directory,
    ).recovery(id: note.id);
    expect(history, hasLength(LocalNotebookRepository.historyLimit));
    expect(history.first.note.title, 'Stand 24');
    expect(history.last.note.title, 'Stand 5');
  });

  test(
    'failed checkpoint prevents overwrite and does not poison the queue',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Behalten', pdf);
      final obstacle = File('${directory.path}/.history/${note.id}');
      await obstacle.parent.create(recursive: true);
      await obstacle.writeAsString('blocked');
      await expectLater(
        repository.save(note.copy(title: 'Verloren'), pdf),
        throwsA(isA<FileSystemException>()),
      );
      expect((await repository.list()).single.title, 'Behalten');
      expect(await repository.load(note.id), pdf);
      await obstacle.delete();
      await repository.save(note.copy(title: 'Gespeichert'), pdf);
      expect(
        (await repository.recovery(id: note.id)).single.note.title,
        'Behalten',
      );
    },
  );

  test(
    'retention enforces the byte budget without reading old PDF payloads',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Aktuell', pdf);
      final history = Directory('${directory.path}/.history/${note.id}');
      await history.create(recursive: true);
      // Sparse fixtures exercise size-based eviction without allocating 600 MiB
      // of PDF data. Retention must inspect file sizes, not decode these payloads.
      for (var i = 0; i < 3; i++) {
        final file = File('${history.path}/large-$i.noter');
        final handle = await file.open(mode: FileMode.write);
        await handle.truncate(200 * 1024 * 1024);
        await handle.close();
        await file.setLastModified(now.subtract(Duration(minutes: 15 - i * 5)));
      }
      await repository.save(note.copy(title: 'Neu'), pdf);
      final files = history.listSync().whereType<File>().toList();
      expect(files, hasLength(3));
      expect(File('${history.path}/large-0.noter').existsSync(), isFalse);
      expect(
        files.fold<int>(0, (size, file) => size + file.lengthSync()),
        lessThanOrEqualTo(LocalNotebookRepository.historyByteLimit),
      );
      expect(await repository.load(note.id), pdf);
    },
  );

  test(
    'failed save preserves live document and recoverable previous archive',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Behalten', pdf);
      final obstacle = Directory('${directory.path}/${note.id}.noter.tmp');
      await obstacle.create();
      await expectLater(
        repository.save(note.copy(title: 'Nicht geschrieben'), pdf),
        throwsA(isA<FileSystemException>()),
      );
      expect((await repository.list()).single.title, 'Behalten');
      final entry = (await repository.recovery(id: note.id)).single;
      expect(await repository.recoveryPdf(entry), pdf);
      await obstacle.delete();
      await repository.save(note.copy(title: 'Jetzt geschrieben'), pdf);
      expect((await repository.list()).single.title, 'Jetzt geschrieben');
    },
  );

  test('failed trash move leaves the document intact', () async {
    final note = await repository.create(
      'Behalten',
      await createPaper('blank'),
    );
    await File('${directory.path}/.trash').writeAsString('blocked');
    await expectLater(
      repository.delete(note.id),
      throwsA(isA<FileSystemException>()),
    );
    expect((await repository.list()).single.id, note.id);
  });

  test(
    'explicit cleanup removes trash and history without deleting restored copies',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Original', pdf);
      await repository.save(note.copy(title: 'Neu'), pdf);
      await repository.clearHistory(note.id);
      expect(await repository.recovery(id: note.id), isEmpty);
      expect(await repository.load(note.id), pdf);
      now = now.add(LocalNotebookRepository.historyInterval);
      await repository.save(note, pdf);
      await repository.delete(note.id);
      final restored = await repository.restore(
        (await repository.recovery()).single,
      );
      await repository.purgeTrash(note.id);
      expect(await repository.recovery(), isEmpty);
      expect(await repository.recovery(id: note.id), isEmpty);
      expect(await repository.load(restored.id), pdf);
      await expectLater(
        repository.clearHistory('../escape'),
        throwsFormatException,
      );
      await expectLater(
        repository.purgeTrash('../escape'),
        throwsFormatException,
      );
    },
  );

  test(
    'sync replacements are checkpointed and compare-and-swap precedes recovery writes',
    () async {
      final first = await createPaper('blank');
      final second = await createPaper('lined');
      final note = await repository.create('Lokal', first);
      final snapshot = (await repository.snapshotForSync(note.id))!;
      final remote = LocalNotebookRepository.encode(
        note.copy(title: 'Remote'),
        second,
      );
      await expectLater(
        repository.applySync(note.id, null, remote),
        throwsStateError,
      );
      expect(await repository.recovery(id: note.id), isEmpty);
      await repository.applySync(note.id, snapshot.raw, remote);
      final history = await repository.recovery(id: note.id);
      expect(history.single.note.title, 'Lokal');
      expect(await repository.recoveryPdf(history.single), first);
      expect(await repository.load(note.id), second);
      final current = (await repository.snapshotForSync(note.id))!;
      await repository.applySync(note.id, current.raw, null);
      expect(await repository.list(), isEmpty);
      expect(
        await repository.recoveryPdf((await repository.recovery()).single),
        second,
      );
    },
  );

  test(
    'two-device sync keeps deletions deleted and restores under a fresh identity',
    () async {
      final other = LocalNotebookRepository(
        Directory('${directory.path}/other'),
      );
      final remote = MemoryRemote();
      Future<void> sync(LocalNotebookRepository repo) async {
        await NotebookSync(repo, remote).run();
      }

      final pdf = await createPaper('grid', pages: 2);
      final note = await repository.create('Synchronisiert', pdf);
      await sync(repository);
      await sync(other);
      await repository.delete(note.id);
      await sync(repository);
      await sync(other);
      expect(await other.list(), isEmpty);
      final otherTrash = (await other.recovery()).single;
      expect(await other.recoveryPdf(otherTrash), pdf);
      await sync(repository);
      await sync(other);
      expect(await repository.list(), isEmpty);
      expect(await other.list(), isEmpty);
      final restored = await other.restore(otherTrash);
      await sync(other);
      await sync(repository);
      expect((await repository.list()).single.id, restored.id);
      expect((await other.list()).single.id, restored.id);
      expect(restored.id, isNot(note.id));
      expect(await repository.load(restored.id), pdf);
      await repository.purgeTrash(note.id);
      await sync(repository);
      await sync(other);
      expect((await repository.list()).single.id, restored.id);
      expect((await other.list()).single.id, restored.id);
    },
  );
}
