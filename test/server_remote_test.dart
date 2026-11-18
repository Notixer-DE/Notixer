import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noter/sync/server_remote.dart';
import 'package:noter/sync/sync_crypto.dart';
import 'package:noter/sync/sync_revision.dart';

void main() {
  test(
    'AEAD rejects changed ciphertext, wrong keys and substituted context',
    () async {
      final key = await SyncCrypto.generateRecoveryKey();
      final a = await SyncCrypto.create(key, 'account');
      final b = await SyncCrypto.create(key, 'another-account');
      final plain = utf8.encode('Secret PDF title');
      final encrypted = await a.encrypt(plain, 'chunk');
      expect(encrypted, isNot(containsAllInOrder(plain)));
      expect(await a.decrypt(encrypted, 'chunk'), plain);
      expect(
        a.decrypt(encrypted, 'revision:id'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(
        b.decrypt(encrypted, 'chunk'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      encrypted[13] ^= 1;
      expect(
        a.decrypt(encrypted, 'chunk'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(a.wireRevision('a' * 64), isNot('a' * 64));
      final block = Uint8List(65536)..[123] = 42;
      expect(await a.decrypt(await a.encrypt(block, 'chunk'), 'chunk'), block);
    },
  );

  test(
    'Only HTTPS or loopback HTTP; no credentials, paths or query strings',
    () {
      for (final url in [
        'http://example.org',
        'https://u:p@example.org',
        'https://example.org/path',
        'https://example.org?x=1',
        'file:///tmp',
      ]) {
        expect(() => validateServerUrl(url), throwsA(isA<SyncFailure>()));
      }
      expect(validateServerUrl('http://127.0.0.1:5150').host, '127.0.0.1');
      expect(validateServerUrl('https://example.org/').path, '');
    },
  );

  test(
    'remote HTTP requires explicit consent, including at transport entrypoints',
    () async {
      final server = Uri.parse('http://192.168.1.20:5150');
      expect(
        validateServerUrl(server.toString(), allowInsecureHttp: true),
        server,
      );
      expect(validateServerUrl('http://[::1]:5150').scheme, 'http');
      for (final invalid in [
        'http://user:password@192.168.1.20',
        'http://192.168.1.20/path',
        'http://192.168.1.20?token=test',
        'http://192.168.1.20#fragment',
        'ftp://192.168.1.20',
      ]) {
        expect(
          () => validateServerUrl(invalid, allowInsecureHttp: true),
          throwsA(isA<SyncFailure>()),
        );
      }
      var requests = 0;
      final crypto = await SyncCrypto.create(
        await SyncCrypto.generateRecoveryKey(),
        'account',
      );
      final client = MockClient((request) async {
        requests++;
        expect(request.url.scheme, 'http');
        expect(request.url.host, server.host);
        expect(request.followRedirects, false);
        expect(request.headers['authorization'], 'Bearer ${'a' * 64}');
        return http.Response(
          jsonEncode({
            'version': 1,
            'account': 'account',
            'key_check': crypto.keyCheck,
          }),
          200,
        );
      });
      await expectLater(
        ServerRemote.connect(server, 'a' * 64, client: client),
        throwsA(isA<SyncFailure>()),
      );
      expect(
        () => ServerRemote(
          server: server,
          token: 'a' * 64,
          crypto: crypto,
          cache: Directory('unused-http-cache'),
          client: client,
        ),
        throwsA(isA<SyncFailure>()),
      );
      expect(requests, 0, reason: 'No bearer token leaves before consent.');
      final session = await ServerRemote.connect(
        server,
        'a' * 64,
        client: client,
        allowInsecureHttp: true,
      );
      expect(session['account'], 'account');
      final remote = ServerRemote(
        server: server,
        token: 'a' * 64,
        crypto: crypto,
        cache: Directory('unused-http-cache'),
        client: client,
        allowInsecureHttp: true,
      );
      expect(await remote.accountId(), contains('account'));
      expect(requests, 2);
      remote.close();
    },
  );

  test(
    'HTTP consent never enables automatic redirects or HTTPS downgrades',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.followRedirects, false);
        return http.Response(
          '',
          302,
          headers: {'location': 'http://other.example.org/api/v1/session'},
        );
      });
      for (final address in [
        'https://sync.example.org',
        'http://sync.example.org',
      ]) {
        await expectLater(
          ServerRemote.connect(
            Uri.parse(address),
            'a' * 64,
            client: client,
            allowInsecureHttp: true,
          ),
          throwsA(isA<SyncFailure>()),
        );
      }
      expect(requests, 2);
      client.close();
    },
  );

  test(
    'Wire data is ciphertext, retries reuse blocks, journal resumes and corruption fails',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-e2ee-');
      final key = await SyncCrypto.generateRecoveryKey();
      final crypto = await SyncCrypto.create(key, 'test-account');
      final blobs = <String, Uint8List>{};
      final commits = <Map<String, dynamic>>[];
      final requestedCursors = <int>[];
      var uploadRequests = 0, downloadRequests = 0;
      var activeUploads = 0,
          activeDownloads = 0,
          peakUploads = 0,
          peakDownloads = 0;
      var corrupt = false;
      final client = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer ${'a' * 64}');
        final path = request.url.path;
        if (path.endsWith('/session')) {
          return http.Response(
            jsonEncode({
              'version': 1,
              'account': crypto.account,
              'key_check': crypto.keyCheck,
            }),
            200,
          );
        }
        if (path.endsWith('/key-check')) return http.Response('', 204);
        if (path.endsWith('/blobs/missing')) {
          final ids = (jsonDecode(request.body)['ids'] as List).cast<String>();
          return http.Response(
            jsonEncode({
              'missing': ids.where((id) => !blobs.containsKey(id)).toList(),
            }),
            200,
          );
        }
        if (path.contains('/blobs/')) {
          final id = request.url.pathSegments.last;
          if (request.method == 'PUT') {
            uploadRequests++;
            activeUploads++;
            if (activeUploads > peakUploads) peakUploads = activeUploads;
            await Future<void>.delayed(const Duration(milliseconds: 80));
            activeUploads--;
            expect(sha256.convert(request.bodyBytes).toString(), id);
            blobs.putIfAbsent(id, () => request.bodyBytes);
            return http.Response('', 204);
          }
          downloadRequests++;
          activeDownloads++;
          if (activeDownloads > peakDownloads) peakDownloads = activeDownloads;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          activeDownloads--;
          final bytes = Uint8List.fromList(blobs[id]!);
          if (corrupt) bytes[0] ^= 1;
          return http.Response.bytes(bytes, 200);
        }
        if (path.endsWith('/commits')) {
          final candidate = jsonDecode(request.body) as Map<String, dynamic>;
          final existing = commits.where((c) => c['id'] == candidate['id']);
          final accepted = existing.isEmpty ? candidate : existing.single;
          if (existing.isEmpty) commits.add(candidate);
          expect(request.body, isNot(contains('Secret title')));
          return http.Response(jsonEncode(accepted), 200);
        }
        if (path.endsWith('/changes')) {
          final after = int.parse(request.url.queryParameters['after']!);
          requestedCursors.add(after);
          return http.Response(
            jsonEncode({
              'cursor': commits.length,
              'items': commits.skip(after).toList(),
            }),
            200,
          );
        }
        return http.Response('', 404);
      });
      ServerRemote remote(String device) => ServerRemote(
        server: Uri.parse('https://example.org'),
        token: 'a' * 64,
        crypto: crypto,
        cache: Directory('${root.path}/$device'),
        client: client,
      );
      try {
        final a = remote('a');
        await a.verifyKey();
        await a.accountId();
        final marker = utf8.encode('Secret title and PDF');
        final bytes = Uint8List(syncBlockBytes * 4 + 1024)
          ..setRange(0, marker.length, marker);
        for (var i = 1; i <= 4; i++) {
          bytes[i * syncBlockBytes] = i;
        }
        final r = SyncRevision(
          noteId: 'secret-id',
          digest: sha256.convert(bytes).toString(),
          parents: [],
        );
        await a.upload(r, bytes);
        await a.upload(r, bytes);
        expect(commits.length, 1);
        expect(blobs.length, 5);
        expect(
          uploadRequests,
          5,
          reason: 'Retry must not transfer completed blocks',
        );
        expect(commits.single.toString(), isNot(contains(r.digest)));
        final b = remote('b');
        expect((await b.list()).single.revision, r.revision);
        expect(await b.download(r), bytes);
        expect(peakUploads, inInclusiveRange(2, 4));
        expect(peakDownloads, inInclusiveRange(2, 4));
        expect(downloadRequests, 5);
        final reopened = remote('b');
        await reopened.list();
        expect(requestedCursors.last, 1);
        corrupt = true;
        expect(
          await reopened.download(r),
          bytes,
          reason: 'Validated cached blocks do not need the server again',
        );
        expect(downloadRequests, 5);
        await for (final file in Directory(
          '${root.path}/b/downloaded',
        ).list()) {
          if (file is File) await file.writeAsBytes([0]);
        }
        await expectLater(reopened.download(r), throwsA(isA<SyncFailure>()));
        corrupt = false;
        commits.single['parents'] = ['b' * 64];
        await expectLater(remote('c').list(), throwsA(isA<SyncFailure>()));
      } finally {
        client.close();
        await root.delete(recursive: true);
      }
    },
  );
}
