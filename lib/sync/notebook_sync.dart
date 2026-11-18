import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../data/notebook.dart';
import '../data/learning.dart';
import 'sync_revision.dart';

String archiveDigest(Uint8List bytes) {
  final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(bytes);
  final json = note.toJson()..remove('folderId');
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'note': json,
            'pdf': sha256.convert(pdf).toString(),
            if (ink != null) 'ink': sha256.convert(ink.encode()).toString(),
          }),
        ),
      )
      .toString();
}

Future<String> archiveDigestAsync(Uint8List bytes) =>
    Isolate.run(() => archiveDigest(bytes), debugName: 'noter:archive-digest');

/// Assessments and their save timestamp do not constitute a document conflict.
/// Keep the existing conflict-copy rule for actual PDF/organization edits.
Future<String> _documentDigest(Uint8List bytes) {
  final transfer = TransferableTypedData.fromList([bytes]);
  return Isolate.run(() {
    final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(
      transfer.materialize().asUint8List(),
    );
    final json = note.toJson()
      ..remove('folderId')
      ..remove('version')
      ..remove('learning')
      ..remove('modified');
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'note': json,
              'pdf': sha256.convert(pdf).toString(),
              if (ink != null) 'ink': sha256.convert(ink.encode()).toString(),
            }),
          ),
        )
        .toString();
  }, debugName: 'noter:sync-document-digest');
}

Future<LearningProgress> _mergeLearning(
  LearningProgress a,
  LearningProgress b,
) => Isolate.run(() => a.merge(b), debugName: 'noter:merge-assessments');

Future<(String, String)> _inspectArchive(Uint8List bytes) {
  final transfer = TransferableTypedData.fromList([bytes]);
  return _inspectTransferred(transfer);
}

Future<(String, String)> _inspectTransferred(TransferableTypedData bytes) =>
    Isolate.run(() {
      final raw = bytes.materialize().asUint8List();
      final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(raw);
      validateNotebookContent(note, pdf);
      final json = note.toJson()..remove('folderId');
      return (
        sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'note': json,
                  'pdf': sha256.convert(pdf).toString(),
                  if (ink != null)
                    'ink': sha256.convert(ink.encode()).toString(),
                }),
              ),
            )
            .toString(),
        note.id,
      );
    }, debugName: 'noter:sync-digest');

final deletedDigest = sha256
    .convert(utf8.encode('noter:deleted:v1'))
    .toString();

class SyncReport {
  int uploaded = 0, downloaded = 0, deleted = 0, conflicts = 0;
  @override
  String toString() =>
      '$uploaded uploaded · $downloaded downloaded · '
      '$deleted deleted · $conflicts conflict copies';
}

/// Sync is explicitly scoped to the library: open editors are closed/flushed
/// before entry. Compare-and-swap also protects against external local writers.
class NotebookSync {
  NotebookSync(
    this.repository,
    this.remote, {
    this.onProgress,
    this.extras = false,
  });
  final LocalNotebookRepository repository;
  final RevisionRemote remote;
  final bool extras;
  final void Function(String)? onProgress;
  bool _running = false;

  /// With [noteId], only reconcile this note and any resulting conflict copies.
  /// [onlyIfChanged] skips even remote discovery when the local baseline matches.
  Future<SyncReport> run({String? noteId, bool onlyIfChanged = false}) async {
    if (_running) throw const SyncFailure('Sync is already running.');
    _running = true;
    try {
      return await _run(noteId: noteId, onlyIfChanged: onlyIfChanged);
    } finally {
      _running = false;
    }
  }

