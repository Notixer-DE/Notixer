import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/sync_revision.dart';

import 'sync_scenarios.dart';

class _TrackingRepository extends LocalNotebookRepository {
  _TrackingRepository(super.directory);
  final snapshots = <String>[];

  @override
  Future<({Uint8List raw, Uint8List archive})?> snapshotForSync(
    String id,
  ) async {
    snapshots.add(id);
    return super.snapshotForSync(id);
  }
}

class _TrackingRemote extends MemoryRemote {
  int listings = 0;
  final downloads = <String>[];

  @override
  Future<List<SyncRevision>> list() async {
    listings++;
    return super.list();
  }

  @override
  Future<Uint8List> download(SyncRevision revision) {
    downloads.add(revision.noteId);
    return super.download(revision);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _TrackingRepository local;
  late LocalNotebookRepository other;
  late _TrackingRemote remote;
  late Notebook a, b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-scoped-sync-');
    local = _TrackingRepository(Directory('${root.path}/local'));
    other = LocalNotebookRepository(Directory('${root.path}/other'));
    remote = _TrackingRemote();
    a = await MarkdownLibrary(local).create('A');
    b = await MarkdownLibrary(local).create('B');
    await NotebookSync(local, remote).run();
    await NotebookSync(other, remote).run();
    local.snapshots.clear();
    remote.downloads.clear();
    remote.listings = 0;
  });
  tearDown(() => root.delete(recursive: true));

  Future<SyncReport> automatic(String id) =>
      NotebookSync(local, remote).run(noteId: id, onlyIfChanged: true);

  test(
    'only the changed note is read and uploaded; full sync remains available',
    () async {
      await local.save(a.copy(title: 'A edited'), await local.load(a.id));
      await local.save(b.copy(title: 'B pending'), await local.load(b.id));
      final previous = remote.revisions.keys.toSet();
      final report = await automatic(a.id);
      expect(report.uploaded, 1);
      expect(local.snapshots.toSet(), {a.id});
      expect(remote.downloads, everyElement(a.id));
      expect(
        remote.revisions.values
            .where((r) => !previous.contains(r.revision))
            .map((r) => r.noteId),
        [a.id],
      );
      expect((await automatic(a.id)).uploaded, 0);
      expect((await NotebookSync(local, remote).run()).uploaded, 1);
    },
  );

  test('unchanged note does not discover or download remote changes', () async {
    final notes = await other.list();
    for (final note in notes) {
      await other.save(
        note.copy(title: '${note.title} remote'),
        await other.load(note.id),
      );
    }
    await NotebookSync(other, remote).run();
    remote.listings = 0;
    remote.downloads.clear();
    final report = await automatic(a.id);
    expect(report.uploaded, 0);
    expect(report.downloaded, 0);
    expect(remote.listings, 0);
    expect(remote.downloads, isEmpty);
    expect((await local.list()).map((n) => n.title), containsAll(['A', 'B']));
    expect((await NotebookSync(local, remote).run()).downloaded, 2);
  });

  test('a scoped deletion leaves another pending edit untouched', () async {
    await local.delete(a.id);
    await local.save(b.copy(title: 'B pending'), await local.load(b.id));
    final previous = remote.revisions.keys.toSet();
    await automatic(a.id);
    final added = remote.revisions.values
        .where((r) => !previous.contains(r.revision))
        .toList();
    expect(added, hasLength(1));
    expect(added.single.noteId, a.id);
    expect(added.single.deleted, true);
    expect((await automatic(a.id)).uploaded, 0);
    expect((await NotebookSync(local, remote).run()).uploaded, 1);
  });

  test('offline failure can be retried without syncing other notes', () async {
    await local.save(a.copy(title: 'A offline'), await local.load(a.id));
    await local.save(b.copy(title: 'B pending'), await local.load(b.id));
    remote.offline = true;
    await expectLater(automatic(a.id), throwsA(isA<SocketException>()));
    remote.offline = false;
    expect((await automatic(a.id)).uploaded, 1);
    expect(local.snapshots.toSet(), {a.id});
    expect((await NotebookSync(local, remote).run()).uploaded, 1);
  });

  test(
    'scoped conflicts preserve both edits without uploading another note',
    () async {
      final counterpart = (await other.list()).singleWhere((n) => n.id == a.id);
      await other.save(
        counterpart.copy(title: 'A remote'),
        await other.load(a.id),
      );
      await NotebookSync(other, remote).run();
      await local.save(a.copy(title: 'A local'), await local.load(a.id));
      await local.save(b.copy(title: 'B pending'), await local.load(b.id));
      final previous = remote.revisions.keys.toSet();
      final report = await automatic(a.id);
      expect(report.conflicts, 1);
      final added = remote.revisions.values
          .where((r) => !previous.contains(r.revision))
          .toList();
      expect(added.any((r) => r.noteId == b.id), false);
      final titles = (await local.list()).map((n) => n.title);
      expect(titles.any((t) => t.startsWith('A local')), true);
      expect(titles.any((t) => t.startsWith('A remote')), true);
      expect(local.snapshots, isNot(contains(b.id)));
      expect((await automatic(a.id)).uploaded, 0);
      expect((await NotebookSync(local, remote).run()).uploaded, 1);
    },
  );
}
