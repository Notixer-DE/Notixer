import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'sync_storage.dart';

class DiskSyncFiles implements SyncFiles {
  DiskSyncFiles(this.directory);
  final Directory directory;

  File _file(String key) => File(p.join(directory.path, key));

  @override
  Future<Uint8List?> read(String key, {int? maxBytes}) async {
    final file = _file(key);
    if (!await file.exists() ||
        (maxBytes != null && await file.length() > maxBytes)) {
      return null;
    }
    return file.readAsBytes();
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    final file = _file(key);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<List<String>> list(String prefix) async {
    final folder = Directory(p.join(directory.path, prefix));
    if (!await folder.exists()) return [];
    return [
      await for (final entry in folder.list())
        if (entry is File) p.posix.join(prefix, p.basename(entry.path)),
    ];
  }
}
