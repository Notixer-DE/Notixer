import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../data/notebook.dart';
import '../data/learning.dart';
import '../data/ink.dart';
import 'sync_revision.dart';
import 'sync_storage.dart';

const archivedSettingsConflictTag = 'Archived settings conflict';
final _settingsConflictId = RegExp(r'^settings_extra_conflict_[0-9a-f]{40}$');

extension SettingsConflictNote on Notebook {
  bool get isSettingsConflict => isMarkdown && _settingsConflictId.hasMatch(id);
  bool get isArchivedSettingsConflict =>
      isSettingsConflict && tags.contains(archivedSettingsConflictTag);
}

String archiveDigest(Uint8List bytes) {
  final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(bytes);
  return archiveDigestFromNote(note, pdf, ink?.encode());
}

String archiveDigestFromNote(Notebook note, Uint8List pdf, Uint8List? ink) {
  final json = note.toJson()..remove('folderId');
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'note': json,
            'pdf': sha256.convert(pdf).toString(),
            if (ink != null) 'ink': sha256.convert(ink).toString(),
          }),
        ),
      )
      .toString();
}

Future<String> archiveDigestAsync(Uint8List bytes) => kIsWeb
    ? Future.sync(() => archiveDigest(bytes))
    : Isolate.run(
        () => archiveDigest(bytes),
        debugName: 'noter:archive-digest',
      );

/// Assessments and their save timestamp do not constitute a document conflict.
/// Keep the existing conflict-copy rule for actual PDF/organization edits.
Future<String> _documentDigest(Uint8List bytes) {
  if (kIsWeb) return Future.sync(() => _documentDigestOf(bytes));
  final transfer = TransferableTypedData.fromList([bytes]);
  return Isolate.run(
    () => _documentDigestOf(transfer.materialize().asUint8List()),
    debugName: 'noter:sync-document-digest',
  );
}

String _documentDigestOf(Uint8List bytes) {
  final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(bytes);
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
}

Future<LearningProgress> _mergeLearning(
  LearningProgress a,
  LearningProgress b,
) => kIsWeb
    ? Future.sync(() => a.merge(b))
    : Isolate.run(() => a.merge(b), debugName: 'noter:merge-assessments');

Future<(String, String)> _inspectArchive(Uint8List bytes) {
  if (kIsWeb) return Future.sync(() => _inspectBytes(bytes));
  final transfer = TransferableTypedData.fromList([bytes]);
  return Isolate.run(
    () => _inspectBytes(transfer.materialize().asUint8List()),
    debugName: 'noter:sync-digest',
  );
}

(String, String) _inspectBytes(Uint8List bytes) {
  final (note, payload, ink) = LocalNotebookRepository.decodeWithInk(bytes);
  validateNotebookContent(note, payload);
  return (archiveDigestFromNote(note, payload, ink?.encode()), note.id);
}

Future<(Notebook, Uint8List, InkDocument?)> _decodeInkValidated(
  Uint8List bytes,
) {
  if (!kIsWeb) return LocalNotebookRepository.decodeInkValidated(bytes);
  return Future.sync(() {
    final decoded = LocalNotebookRepository.decodeWithInk(bytes);
    validateNotebookContent(decoded.$1, decoded.$2);
    return decoded;
  });
}

Future<(Notebook, Uint8List)> _decodeValidated(Uint8List bytes) async {
  final (note, payload, _) = await _decodeInkValidated(bytes);
  return (note, payload);
}

