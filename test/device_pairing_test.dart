import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noter/sync/device_pairing.dart';
import 'package:noter/sync/sync_revision.dart';

void main() {
  const account = '8c504cb3-ea0b-4ba4-a87c-b1e78f5500cf';
  final code = 'a' * 64;
  final key = base64UrlEncode(List.filled(32, 7));
  String payload({
    String server = 'https://example.test',
    Object? version = 1,
  }) =>
      'notixer-pair:${jsonEncode({'v': version, 'server': server, 'account': account, 'code': code, 'needsKey': true, 'key': key})}';

  test('only valid Notixer invitations for the server origin are accepted', () {
    final pairing = DevicePairing.parse(payload());
    expect(pairing.server.origin, 'https://example.test');
    expect(pairing.recoveryKey, key);
    expect(pairing.needsKey, isTrue);
    for (final input in [
      'https://example.test',
      payload(version: 2),
      payload(server: 'https://example.test/other'),
      payload(server: 'http://example.test'),
      payload(server: 'https://user:pass@example.test'),
    ]) {
      expect(() => DevicePairing.parse(input), throwsA(isA<SyncFailure>()));
    }
  });

  test(
    'pairing transmits only the invitation and key check and blocks redirects',
    () async {
      final pairing = DevicePairing.parse(payload());
      final token = 'b' * 64;
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.test/api/v1/pairing/redeem',
        );
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(jsonDecode(request.body), {
          'account': account,
          'code': code,
          'key_check': 'c' * 64,
        });
        return http.Response(jsonEncode({'token': token}), 200);
      });
      expect(await pairing.redeem('c' * 64, client: client), token);
    },
  );

  test('wrong key and expired invitation produce actionable errors', () async {
    final pairing = DevicePairing.parse(payload());
    for (final (status, text) in [(409, 'does not match'), (401, 'expired')]) {
      final client = MockClient((_) async => http.Response('', status));
      await expectLater(
        pairing.redeem('c' * 64, client: client),
        throwsA(
          isA<SyncFailure>().having(
            (error) => error.message,
            'message',
            contains(text),
          ),
        ),
      );
    }
  });
}
