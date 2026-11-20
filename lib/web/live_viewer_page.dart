import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../live/live_channel.dart';
import '../live/live_viewer_page.dart';
import '../sync/server_remote.dart';
import '../sync/sync_crypto.dart';
import '../ui/noter_theme.dart';

class LiveViewerApp extends StatelessWidget {
  const LiveViewerApp({super.key, required this.url});
  final Uri url;

  Future<({LiveChannel channel, String role, String token})> _join() async {
    final params = Uri.splitQueryString(url.fragment.substring(5));
    final id = params['room'];
    final token = params['invite'];
    final key = params['key'];
    if (id == null ||
        token == null ||
        key == null ||
        !liveTokenPattern.hasMatch(id) ||
        !liveTokenPattern.hasMatch(token)) {
      throw const FormatException('Invalid Live Canvas invitation.');
    }
    final server = validateServerUrl(url.origin);
    return (
      channel: LiveChannel(server, id, await SyncCrypto.create(key, id)),
      role: 'viewer',
      token: token,
    );
  }

  Future<void> _toggleFullscreen() async {
    if (web.document.fullscreenElement != null) {
      await web.document.exitFullscreen().toDart;
    } else {
      await web.document.documentElement?.requestFullscreen().toDart;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Notixer Live Canvas',
    theme: NoterTheme.light,
    initialRoute: '/',
    home: LiveViewerPage(join: _join, toggleFullscreen: _toggleFullscreen),
  );
}
