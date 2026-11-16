import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const maxSyncBytes = 256 * 1024 * 1024;
final syncHashPattern = RegExp(r'^[a-f0-9]{64}$');

class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// These metadata exist in plaintext only on end devices.
class SyncRevision {
  SyncRevision({
    required this.noteId,
    required this.digest,
    required List<String> parents,
    this.deleted = false,
  }) : parents = List.unmodifiable(parents.toSet().toList()..sort());
  final String noteId, digest;
  final List<String> parents;
  final bool deleted;
  String get revision => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'note': noteId,
            'digest': digest,
            'deleted': deleted,
            'parents': parents,
          }),
        ),
      )
      .toString();

  Map<String, Object?> get metadata => {
    'version': 1,
    'note': noteId,
    'digest': digest,
    'deleted': deleted,
    'parents': parents,
    'revision': revision,
  };

  factory SyncRevision.parse(Map<String, dynamic> json) {
    final id = json['note'];
    final digest = json['digest'];
    final parents = (json['parents'] as List).cast<String>();
    if (json['version'] != 1 ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        digest is! String ||
        !syncHashPattern.hasMatch(digest) ||
        json['deleted'] is! bool ||
        parents.length > 512 ||
        parents.any((p) => !syncHashPattern.hasMatch(p)) ||
        (json['deleted'] == true &&
            digest !=
                sha256.convert(utf8.encode('noter:deleted:v1')).toString())) {
      throw const FormatException('Ungültige Synchronisationsdaten.');
    }
    final result = SyncRevision(
      noteId: id,
      digest: digest,
      parents: parents,
      deleted: json['deleted'] as bool,
    );
    if (result.revision != json['revision'] ||
        parents.length != result.parents.length ||
        parents.contains(result.revision)) {
      throw const FormatException('Ungültige Revisionskennung.');
    }
    return result;
  }
}

abstract class RevisionRemote {
  Future<String> accountId();
  Future<List<SyncRevision>> list();
  Future<Uint8List> download(SyncRevision revision);
  Future<void> upload(SyncRevision revision, Uint8List bytes);
}
