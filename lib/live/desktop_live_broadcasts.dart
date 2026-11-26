import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../sync/sync_controller.dart';
import 'live_sessions.dart';
import 'live_viewer_page.dart';

/// Shared workspace notice, including when a desktop editor tab is open.
class DesktopLiveBroadcasts extends StatefulWidget {
  const DesktopLiveBroadcasts({super.key, required this.sync});
  final SyncController sync;

  @override
  State<DesktopLiveBroadcasts> createState() => _DesktopLiveBroadcastsState();
}

class _DesktopLiveBroadcastsState extends State<DesktopLiveBroadcasts> {
  final _client = http.Client();
  Timer? _timer;
  LiveCredentials? _credentials;
  List<({String id, String device})> _sessions = [];
  bool _checking = false, _opening = false;

  @override
  void initState() {
    super.initState();
    widget.sync.addListener(_syncChanged);
    _syncChanged();
  }

  void _syncChanged() {
    if (widget.sync.enabled) {
      if (_timer == null) {
        _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check());
        unawaited(_check());
      }
    } else {
      _timer?.cancel();
      _timer = null;
      _update(null, []);
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final credentials = await widget.sync.liveCredentials();
      if (!mounted || credentials == null) return;
      if (_credentials != credentials) _update(credentials, []);
      final sessions = await LiveSessions(
        credentials,
        client: _client,
      ).active();
      if (mounted &&
          await widget.sync.liveCredentials() == credentials &&
          mounted) {
        _update(credentials, sessions);
      }
    } catch (_) {
      if (mounted) _update(null, []);
    } finally {
      _checking = false;
    }
  }

  void _update(
    LiveCredentials? credentials,
    List<({String id, String device})> sessions,
  ) {
    _credentials = credentials;
    if (!listEquals(_sessions, sessions)) setState(() => _sessions = sessions);
  }

  Future<void> _watch() async {
    if (_opening) return;
    _opening = true;
    final sessions = _sessions;
    final credentials = _credentials;
    try {
      if (credentials == null || sessions.isEmpty) return;
      final id = sessions.length == 1
          ? sessions.single.id
          : await showDialog<String>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Live Canvases'),
                children: [
                  for (final session in sessions)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, session.id),
                      child: Text(
                        'Device ${session.device.split('-').first} · ${session.id.substring(0, 6)}',
                      ),
                    ),
                ],
              ),
            );
      if (id == null || !mounted) return;
      if (await widget.sync.liveCredentials() != credentials || !mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LiveViewerPage(
            join: () async => (
              channel: await LiveSessions(credentials).channel(id),
              token: credentials.token,
            ),
          ),
        ),
      );
    } finally {
      _opening = false;
    }
  }

  @override
  void dispose() {
    widget.sync.removeListener(_syncChanged);
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.cast_connected),
          title: Text(
            _sessions.length == 1
                ? 'Live Canvas is being shared'
                : '${_sessions.length} Live Canvases are being shared',
          ),
          trailing: FilledButton.tonal(
            onPressed: _watch,
            child: const Text('Watch live'),
          ),
        ),
      ),
    );
  }
}
