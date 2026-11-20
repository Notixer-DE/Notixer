import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sync/sync_controller.dart';
import '../sync/sync_crypto.dart';
import 'live_channel.dart';

class LiveSessions {
  const LiveSessions(this.credentials);

  final LiveCredentials credentials;

  Future<LiveChannel> start() async {
    final response = await _request('POST', '/api/v1/live');
    if (response.statusCode != 200) {
      throw FormatException(switch (response.statusCode) {
        401 || 403 =>
          'Device access is invalid or revoked. Reconnect in Sync settings.',
        404 || 405 => 'Update the sync server to use Live Canvas.',
        429 =>
          'The Live Canvas session limit is reached. Stop another session or try again later.',
        502 || 503 || 504 =>
          'The sync server is unavailable (${response.statusCode}). Check that the server and its database are running.',
        _ =>
          'The server could not start a Live Canvas session (${response.statusCode}).',
      });
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = _roomId(body['id']);
    try {
      if (body['account_only'] != true) {
        throw const FormatException(
          'Update the sync server to share privately with other apps.',
        );
      }
      return await channel(id);
    } catch (_) {
      await end(id).catchError((Object _) {});
      rethrow;
    }
  }

  Future<List<({String id, String device})>> active() async {
    final response = await _request('GET', '/api/v1/live');
    if (response.statusCode == 405 || response.statusCode == 404) {
      throw const FormatException(
        'Update the sync server to find Live Canvas broadcasts.',
      );
    }
    if (response.statusCode != 200) {
      throw const FormatException(
        'Could not check for Live Canvas broadcasts.',
      );
    }
    final sessions = jsonDecode(response.body) as List;
    return [
      for (final session in sessions)
        (id: _roomId(session['id']), device: session['host_device'] as String),
    ]..sort((a, b) {
      final device = a.device.compareTo(b.device);
      return device == 0 ? a.id.compareTo(b.id) : device;
    });
  }

  Future<LiveChannel> channel(String id) async => LiveChannel(
    credentials.server,
    id,
    await SyncCrypto.create(credentials.crypto.liveRoomKey(id), id),
  );

  Future<void> end(String id) async {
    final response = await _request('DELETE', '/api/v1/live/$id');
    if (response.statusCode != 204) {
      throw const FormatException('Could not end the sharing session.');
    }
  }

  Future<http.Response> _request(String method, String path) async {
    final client = http.Client();
    try {
      final request = http.Request(method, credentials.server.resolve(path))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${credentials.token}';
      return await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
  }

  static String _roomId(Object? value) {
    if (value is! String || !liveTokenPattern.hasMatch(value)) {
      throw const FormatException('Invalid Live Canvas session.');
    }
    return value;
  }
}
