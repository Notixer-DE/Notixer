import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_canvas.dart';
import 'live_channel.dart';

class LiveViewerPage extends StatefulWidget {
  const LiveViewerPage({super.key, required this.join});
  final Future<({LiveChannel channel, String token})> Function() join;

  @override
  State<LiveViewerPage> createState() => _LiveViewerPageState();
}

class _LiveViewerPageState extends State<LiveViewerPage> {
  final _model = LiveCanvasModel();
  WebSocketChannel? _socket;
  Timer? _retry;
  late final ({LiveChannel channel, String token}) _access;
  bool _presentation = false;
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
      _access = await widget.join();
      if (mounted) await _connect();
    } catch (_) {
      _end('Could not open this Live Canvas.');
    }
  }

  Future<void> _connect() async {
    try {
      final socket = await _access.channel.join(
        'account-viewer',
        _access.token,
      );
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
              case 'resync':
                _waitingForSnapshot = true;
                _model.cancel(send: false);
                setState(() => _status = 'Recovering the drawing…');
                return;
              case 'host-offline':
                _waitingForSnapshot = true;
                _model.cancel(send: false);
                setState(() => _status = 'Waiting for the host to reconnect…');
                return;
              case 'ended':
                _end('The host ended sharing.');
                return;
              case 'denied':
                _end('This broadcast is unavailable for your device.');
                return;
            }
            final event = await _access.channel.decode(message);
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
      _end('The Live Canvas broadcast is unavailable or has expired.');
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

  void _fullscreen() => setState(() => _presentation = !_presentation);

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
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_presentation) setState(() => _presentation = false);
      },
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: _presentation
            ? null
            : AppBar(
                title: const Text('Live Canvas'),
                actions: [
                  IconButton(
                    tooltip: 'Presentation mode',
                    icon: const Icon(Icons.fullscreen),
                    onPressed: _fullscreen,
                  ),
                ],
              ),
        body: SafeArea(
          child: Column(
            children: [
              if (!_presentation || _status != 'Live')
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Semantics(liveRegion: true, child: Text(_status)),
                ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LiveCanvasSurface(model: _model),
                    if (_presentation)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton.filledTonal(
                          tooltip: 'Exit presentation mode',
                          icon: const Icon(Icons.fullscreen_exit),
                          onPressed: _fullscreen,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
