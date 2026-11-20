import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../sync/notebook_sync.dart';
import '../sync/server_remote.dart';
import '../sync/sync_crypto.dart';
import '../sync/sync_revision.dart';
import 'browser_library.dart';
import 'web_quick_todos.dart';

class WebSync {
  WebSync(this.library);
  final BrowserLibrary library;
  late final quickTodos = WebQuickTodos(library);
  ServerRemote? _remote;

  bool get connected => _remote != null;
  String? get address => _remote?.server.toString();

  Future<void> connect(String address, String token, String key) async {
    final server = validateServerUrl(address);
    final Map<String, dynamic> session;
    try {
      session = await ServerRemote.connect(server, token.trim());
    } on http.ClientException {
      throw const SyncFailure(
        'The browser could not reach the sync server. Check the HTTPS address and the server setup for Web.',
      );
    }
    if (session['version'] != 1 || session['account'] is! String) {
      throw const SyncFailure('Unknown sync server version.');
    }
    final crypto = await SyncCrypto.create(key, session['account'] as String);
    if (session['key_check'] != null &&
        session['key_check'] != crypto.keyCheck) {
      throw const SyncFailure('The recovery key does not match the server.');
    }
    final fingerprint = sha256.convert(
      utf8.encode('$server:${crypto.account}:${crypto.keyCheck}'),
    );
    final remote = ServerRemote(
      server: server,
      token: token.trim(),
      crypto: crypto,
      cacheFiles: library.syncFiles('remote/$fingerprint/'),
    );
    try {
      // Check the vault before accepting local changes or a different server.
      await library.checkAccount(fingerprint.toString());
      await remote.verifyKey();
      await remote.accountId();
      await library.attachAccount(fingerprint.toString());
    } catch (_) {
      remote.close();
      rethrow;
    }
    _remote?.close();
    _remote = remote;
  }

  Future<SyncReport> synchronize(void Function(String) onProgress) async {
    final remote = _remote;
    if (remote == null) {
      throw const SyncFailure('Connect the sync server first.');
    }
    final session = SyncSessionRemote(remote);
    await quickTodos.migrate();
    final report = await NotebookSync(
      library,
      session,
      onProgress: onProgress,
    ).run();
    final extras = await NotebookSync(
      library.extras,
      session,
      extras: true,
      onProgress: onProgress,
    ).run();
    report.uploaded += extras.uploaded;
    report.downloaded += extras.downloaded;
    report.deleted += extras.deleted;
    report.conflicts += extras.conflicts;
    return report;
  }

  void disconnect() {
    _remote?.close();
    _remote = null;
  }
}