Future<Uint8List> _encodeSyncArchive(
  Notebook note,
  Uint8List payload, {
  InkDocument? ink,
}) => kIsWeb
    ? Future.sync(() => LocalNotebookRepository.encode(note, payload, ink: ink))
    : LocalNotebookRepository.encodeAsync(note, payload, ink: ink);

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
  final SyncNotebookRepository repository;
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
    final stateFiles = repository.syncState;
    final stateKey = '.sync-state-$account.json';
    final cachedState = await stateFiles.read(stateKey);
    var state = <String, dynamic>{};
    if (cachedState != null) {
      final json = jsonDecode(utf8.decode(cachedState)) as Map<String, dynamic>;
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
    final byNote = <String, List<SyncRevision>>{};
    // A corrupt history must never turn a live document into a deletion.
    for (final r in revisions.values) {
      (byNote[r.noteId] ??= []).add(r);
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
        ? ({...localIds, ...state.keys, ...byNote.keys}.toList()..sort())
        : [noteId];
    final cache = <String, Uint8List>{};
    Future<void> publish(SyncRevision r, Uint8List bytes) async {
      if (!revisions.containsKey(r.revision)) {
        await remote.upload(r, bytes);
        revisions[r.revision] = r;
        (byNote[r.noteId] ??= []).add(r);
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
      final settingsConflict = _settingsConflictId.hasMatch(id);
      final local = repository;
      // A notice can be dismissed before its first ordinary notebook sync.
      final dismissed =
          settingsConflict &&
          snapshot == null &&
          baseline == null &&
          local is LocalNotebookRepository &&
          byNote.containsKey(id) &&
          await File(
            p.join(local.directory.path, '.trash', '$id.noter'),
          ).exists();
      if (dismissed ||
          (snapshot != null &&
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
      final versions = byNote[id] ?? const <SyncRevision>[];
      if (versions.isEmpty) continue;
      final superseded = versions.expand((r) => r.parents).toSet();
      final heads =
          versions.where((r) => !superseded.contains(r.revision)).toList()
            ..sort((a, b) => a.revision.compareTo(b.revision));
      if (heads.isEmpty) {
        throw const SyncFailure('Invalid version history.');
      }
      final live = heads.where((r) => !r.deleted).toList();
      final dismissal = settingsConflict
          ? heads.where((revision) => revision.deleted).firstOrNull
          : null;
      var winner = dismissal ?? (live.isEmpty ? heads.first : live.first);
      if (dismissal == null && live.length > 1 && settingsConflict) {
        // Another device can still have an unpublished copy of this notice.
        for (final candidate in live) {
          final (note, _) = await _decodeValidated(await read(candidate));
          if (note.isArchivedSettingsConflict) {
            winner = candidate;
            break;
          }
        }
      }
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
      Uint8List? archivedConflictContent;
      final winnerContent = winnerBytes == null || live.length < 2
          ? null
          : await _documentDigest(winnerBytes);
      if (winnerBytes != null && live.length > 1) {
        final (note, pdf, ink) = await _decodeInkValidated(winnerBytes);
        if (note.isArchivedSettingsConflict) archivedConflictContent = pdf;
        learning = note.learning;
        var modified = note.modified;
        for (final other in live.where((r) => r.revision != winner.revision)) {
          final (otherNote, _) = await _decodeValidated(await read(other));
          // Set union is idempotent and commutative. Conflicting IDs abort
          // instead of picking a rating and silently discarding the other.
          learning = await _mergeLearning(learning, otherNote.learning);
          if (otherNote.modified.isAfter(modified)) {
            modified = otherNote.modified;
          }
        }
        winnerBytes = await _encodeSyncArchive(
          note.copy(learning: learning, modified: modified),
          pdf,
          ink: ink,
        );
        resolvedDigest = (await _inspectArchive(winnerBytes)).$1;
      }
      // Stable conflict IDs make retries and simultaneous resolutions idempotent.
      final handled = <String>{winner.digest};
      for (final losing in live.where(
        (revision) => dismissal == null && revision.revision != winner.revision,
      )) {
        if (!handled.add(losing.digest)) continue;
        final bytes = await read(losing);
        if (await _documentDigest(bytes) == winnerContent) continue;
        final conflictIdentity = extras ? losing.revision : losing.digest;
        final conflictId =
            '${extras ? 'extra_conflict_' : 'conflict_'}${sha256.convert(utf8.encode('$id:$conflictIdentity')).toString().substring(0, 40)}';
        if (byNote.containsKey(conflictId) || localIds.contains(conflictId)) {
          continue;
        }
        final (note, pdf, ink) = await _decodeInkValidated(bytes);
        if (archivedConflictContent != null &&
            !note.isArchivedSettingsConflict &&
            sha256.convert(archivedConflictContent) == sha256.convert(pdf)) {
          continue;
        }
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
        final archive = await _encodeSyncArchive(copy, pdf, ink: ink);
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
      await stateFiles.write(
        stateKey,
        Uint8List.fromList(
          utf8.encode(jsonEncode({'version': 1, 'notes': state})),
        ),
      );
      cache.removeWhere((revision, _) => revisions[revision]?.noteId == id);
    }
    return report;
  }
}
