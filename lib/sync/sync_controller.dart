import 'library_extras_sync.dart';
import 'device_pairing.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/notebook.dart';
import 'notebook_sync.dart';
import 'server_remote.dart';
import 'sync_crypto.dart';
import 'sync_revision.dart';

typedef LiveCredentials = ({Uri server, String token, SyncCrypto crypto});

class SyncController extends ChangeNotifier {
  SyncController(this.repository, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final LocalNotebookRepository repository;
  final FlutterSecureStorage _storage;
  ServerRemote? _remote;
  bool busy = false, enabled = false, automatic = false;
  bool allowInsecureHttp = false;
  bool get usesHttp => enabled && Uri.tryParse(serverUrl)?.scheme == 'http';
  String serverUrl = '', status = 'Server sync is disabled.';
  String? error;
  DateTime? lastSyncedAt;
  Future<void>? _loading;
  File get _file => File('${repository.directory.path}/.server-sync.json');
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      await _loadConfiguration();
    } catch (_) {
      enabled = false;
      automatic = false;
      _remote?.close();
      _remote = null;
      status =
          'Server configuration or keychain unavailable. Please reconnect.';
      notifyListeners();
    }
  }

  Future<void> _loadConfiguration() async {
    if (!await _file.exists()) return;
    final config =
        jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    serverUrl = config['server'] as String;
    automatic = config['automatic'] == true;
    allowInsecureHttp = config['allowInsecureHttp'] == true;
    enabled = config['enabled'] == true;
    if (enabled) {
      final secret = await _storage.read(key: 'noter.sync.credentials');
      if (secret == null) {
        enabled = false;
        status = 'The device key is missing. Please reconnect.';
      } else {
        final credentials = jsonDecode(secret) as Map<String, dynamic>;
        if (credentials['server'] != serverUrl) {
          enabled = false;
          throw const SyncFailure(
            'Saved credentials belong to a different server. Please reconnect.',
          );
        }
        _remote = await _makeRemote(
          serverUrl,
          credentials['token'] as String,
          credentials['key'] as String,
          credentials['account'] as String,
          allowHttp: allowInsecureHttp,
        );
        status = 'Ready to sync.';
      }
    }
    notifyListeners();
  }

  Future<ServerRemote> _makeRemote(
    String url,
    String token,
    String key,
    String account, {
    bool allowHttp = false,
  }) async {
    final crypto = await SyncCrypto.create(key, account);
    return ServerRemote(
      server: validateServerUrl(url, allowInsecureHttp: allowHttp),
      allowInsecureHttp: allowHttp,
      token: token,
      crypto: crypto,
      cache: Directory(
        '${repository.directory.path}/.sync-cache/${crypto.identify('$url:$account')}',
      ),
    );
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'server': serverUrl,
        'enabled': enabled,
        'automatic': automatic,
        'allowInsecureHttp': allowInsecureHttp,
      }),
      flush: true,
    );
    await temp.rename(_file.path);
  }

  Future<void> _action(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      error = e is SyncFailure
          ? e.message
          : 'Sync failed. Check the connection, key and system keychain. Local notes are preserved.';
      status = 'Sync did not complete.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connect(
    String url,
    String token,
    String recoveryKey, {
    bool allowHttp = false,
  }) => _action(() => _connect(url, token, recoveryKey, allowHttp: allowHttp));

  Future<void> pair(DevicePairing pairing, String recoveryKey) =>
      _action(() async {
        await load();
        final SyncCrypto crypto;
        try {
          crypto = await SyncCrypto.create(recoveryKey, pairing.account);
        } on FormatException {
          throw const SyncFailure('Enter a valid recovery key.');
        }
        final token = await pairing.redeem(crypto.keyCheck);
        await _connect(
          pairing.server.origin,
          token,
          recoveryKey,
          expectedAccount: pairing.account,
        );
      });

  Future<void> _connect(
    String url,
    String token,
    String recoveryKey, {
    bool allowHttp = false,
    String? expectedAccount,
  }) async {
    await load();
    final server = validateServerUrl(url, allowInsecureHttp: allowHttp);
    if (!syncHashPattern.hasMatch(token.trim())) {
      throw const SyncFailure('Enter a valid device access token.');
    }
    final session = await ServerRemote.connect(
      server,
      token.trim(),
      allowInsecureHttp: allowHttp,
    );
    if (session['version'] != 1 || session['account'] is! String) {
      throw const SyncFailure('Unknown server version.');
    }
    if (expectedAccount != null && expectedAccount != session['account']) {
      throw const SyncFailure('The pairing token belongs to another account.');
    }
    final remote = await _makeRemote(
      server.toString(),
      token.trim(),
      recoveryKey.trim(),
      session['account'] as String,
      allowHttp: allowHttp,
    );
    try {
      await remote.verifyKey();
      // One atomic keychain entry prevents partially updated token/key pairs.
      await _storage.write(
        key: 'noter.sync.credentials',
        value: jsonEncode({
          'server': server.toString(),
          'token': token.trim(),
          'key': recoveryKey.trim(),
          'account': session['account'],
        }),
      );
    } catch (_) {
      remote.close();
      rethrow;
    }
    _remote?.close();
    _remote = remote;
    serverUrl = server.toString();
    allowInsecureHttp = server.scheme == 'http' && allowHttp;
    enabled = true;
    lastSyncedAt = null;
    await _save();
    status = 'Server connected. End-to-end encryption is active.';
  }

  Future<void> disableHttp() => _action(() async {
    await load();
    if (usesHttp) {
      enabled = false;
      automatic = false;
      _remote?.close();
      _remote = null;
      status =
          'HTTP connection disabled. Reconnect using HTTPS. Credentials remain in the keychain.';
    }
    allowInsecureHttp = false;
    await _save();
  });

  Future<void> setAutomatic(bool value) => _action(() async {
    await load();
    automatic = value;
    await _save();
    status = value ? 'Automatic sync enabled.' : 'Automatic sync disabled.';
  });

  Future<void> synchronize({String? noteId, bool onlyIfChanged = false}) =>
      _action(() async {
        await load();
        if (!enabled || _remote == null) {
          throw const SyncFailure('Please connect the server first.');
        }
        final sessionRemote = SyncSessionRemote(_remote!);
        final report = await NotebookSync(
          repository,
          sessionRemote,
          onProgress: (value) {
            status = value;
            notifyListeners();
          },
        ).run(noteId: noteId, onlyIfChanged: onlyIfChanged);
        if (noteId == null) {
          final extras = await LibraryExtrasSync(
            repository,
            sessionRemote,
            onProgress: (value) {
              status = value;
              notifyListeners();
            },
          ).run();
          report.uploaded += extras.uploaded;
          report.downloaded += extras.downloaded;
          report.deleted += extras.deleted;
          report.conflicts += extras.conflicts;
        }
        lastSyncedAt = DateTime.now();
        status = 'Synced: $report';
      });

  Future<void> synchronizePreferences() => _action(() async {
    await load();
    if (!enabled || _remote == null) return;
    final report = await LibraryExtrasSync(
      repository,
      SyncSessionRemote(_remote!),
      onProgress: (value) {
        status = value;
        notifyListeners();
      },
    ).run(onlyIfChanged: true);
    lastSyncedAt = DateTime.now();
    status = 'Quick to-dos, templates and preferences synced: $report';
  });

  Future<void> disconnect() => _action(() async {
    enabled = false;
    automatic = false;
    allowInsecureHttp = false;
    await _save();
    await _storage.delete(key: 'noter.sync.credentials');
    _remote?.close();
    _remote = null;
    status =
        'Disconnected. Notes are preserved; server access has not been revoked.';
  });

  Future<LiveCredentials?> liveCredentials() async {
    await load();
    final remote = _remote;
    return !enabled || remote == null
        ? null
        : (server: remote.server, token: remote.token, crypto: remote.crypto);
  }

  Future<String?> recoveryKey() async {
    final value = await _storage.read(key: 'noter.sync.credentials');
    return value == null
        ? null
        : (jsonDecode(value) as Map<String, dynamic>)['key'] as String?;
  }

  @override
  void dispose() {
    _remote?.close();
    super.dispose();
  }
}
