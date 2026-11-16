import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/sync_revision.dart';

void expectSync(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class MemoryRemote implements RevisionRemote {
  final revisions = <String, SyncRevision>{};
  final data = <String, Uint8List>{};
  bool offline = false;
  List<SyncRevision>? frozenList;
  Future<void> Function()? beforeDownload;
  @override
  Future<String> accountId() async => 'test-server-account';
  @override
  Future<List<SyncRevision>> list() async {
    if (offline) throw const SocketException('offline');
    return frozenList ?? revisions.values.toList();
  }

  @override
  Future<void> upload(SyncRevision revision, Uint8List bytes) async {
    if (offline) throw const SocketException('offline');
    revisions[revision.revision] = revision;
    data[revision.revision] = bytes;
  }

  @override
  Future<Uint8List> download(SyncRevision revision) async {
    await beforeDownload?.call();
    return data[revision.revision]!;
  }
}

Future<void> verifySync(Directory root) async {
  final a = LocalNotebookRepository(Directory('${root.path}/a'));
  final b = LocalNotebookRepository(Directory('${root.path}/b'));
  final c = LocalNotebookRepository(Directory('${root.path}/c'));
  final remote = MemoryRemote();
  Future<SyncReport> sync(LocalNotebookRepository repo) =>
      NotebookSync(repo, remote).run();
  final folder = await a.catalog.ensureFolder('Studium');
  var note = await a.create(
    'Analysis',
    await createPaper('grid'),
    paper: 'grid',
  );
  note = await a.save(
    note.copy(folderId: folder.id, folderName: folder.name, tags: ['Mathe']),
    await a.load(note.id),
  );
  expectSync((await sync(a)).uploaded == 1, 'First sync uploads once');
  await sync(b);
  var other = (await b.list()).single;
  expectSync(
    other.id == note.id &&
        other.tags.single == 'Mathe' &&
        b.catalog.folderName(other.folderId) == 'Studium',
    'Portable metadata',
  );
  final count = remote.revisions.length;
  await sync(a);
  await sync(b);
  expectSync(count == remote.revisions.length, 'No-op uploads nothing');
  await a.catalog.renameFolder(folder.id, 'Uni');
  await sync(a);
  await sync(b);
  expectSync(
    b.catalog.folderName((await b.list()).single.folderId) == 'Uni',
    'Folder rename transfers',
  );

  note = (await a.list()).single;
  other = (await b.list()).single;
  await a.save(note.copy(title: 'Tablet'), await a.load(note.id));
  await b.save(other.copy(title: 'Laptop'), await b.load(other.id));
  remote.frozenList = await remote.list();
  await sync(a);
  await sync(b);
  remote.frozenList = null;
  expectSync((await sync(a)).conflicts == 1, 'Parallel edits create conflict');
  await sync(b);
  await sync(c);
  final titles = (await a.list()).map((n) => n.title).toList()..sort();
  expectSync(
    titles.length == 2 &&
        titles.any((t) => t.startsWith('Tablet')) &&
        titles.any((t) => t.startsWith('Laptop')),
    'Both edits survive',
  );
  for (final repo in [b, c]) {
    final actual = (await repo.list()).map((n) => n.title).toList()..sort();
    expectSync(jsonEncode(actual) == jsonEncode(titles), 'Devices converge');
  }
  final resolved = remote.revisions.length;
  await sync(a);
  await sync(b);
  expectSync(resolved == remote.revisions.length, 'Resolution is idempotent');
  await a.delete(note.id);
  await sync(a);
  await sync(b);
  await sync(c);
  expectSync(
    !(await b.list()).any((n) => n.id == note.id),
    'Deletion transfers',
  );

  var survivor = (await a.list()).single;
  remote.offline = true;
  await a.save(survivor.copy(title: 'Offline'), await a.load(survivor.id));
  var failed = false;
  try {
    await sync(a);
  } on SocketException {
    failed = true;
  }
  expectSync(
    failed && (await a.list()).single.title == 'Offline',
    'Offline preserves edits',
  );
  remote.offline = false;
  await sync(a);
  await sync(b);
  expectSync(
    (await b.list()).single.title == 'Offline',
    'Retry transfers edit',
  );
  other = (await b.list()).single;
  await a.delete(other.id);
  await b.save(other.copy(title: 'Edit versus delete'), await b.load(other.id));
  remote.frozenList = await remote.list();
  await sync(a);
  await sync(b);
  remote.frozenList = null;
  await sync(a);
  await sync(b);
  expectSync(
    (await a.list()).single.title == 'Edit versus delete',
    'Live edit survives deletion',
  );

  survivor = (await a.list()).single;
  await a.save(survivor.copy(title: 'New revision'), await a.load(survivor.id));
  await sync(a);
  final last = remote.revisions.values.last;
  final intact = remote.data[last.revision]!;
  remote.data[last.revision] = Uint8List.fromList([1, 2, 3]);
  failed = false;
  try {
    await sync(b);
  } catch (_) {
    failed = true;
  }
  expectSync(
    failed && (await b.list()).single.title == 'Edit versus delete',
    'Corrupt download preserves local data',
  );
  remote.data[last.revision] = intact;
  remote.beforeDownload = () async {
    remote.beforeDownload = null;
    final n = (await b.list()).single;
    await b.save(n.copy(title: 'Concurrent local edit'), await b.load(n.id));
  };
  failed = false;
  try {
    await sync(b);
  } on StateError {
    failed = true;
  }
  expectSync(
    failed && (await b.list()).single.title == 'Concurrent local edit',
    'Compare-and-swap protects local edits',
  );
  await sync(b);
  await sync(a);
  expectSync((await a.list()).length == 2, 'Retry preserves both versions');
  final removed = remote.revisions.keys.first;
  final revision = remote.revisions.remove(removed)!;
  failed = false;
  try {
    await sync(c);
  } on SyncFailure {
    failed = true;
  }
  expectSync(failed, 'Missing parents abort before replacement');
  remote.revisions[removed] = revision;
}
