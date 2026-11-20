import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:web/web.dart' as web;

import '../sync/sync_storage.dart';
import 'web_library.dart';
import 'web_note_archive.dart';

class BrowserLibrary implements WebLibrary, SyncNotebookRepository {
  static const _store = 'notes';
  static const _sync = 'sync';
  Future<web.IDBDatabase>? _opening;

  Future<web.IDBDatabase> _database() => _opening ??= _open().then(
    (db) => db,
    onError: (Object error, StackTrace stack) {
      _opening = null;
      Error.throwWithStackTrace(error, stack);
    },
  );

  Future<web.IDBDatabase> _open() async {
    final request = web.window.indexedDB.open('notixer-web', 2);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
      if (!db.objectStoreNames.contains(_sync)) db.createObjectStore(_sync);
    }).toJS;
    final db = await _request(request) as web.IDBDatabase;
    db.onversionchange = ((web.Event _) {
      db.close();
      _opening = null;
    }).toJS;
    return db;
  }

  Future<JSAny?> _request(web.IDBRequest request) {
    final result = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      result.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      result.completeError(
        StateError(
          request.error?.message ?? 'Could not access browser storage.',
        ),
      );
    }).toJS;
    return result.future;
  }

  Future<T> _transaction<T>(
    String mode,
    Future<T> Function(web.IDBObjectStore) action, {
    String location = _store,
  }) async {
    final transaction = (await _database()).transaction(location.toJS, mode);
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    transaction.onabort = ((web.Event _) => done.completeError(
      StateError(
        transaction.error?.message ?? 'The browser could not save the changes.',
      ),
    )).toJS;
    // Attach the transaction listener before starting requests, including failures.
    final finished = done.future.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    final T result;
    try {
      result = await action(transaction.objectStore(location));
    } catch (_) {
      try {
        transaction.abort();
      } catch (_) {
        // A failed request can already have aborted the transaction.
      }
      await finished;
      rethrow;
    }
    final error = await finished;
    if (error != null) throw error;
    return result;
  }

  @override
  Future<List<WebNote>> readAll() => _transaction('readonly', (store) async {
    final result = await _request(store.getAll()) as JSArray<JSString>;
    return [
      for (final entry in result.toDart)
        WebNote.fromJson(jsonDecode(entry.toDart)),
    ];
  });

  Future<void> _expect(
    web.IDBObjectStore store,
    String id,
    WebNote? previous,
  ) async {
    final existing = await _request(store.get(id.toJS)) as JSString?;
    if (existing?.toDart != previous?.encode()) {
      throw StateError(
        'This note changed in another tab. Reopen it before saving.',
      );
    }
  }

  @override
  Future<void> write(WebNote note, {required WebNote? previous}) {
    WebNote.fromJson(note.toJson());
    return _transaction('readwrite', (store) async {
      await _expect(store, note.id, previous);
      await _request(store.put(note.encode().toJS, note.id.toJS));
    });
  }

  @override
  Future<void> delete(WebNote previous) =>
      _transaction('readwrite', (store) async {
        await _expect(store, previous.id, previous);
        await _request(store.delete(previous.id.toJS));
      });

  @override
  Future<int> importMissing(List<WebNote> notes) =>
      _transaction('readwrite', (store) async {
        var added = 0;
        for (final note in notes) {
          if (await _request(store.get(note.id.toJS)) != null) continue;
          await _request(store.add(note.encode().toJS, note.id.toJS));
          added++;
        }
        return added;
      });
  SyncNotebookRepository get extras => _BrowserExtras(this);

  Future<void> replaceExtra(
    String name,
    Uint8List? expected,
    Uint8List? next,
  ) => _transaction('readwrite', (store) async {
    final key = 'extras/$name'.toJS;
    final current = await _request(store.get(key)) as JSUint8Array?;
    if (!listEquals(current?.toDart, expected)) {
      throw StateError(
        'An extra changed in another tab during sync. Sync again.',
      );
    }
    if (next == null) {
      await _request(store.delete(key));
    } else {
      await _request(store.put(next.toJS, key));
    }
  }, location: _sync);

  @override
  SyncFiles get syncState => syncFiles('state/');

  SyncFiles syncFiles(String prefix) => _IndexedSyncFiles(this, prefix);

  Future<void> checkAccount(String account) =>
      _checkAccount(account, attach: false);
  Future<void> attachAccount(String account) =>
      _checkAccount(account, attach: true);

  Future<void> _checkAccount(
    String account, {
    required bool attach,
  }) => _transaction(attach ? 'readwrite' : 'readonly', (store) async {
    final key = 'library-account'.toJS;
    final current = await _request(store.get(key)) as JSString?;
    if (current != null && current.toDart != account) {
      throw StateError(
        'This browser library is connected to a different vault. Use another browser profile for that vault.',
      );
    }
    if (attach) await _request(store.put(account.toJS, key));
  }, location: _sync);

  @override
  Future<List<String>> syncIds() async => [
    for (final note in await readAll())
      if (note.syncDocument) note.id,
  ];

  @override
  Future<({Uint8List raw, Uint8List archive})?> snapshotForSync(
    String id,
  ) async {
    final raw = await _transaction(
      'readonly',
      (store) async =>
          (await _request(store.get(id.toJS)) as JSString?)?.toDart,
    );
    if (raw == null) return null;
    final note = WebNote.fromJson(jsonDecode(raw));
    if (!note.syncDocument) {
      throw const FormatException('Reserved browser note identity.');
    }
    return (
      raw: Uint8List.fromList(utf8.encode(raw)),
      archive: archiveForWebNote(note),
    );
  }

  @override
  Future<void> applySync(String id, Uint8List? expected, Uint8List? archive) {
    final updated = archive == null ? null : webNoteFromArchive(archive);
    if (updated != null && updated.id != id) {
      throw const FormatException('Incorrect sync note ID.');
    }
    final previous = expected == null ? null : utf8.decode(expected);
    return _transaction('readwrite', (store) async {
      final current = await _request(store.get(id.toJS)) as JSString?;
      if (current?.toDart != previous) {
        throw StateError(
          'A note changed in another tab during sync. Sync again.',
        );
      }
      if (updated == null) {
        await _request(store.delete(id.toJS));
      } else {
        await _request(store.put(updated.encode().toJS, id.toJS));
      }
    });
  }
}

