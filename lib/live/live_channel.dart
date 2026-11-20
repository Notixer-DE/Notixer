import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../sync/sync_crypto.dart';

const liveFrameLimit = 2 * 1024 * 1024;
final liveTokenPattern = RegExp(r'^[a-f0-9]{64}$');

class LiveChannel {
  LiveChannel(this.server, this.id, this.crypto);

  final Uri server;
  final String id;
  final SyncCrypto crypto;

  Future<WebSocketChannel> join(String role, String token) async {
    final socket = WebSocketChannel.connect(
      server.replace(
        scheme: server.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/v1/live/$id',
      ),
    );
    try {
      await socket.ready.timeout(const Duration(seconds: 8));
      socket.sink.add(jsonEncode({'role': role, 'token': token}));
      return socket;
    } catch (_) {
      unawaited(socket.sink.close());
      rethrow;
    }
  }

  Future<Uint8List> encode(Map<String, Object> event, int sequence) async {
    final data = utf8.encode(jsonEncode({...event, 'v': 1, 'seq': sequence}));
    if (data.length + 28 > liveFrameLimit) {
      throw const FormatException('This canvas is too large to share live.');
    }
    return crypto.encrypt(data, 'live-canvas');
  }

  Future<Map<String, dynamic>> decode(Object message) async {
    if (message is! List<int> || message.length > liveFrameLimit) {
      throw const FormatException('Invalid Live Canvas frame.');
    }
    final plain = await crypto.decrypt(message, 'live-canvas');
    final event = jsonDecode(utf8.decode(plain));
    if (event is! Map<String, dynamic> ||
        event['v'] != 1 ||
        event['seq'] is! int ||
        (event['seq'] as int) < 1) {
      throw const FormatException('Invalid Live Canvas event.');
    }
    return event;
  }
}
