import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_remote.dart';
import 'sync_revision.dart';

class DevicePairing {
  const DevicePairing._(
    this.server,
    this.account,
    this.code,
    this.needsKey,
    this.recoveryKey,
  );

  static const _prefix = 'notixer-pair:';
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  static final _key = RegExp(r'^[A-Za-z0-9_-]{43}=?$');

  final Uri server;
  final String account, code;
  final bool needsKey;
  final String? recoveryKey;

  static DevicePairing parse(String input) {
    const invalid = SyncFailure('Scan a valid Notixer pairing QR code.');
    if (!input.startsWith(_prefix) || input.length > 1024) throw invalid;
    try {
      final value = jsonDecode(input.substring(_prefix.length));
      if (value is! Map<String, dynamic> ||
          value['v'] != 1 ||
          value['server'] is! String ||
          value['account'] is! String ||
          value['code'] is! String ||
          value['needsKey'] is! bool ||
          !_uuid.hasMatch(value['account'] as String) ||
          !syncHashPattern.hasMatch(value['code'] as String) ||
          (value['key'] != null &&
              (value['key'] is! String ||
                  !_key.hasMatch(value['key'] as String)))) {
        throw invalid;
      }
      final server = validateServerUrl(value['server'] as String);
      return DevicePairing._(
        server,
        value['account'] as String,
        value['code'] as String,
        value['needsKey'] as bool,
        value['key'] as String?,
      );
    } on FormatException {
      throw invalid;
    }
  }

  Future<String> redeem(String keyCheck, {http.Client? client}) async {
    final transport = client ?? http.Client();
    try {
      final request =
          http.Request('POST', server.resolve('/api/v1/pairing/redeem'))
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({
              'account': account,
              'code': code,
              'key_check': keyCheck,
            });
      final response = await transport
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw SyncFailure(switch (response.statusCode) {
          401 =>
            'This QR code has expired or was already used. Generate a new one.',
          409 =>
            'The recovery key does not match this account. The QR code can be used again.',
          404 => 'The server does not support QR pairing yet.',
          _ => 'The server did not accept the pairing request.',
        });
      }
      final body = StringBuffer();
      await for (final part in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (body.length + part.length > 4096) {
          throw const SyncFailure('Invalid pairing response.');
        }
        body.write(String.fromCharCodes(part));
      }
      final value = jsonDecode(body.toString());
      final token = value is Map ? value['token'] : null;
      if (token is! String || !syncHashPattern.hasMatch(token)) {
        throw const SyncFailure('Invalid pairing response.');
      }
      return token;
    } finally {
      if (client == null) transport.close();
    }
  }
}
