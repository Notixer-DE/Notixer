import 'dart:typed_data';

abstract interface class SyncFiles {
  Future<Uint8List?> read(String key, {int? maxBytes});
  Future<void> write(String key, Uint8List bytes);
  Future<List<String>> list(String prefix);
}

abstract interface class SyncNotebookRepository {
  Future<List<String>> syncIds();
  Future<({Uint8List raw, Uint8List archive})?> snapshotForSync(String id);
  Future<void> applySync(String id, Uint8List? expected, Uint8List? archive);
  SyncFiles get syncState;
}