class _BrowserExtras implements SyncNotebookRepository {
  _BrowserExtras(this.library);
  final BrowserLibrary library;
  late final SyncFiles _storage = library.syncFiles('extras/');

  @override
  SyncFiles get syncState => library.syncFiles('extra-state/');

  @override
  Future<List<String>> syncIds() => _storage.list('');

  @override
  Future<({Uint8List raw, Uint8List archive})?> snapshotForSync(
    String id,
  ) async {
    final bytes = await _storage.read(id);
    return bytes == null ? null : (raw: bytes, archive: bytes);
  }

  @override
  Future<void> applySync(String id, Uint8List? expected, Uint8List? archive) =>
      library.replaceExtra(id, expected, archive);
}

class _IndexedSyncFiles implements SyncFiles {
  _IndexedSyncFiles(this.library, this.prefix);
  final BrowserLibrary library;
  final String prefix;

  @override
  Future<Uint8List?> read(String key, {int? maxBytes}) =>
      library._transaction('readonly', (store) async {
        final item =
            await library._request(store.get('$prefix$key'.toJS))
                as JSUint8Array?;
        final bytes = item?.toDart;
        return bytes != null && (maxBytes == null || bytes.length <= maxBytes)
            ? bytes
            : null;
      }, location: BrowserLibrary._sync);

  @override
  Future<void> write(String key, Uint8List bytes) =>
      library._transaction('readwrite', (store) async {
        await library._request(store.put(bytes.toJS, '$prefix$key'.toJS));
      }, location: BrowserLibrary._sync);

  @override
  Future<List<String>> list(
    String subPrefix,
  ) => library._transaction('readonly', (store) async {
    final keyPrefix = '$prefix$subPrefix';
    final range = web.IDBKeyRange.bound(keyPrefix.toJS, '$keyPrefix￿'.toJS);
    final keys =
        await library._request(store.getAllKeys(range)) as JSArray<JSString>;
    return [for (final key in keys.toDart) key.toDart.substring(prefix.length)];
  }, location: BrowserLibrary._sync);
}

void downloadBrowserFile(String name, String content, String type) =>
    _download(name, content.toJS, type);

void downloadBrowserBytes(String name, Uint8List content, String type) =>
    _download(name, content.toJS, type);

void _download(String name, JSAny content, String type) {
  final blob = web.Blob([content].toJS, web.BlobPropertyBag(type: type));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(link);
  link.click();
  link.remove();
  Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
}
