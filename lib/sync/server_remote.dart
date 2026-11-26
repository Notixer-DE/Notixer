import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'disk_sync_files.dart';
import 'sync_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'sync_crypto.dart';
import 'sync_revision.dart';

const syncBlockBytes = 4 * 1024 * 1024;

bool isLoopbackServer(Uri uri) =>
    ['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host.toLowerCase());

Uri validateServerUrl(String value, {bool allowInsecureHttp = false}) {
  final uri = Uri.parse(value.trim());
  final loopback = isLoopbackServer(uri);
  if (uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' && (loopback || allowInsecureHttp)))) {
    throw const SyncFailure(
      'Enter a server address without a path. Use HTTPS or explicitly allow HTTP.',
    );
  }
  return uri.replace(path: '');
}

class ServerRemote implements RevisionRemote {
  ServerRemote({
    required Uri server,
    required this.token,
    required this.crypto,
    Directory? cache,
    SyncFiles? cacheFiles,
    http.Client? client,
    bool allowInsecureHttp = false,
  }) : server = validateServerUrl(
         server.toString(),
         allowInsecureHttp: allowInsecureHttp,
       ),
       _client = client ?? http.Client(),
       _cache = cacheFiles ?? DiskSyncFiles(cache!);
  final Uri server;
  final String token;
  final SyncCrypto crypto;
  final SyncFiles _cache;
  final http.Client _client;
  late final _transport = _ServerHttp(server, token, _client);
  final _envelopes = <String, Map<String, dynamic>>{};

  void close() => _client.close();

  static Future<Map<String, dynamic>> connect(
    Uri server,
    String token, {
    http.Client? client,
    bool allowInsecureHttp = false,
  }) async {
    final normalized = validateServerUrl(
      server.toString(),
      allowInsecureHttp: allowInsecureHttp,
    );
    final transport = _ServerHttp(normalized, token, client ?? http.Client());
    try {
      return jsonDecode(utf8.decode(await transport.request('GET', '/session')))
          as Map<String, dynamic>;
    } finally {
      if (client == null) transport.client.close();
    }
  }

  Future<Uint8List> _request(
    String method,
    String path, {
    List<int>? bytes,
    Map<String, dynamic>? json,
    int limit = 16 * 1024 * 1024,
  }) =>
      _transport.request(method, path, bytes: bytes, json: json, limit: limit);

  Future<void> verifyKey() async {
    await _request('PUT', '/key-check', json: {'value': crypto.keyCheck});
  }

  @override
  Future<String> accountId() async {
    final session =
        jsonDecode(utf8.decode(await _request('GET', '/session')))
            as Map<String, dynamic>;
    if (session['account'] != crypto.account ||
        session['key_check'] != crypto.keyCheck) {
      throw const SyncFailure(
        'The server account or encryption key does not match.',
      );
    }
    return '$server:${crypto.account}:${crypto.keyCheck}';
  }

  Future<SyncRevision> _inspect(Map<String, dynamic> envelope) async {
    final id = envelope['id'] as String;
    if (!syncHashPattern.hasMatch(id)) {
      throw const FormatException('Invalid identifier.');
    }
    final decoded =
        jsonDecode(
              utf8.decode(
                await crypto.decrypt(
                  base64Decode(envelope['manifest'] as String),
                  'revision:$id',
                ),
              ),
            )
            as Map<String, dynamic>;
    final revision = SyncRevision.parse(
      decoded['revision'] as Map<String, dynamic>,
    );
    final parents = revision.parents.map(crypto.wireRevision).toList();
    if (crypto.wireRevision(revision.revision) != id ||
        jsonEncode(parents) != jsonEncode(envelope['parents']) ||
        jsonEncode(decoded['blobs']) != jsonEncode(envelope['blobs'])) {
      throw const SyncFailure(
        'The revision has changed. Local data is preserved.',
      );
    }
    final blobs = (envelope['blobs'] as List).cast<String>();
    if (blobs.length > 64 ||
        blobs.any((b) => !syncHashPattern.hasMatch(b)) ||
        (revision.deleted && blobs.isNotEmpty)) {
      throw const FormatException('Invalid block list.');
    }
    _envelopes[revision.revision] = envelope;
    return revision;
  }

  @override
  Future<List<SyncRevision>> list() async {
    final all = <String, SyncRevision>{};
    for (final key in await _cache.list('history/')) {
      if (!key.endsWith('.json')) continue;
      final data = await _cache.read(key);
      if (data == null) {
        throw const SyncFailure('The local sync journal is incomplete.');
      }
      final revision = await _inspect(
        jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
      );
      all[revision.revision] = revision;
    }
    final cursorBytes = await _cache.read('cursor');
    var cursor = cursorBytes == null ? 0 : int.parse(utf8.decode(cursorBytes));
    if (cursor < 0 || all.length < cursor) {
      throw const SyncFailure(
        'The local sync journal is incomplete. Check the cache before running a full sync again.',
      );
    }
    while (true) {
      final page =
          jsonDecode(
                utf8.decode(await _request('GET', '/changes?after=$cursor')),
              )
              as Map<String, dynamic>;
      final items = page['items'] as List;
      final next = page['cursor'] as int;
      if (next != cursor + items.length) {
        throw const SyncFailure('Invalid sync cursor.');
      }
      for (final raw in items) {
        final envelope = raw as Map<String, dynamic>;
        final revision = await _inspect(envelope);
        // Persist before advancing the cursor; crashes may replay, never skip.
        await _cache.write(
          'history/${envelope['id']}.json',
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        );
        all[revision.revision] = revision;
      }
      await _cache.write('cursor', Uint8List.fromList(utf8.encode('$next')));
      cursor = next;
      if (items.isEmpty) break;
    }
    return all.values.toList();
  }

  @override
  Future<void> upload(SyncRevision revision, Uint8List bytes) async {
    if (bytes.length > maxSyncBytes || (revision.deleted && bytes.isNotEmpty)) {
      throw const SyncFailure('The note exceeds the sync limit.');
    }
    final blobs = <String>[];
    final locations = <String, String>{};
    for (var offset = 0; offset < bytes.length; offset += syncBlockBytes) {
      final end = (offset + syncBlockBytes).clamp(0, bytes.length);
      final plain = Uint8List.sublistView(bytes, offset, end);
      // Local keyed lookup reuses the exact random-nonce ciphertext on retry.
      // Neither this lookup nor the plaintext hash is sent to the server.
      final lookup = crypto.identify('chunk:${sha256.convert(plain)}');
      final location = 'chunks/$lookup';
      Uint8List? encrypted;
      final cached = await _cache.read(location, maxBytes: syncBlockBytes + 28);
      if (cached != null) {
        try {
          final restored = await crypto.decrypt(cached, 'chunk');
          if (crypto.identify('chunk:${sha256.convert(restored)}') == lookup) {
            encrypted = cached;
          }
        } catch (_) {
          // A damaged local cache is disposable; never publish its bad bytes.
        }
      }
      if (encrypted == null) {
        encrypted = await crypto.encrypt(plain, 'chunk');
        await _cache.write(location, encrypted);
      }
      final id = sha256.convert(encrypted).toString();
      blobs.add(id);
      locations[id] = location;
    }
    final missing =
        (jsonDecode(
                  utf8.decode(
                    await _request(
                      'POST',
                      '/blobs/missing',
                      json: {'ids': blobs},
                    ),
                  ),
                )
                as Map<String, dynamic>)['missing']
            as List;
    final missingIds = missing.cast<String>().toSet().toList();
    for (var offset = 0; offset < missingIds.length; offset += 4) {
      await Future.wait(
        missingIds.skip(offset).take(4).map((id) async {
          final location = locations[id];
          final data = location == null ? null : await _cache.read(location);
          if (data == null) {
            throw const SyncFailure('The server requested an unknown block.');
          }
          await _request('PUT', '/blobs/$id', bytes: data);
        }),
      );
    }
    final id = crypto.wireRevision(revision.revision);
    final manifest = await crypto.encrypt(
      utf8.encode(jsonEncode({'revision': revision.metadata, 'blobs': blobs})),
      'revision:$id',
    );
    final canonical =
        jsonDecode(
              utf8.decode(
                await _request(
                  'POST',
                  '/commits',
                  json: {
                    'id': id,
                    'parents': revision.parents
                        .map(crypto.wireRevision)
                        .toList(),
                    'blobs': blobs,
                    'manifest': base64Encode(manifest),
                  },
                ),
              ),
            )
            as Map<String, dynamic>;
    final accepted = await _inspect(canonical);
    if (accepted.revision != revision.revision) {
      throw const SyncFailure('The server confirmed a different revision.');
    }
  }

  @override
  Future<Uint8List> download(SyncRevision revision) async {
    final envelope = _envelopes[revision.revision];
    if (envelope == null) {
      throw const SyncFailure('Revision missing from the local journal.');
    }
    final output = BytesBuilder(copy: false);
    final ids = (envelope['blobs'] as List).cast<String>();
    final chunkWrites = <String, Future<void>>{};
    Future<Uint8List> block(String id) async {
      final location = 'downloaded/$id';
      Uint8List? encrypted;
      var reused = false;
      final cached = await _cache.read(location, maxBytes: syncBlockBytes + 28);
      if (cached != null && sha256.convert(cached).toString() == id) {
        encrypted = cached;
        reused = true;
      }
      if (encrypted == null) {
        encrypted = await _request(
          'GET',
          '/blobs/$id',
          limit: syncBlockBytes + 28,
        );
        if (sha256.convert(encrypted).toString() != id) {
          throw const SyncFailure('An encrypted block is corrupted.');
        }
      }
      final plain = await crypto.decrypt(encrypted, 'chunk');
      if (!reused) await _cache.write(location, encrypted);
      final lookup = crypto.identify('chunk:${sha256.convert(plain)}');
      await chunkWrites.putIfAbsent(lookup, () async {
        final chunkKey = 'chunks/$lookup';
        if (await _cache.read(chunkKey) == null) {
          await _cache.write(chunkKey, encrypted!);
        }
      });
      return plain;
    }

    // Four blocks bound temporary transfer/decryption memory, while results
    // are appended in manifest order. Duplicate blocks share one fetch.
    for (var offset = 0; offset < ids.length; offset += 4) {
      final pending = <String, Future<Uint8List>>{};
      final batch = await Future.wait(
        ids
            .skip(offset)
            .take(4)
            .map((id) => pending.putIfAbsent(id, () => block(id))),
      );
      for (final plain in batch) {
        if (output.length + plain.length > maxSyncBytes) {
          throw const SyncFailure('The note exceeds the sync limit.');
        }
        output.add(plain);
      }
    }
    return output.takeBytes();
  }
}

/// Authentication/transport is independent of the vault key. The initial
/// session probe discovers the account before account-scoped keys are derived.
class _ServerHttp {
  _ServerHttp(this.server, this.token, this.client);
  final Uri server;
  final String token;
  final http.Client client;

  Future<Uint8List> request(
    String method,
    String path, {
    List<int>? bytes,
    Map<String, dynamic>? json,
    int limit = 16 * 1024 * 1024,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, server.resolve('/api/v1$path'))
        ..followRedirects = false
        ..headers['authorization'] = 'Bearer $token';
      if (json != null) {
        request.headers['content-type'] = 'application/json';
        request.body = jsonEncode(json);
      } else if (bytes != null) {
        request.headers['content-type'] = 'application/octet-stream';
        request.bodyBytes = bytes;
      }
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final output = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (output.length + chunk.length > limit) {
          throw const SyncFailure(
            'The server response exceeds the size limit.',
          );
        }
        output.add(chunk);
      }
      final retryable =
          response.statusCode == 429 ||
          response.statusCode == 503 ||
          (method == 'PUT' &&
              path.startsWith('/blobs/') &&
              response.statusCode == 500);
      if (retryable && attempt < 3) {
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (1 << attempt) + Random().nextInt(500)),
        );
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SyncFailure(switch (response.statusCode) {
          401 ||
          403 => 'Device access is invalid or revoked. Please reconnect.',
          409 =>
            'The key or sync state does not match the server. Do not reset automatically.',
          502 || 503 || 504 =>
            'The sync server is unavailable (${response.statusCode}). Check that the server and its database are running.',
          507 => 'Storage or revision quota exceeded.',
          _ =>
            'Server request failed (${response.statusCode}). Please try again later.',
        });
      }
      return output.takeBytes();
    }
  }
}
