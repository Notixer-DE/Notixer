import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_library.dart';

class BrowserLibrary implements WebLibrary {
  static const _store = 'notes';
  Future<web.IDBDatabase>? _opening;

  Future<web.IDBDatabase> _database() => _opening ??= _open().then(
    (db) => db,
    onError: (Object error, StackTrace stack) {
      _opening = null;
      Error.throwWithStackTrace(error, stack);
    },
  );

  Future<web.IDBDatabase> _open() async {
    final request = web.window.indexedDB.open('notixer-web', 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore(_store);
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
    Future<T> Function(web.IDBObjectStore) action,
  ) async {
    final transaction = (await _database()).transaction(_store.toJS, mode);
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
      result = await action(transaction.objectStore(_store));
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
}

void downloadBrowserFile(String name, String content, String type) {
  final blob = web.Blob([content.toJS].toJS, web.BlobPropertyBag(type: type));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(link);
  link.click();
  link.remove();
  Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
}
