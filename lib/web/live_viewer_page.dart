import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../live/live_canvas.dart';
import '../live/live_channel.dart';
import '../sync/server_remote.dart';
import '../sync/sync_crypto.dart';
import '../ui/noter_theme.dart';

class LiveViewerApp extends StatelessWidget {
  const LiveViewerApp({super.key, required this.url});
  final Uri url;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Notixer Live Canvas',
    theme: NoterTheme.light,
    initialRoute: '/',
    home: _LiveViewerPage(url),
  );
}

class _LiveViewerPage extends StatefulWidget {
  const _LiveViewerPage(this.url);
  final Uri url;

  @override
  State<_LiveViewerPage> createState() => _LiveViewerPageState();
}

class _LiveViewerPageState extends State<_LiveViewerPage> {
  final _model = LiveCanvasModel();
  WebSocketChannel? _socket;
  Timer? _retry;
  LiveChannel? _channel;
  String? _token;
  int? _sequence;
  bool _waitingForSnapshot = true;
  int _attempts = 0;
  bool _finished = false;
  String _status = 'Connecting…';

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final params = Uri.splitQueryString(widget.url.fragment.substring(5));
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
      final server = validateServerUrl(widget.url.origin);
      _channel = LiveChannel(server, id, await SyncCrypto.create(key, id));
      _token = token;
      if (mounted) await _connect();
    } catch (_) {
      _end('This Live Canvas invitation is invalid.');
    }
  }

  Future<void> _connect() async {
    try {
      final socket = await _channel!.join('viewer', _token!);
      if (!mounted || _finished) {
        await socket.sink.close();
        return;
      }
      _socket = socket;
      _waitingForSnapshot = true;
      socket.stream
          .asyncMap((message) async {
            if (_socket != socket || !mounted) return;
            switch (message) {
              case 'joined':
                setState(() => _status = 'Waiting for the drawing…');
                return;
              case 'ended':
                _end('The host ended sharing.');
                return;
              case 'denied':
                _end('This invitation is invalid or has expired.');
                return;
            }
            final event = await _channel!.decode(message);
            if (_socket != socket || !mounted) return;
            final sequence = event['seq'] as int;
            final previous = _sequence;
            if (event['type'] == 'snapshot') {
              if (previous != null && sequence <= previous) return;
              _model.receive(event);
              _sequence = sequence;
              _waitingForSnapshot = false;
              _attempts = 0;
              setState(() => _status = 'Live');
            } else if (!_waitingForSnapshot && previous != null) {
              if (sequence != previous + 1) {
                throw StateError('Live Canvas sequence gap.');
              }
              _model.receive(event);
              _sequence = sequence;
            }
          })
          .listen(
            (_) {},
            onError: (Object _) => _lost(socket),
            onDone: () => _lost(socket),
          );
    } catch (_) {
      _lost(null);
    }
  }

  void _lost(WebSocketChannel? socket) {
    if (_socket != socket || !mounted || _finished) return;
    _socket = null;
    if (socket != null) unawaited(socket.sink.close());
    _model.cancel(send: false);
    if (++_attempts > 12) {
      _end('The Live Canvas is unavailable or the invitation has expired.');
      return;
    }
    setState(() => _status = 'Reconnecting…');
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _attempts > 4 ? 8 : 2), _connect);
  }

  void _end(String status) {
    _finished = true;
    _retry?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.sink.close());
    if (mounted) setState(() => _status = status);
  }

  Future<void> _fullscreen() async {
    try {
      if (web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      } else {
        await web.document.documentElement?.requestFullscreen().toDart;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Full screen is unavailable in this browser.'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.sink.close());
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Live Canvas'),
      actions: [
        IconButton(
          tooltip: 'Full screen',
          icon: const Icon(Icons.fullscreen),
          onPressed: _fullscreen,
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Semantics(liveRegion: true, child: Text(_status)),
          ),
          Expanded(child: LiveCanvasSurface(model: _model)),
        ],
      ),
    ),
  );
}