  Future<SyncReport> _run({String? noteId, required bool onlyIfChanged}) async {
    final report = SyncReport();
    onProgress?.call('Checking the account and local notes …');
    final localIds = (await repository.syncIds()).toSet();
    // A stale manual selection must not become a deletion. Automatic sync
    // must still be able to publish a locally deleted note.
    if (noteId != null && !onlyIfChanged && !localIds.contains(noteId)) {
      throw const SyncFailure(
        'The selected note no longer exists. Please select it again.',
      );
    }
    final account = sha256
        .convert(utf8.encode(await remote.accountId()))
        .toString();
    final stateFile = File(
      '${repository.directory.path}/.sync-state-$account.json',
    );
    var state = <String, dynamic>{};
    if (await stateFile.exists()) {
      final json =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      if (json['version'] != 1) {
        throw const FormatException('Unknown sync state.');
      }
      state = Map<String, dynamic>.from(json['notes'] as Map);
    }
    if (noteId != null && onlyIfChanged) {
      final snapshot = await repository.snapshotForSync(noteId);
      final hash = snapshot == null
          ? null
          : (await _inspectArchive(snapshot.archive)).$1;
      final baseline = state[noteId] as Map?;
      if ((baseline != null && baseline['digest'] == hash) ||
          (baseline == null && snapshot == null)) {
        return report;
      }
    }
    onProgress?.call('Loading encrypted revisions …');
    final revisions = <String, SyncRevision>{
      for (final r in await remote.list())
        if (r.noteId.startsWith('extra_') == extras) r.revision: r,
    };
    // A corrupt history must never turn a live document into a deletion.
    for (final r in revisions.values) {
      if (noteId != null && r.noteId != noteId) continue;
      for (final parent in r.parents) {
        final previous = revisions[parent];
        if (previous == null || previous.noteId != r.noteId) {
          throw const SyncFailure(
            'Version history is incomplete. No local notes were replaced.',
          );
        }
      }
    }
    final ids = noteId == null
        ? ({
            ...localIds,
            ...state.keys,
            ...revisions.values.map((r) => r.noteId),
          }.toList()..sort())
        : [noteId];
    final cache = <String, Uint8List>{};
    Future<void> publish(SyncRevision r, Uint8List bytes) async {
      if (!revisions.containsKey(r.revision)) {
        await remote.upload(r, bytes);
        revisions[r.revision] = r;
        cache[r.revision] = bytes;
        report.uploaded++;
      }
    }

    Future<Uint8List> read(SyncRevision r) async {
      final bytes = cache[r.revision] ?? await remote.download(r);
      final inspection = await _inspectArchive(bytes);
      if (inspection.$1 != r.digest || inspection.$2 != r.noteId) {
        throw const SyncFailure(
          'A synced note is corrupted. The local version is preserved.',
        );
      }
      cache[r.revision] = bytes;
      return bytes;
    }

    for (var index = 0; index < ids.length; index++) {
      final id = ids[index];
      onProgress?.call('Note ${index + 1} of ${ids.length}: syncing …');
      final snapshot = await repository.snapshotForSync(id);
      final hash = snapshot == null
          ? null
          : (await _inspectArchive(snapshot.archive)).$1;
      final baseline = state[id] as Map?;
      final previousHeads = (baseline?['heads'] as List? ?? const [])
          .cast<String>();
      final knownParents = previousHeads.where(revisions.containsKey).toList();
      if ((snapshot != null &&
              (baseline == null || baseline['digest'] != hash)) ||
          (snapshot == null &&
              baseline != null &&
              baseline['digest'] != null) ||
          (snapshot != null && knownParents.isEmpty)) {
        await publish(
          SyncRevision(
            noteId: id,
            digest: hash ?? deletedDigest,
            parents: knownParents,
            deleted: snapshot == null,
          ),
          snapshot?.archive ?? Uint8List(0),
        );
      }
      final versions = revisions.values.where((r) => r.noteId == id).toList();
      if (versions.isEmpty) continue;
      final superseded = versions.expand((r) => r.parents).toSet();
      final heads =
          versions.where((r) => !superseded.contains(r.revision)).toList()
            ..sort((a, b) => a.revision.compareTo(b.revision));
      if (heads.isEmpty) {
        throw const SyncFailure('Invalid version history.');
      }
      final live = heads.where((r) => !r.deleted).toList();
      final winner = live.isEmpty ? heads.first : live.first;
      if (heads.length == 1 &&
          baseline != null &&
          baseline['digest'] == hash &&
          ((winner.deleted && snapshot == null) ||
              (!winner.deleted && winner.digest == hash)) &&
          previousHeads.length == 1 &&
          previousHeads.single == winner.revision) {
        continue;
      }
      var winnerBytes = winner.deleted
          ? null
          : winner.digest == hash && snapshot != null
          ? snapshot.archive
          : await read(winner);
      var resolvedDigest = winner.digest;
      var learning = const LearningProgress.empty();
      final winnerContent = winnerBytes == null || live.length < 2
          ? null
          : await _documentDigest(winnerBytes);
      if (winnerBytes != null && live.length > 1) {
        final (note, pdf, ink) =
            await LocalNotebookRepository.decodeInkValidated(winnerBytes);
        learning = note.learning;
        var modified = note.modified;
        for (final other in live.where((r) => r.revision != winner.revision)) {
          final (otherNote, _) = await LocalNotebookRepository.decodeValidated(
            await read(other),
          );
          // Set union is idempotent and commutative. Conflicting IDs abort
          // instead of picking a rating and silently discarding the other.
          learning = await _mergeLearning(learning, otherNote.learning);
          if (otherNote.modified.isAfter(modified)) {
            modified = otherNote.modified;
          }
        }
        winnerBytes = await LocalNotebookRepository.encodeAsync(
          note.copy(learning: learning, modified: modified),
          pdf,
          ink: ink,
        );
        resolvedDigest = (await _inspectArchive(winnerBytes)).$1;
      }
      // Stable conflict IDs make retries and simultaneous resolutions idempotent.
      final handled = <String>{winner.digest};
      for (final losing in live.where((r) => r.revision != winner.revision)) {
        if (!handled.add(losing.digest)) continue;
        final bytes = await read(losing);
        if (await _documentDigest(bytes) == winnerContent) continue;
        final conflictId =
            '${extras ? 'extra_conflict_' : 'conflict_'}${sha256.convert(utf8.encode('$id:${losing.digest}')).toString().substring(0, 40)}';
        if (revisions.values.any((r) => r.noteId == conflictId) ||
            localIds.contains(conflictId)) {
          continue;
        }
        final (note, pdf, ink) =
            await LocalNotebookRepository.decodeInkValidated(bytes);
        final title = note.title.length > 95
            ? note.title.substring(0, 95)
            : note.title;
        final copy = Notebook(
          id: conflictId,
          title: '$title (Conflict ${losing.digest.substring(0, 6)})',
          created: note.created,
          modified: note.modified,
          paper: note.paper,
          lineColor: note.lineColor,
          folderName: note.folderName,
          tags: note.tags,
          learning: learning,
          linkPath: !note.isPdf || note.linkPath != null
              ? p.posix.normalize(
                  p.posix.join(
                    p.posix.dirname(note.documentPath),
                    '$conflictId.${note.extension}',
                  ),
                )
              : null,
        );
        final archive = await LocalNotebookRepository.encodeAsync(
          copy,
          pdf,
          ink: ink,
        );
        await publish(
          SyncRevision(
            noteId: conflictId,
            digest: (await _inspectArchive(archive)).$1,
            parents: [],
          ),
          archive,
        );
        if (!ids.contains(conflictId)) ids.add(conflictId);
        report.conflicts++;
      }
      var resolved = winner;
      if (heads.length > 1) {
        resolved = SyncRevision(
          noteId: id,
          digest: resolvedDigest,
          deleted: winner.deleted,
          parents: heads.map((r) => r.revision).toList(),
        );
        await publish(resolved, winnerBytes ?? Uint8List(0));
      }
      if ((winner.deleted && snapshot != null) ||
          (!winner.deleted && hash != resolvedDigest)) {
        await repository.applySync(id, snapshot?.raw, winnerBytes);
        if (winner.deleted) {
          report.deleted++;
        } else {
          report.downloaded++;
        }
      }
      state[id] = {
        'digest': winner.deleted ? null : resolvedDigest,
        'heads': [resolved.revision],
      };
      await stateFile.parent.create(recursive: true);
      final temporary = File('${stateFile.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'notes': state}),
        flush: true,
      );
      await temporary.rename(stateFile.path);
      cache.removeWhere((revision, _) => revisions[revision]?.noteId == id);
    }
    return report;
  }
}
