import 'package:flutter/material.dart';

import 'web_sync.dart';

class WebSyncPage extends StatefulWidget {
  const WebSyncPage({super.key, required this.sync});
  final WebSync sync;

  @override
  State<WebSyncPage> createState() => _WebSyncPageState();
}

class _WebSyncPageState extends State<WebSyncPage> {
  late final _address = TextEditingController(
    text: widget.sync.address ?? Uri.base.origin,
  );
  final _token = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;
  String? _status, _error;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.sync.connected;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Self-hosted sync server')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (!connected) ...[
                  const Text(
                    'Enter the device token and recovery key for your existing Notixer vault. Credentials are kept in this tab until you close or reload it.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _address,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Device token',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Recovery key',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await widget.sync.connect(
                              _address.text,
                              _token.text,
                              _key.text,
                            );
                            _token.clear();
                            _key.clear();
                            if (mounted) {
                              setState(
                                () => _status =
                                    'Connected. End-to-end encryption is active.',
                              );
                            }
                          }),
                    child: const Text('Connect'),
                  ),
                ] else ...[
                  Text(widget.sync.address ?? ''),
                  const SizedBox(height: 8),
                  const Text(
                    'Sync exchanges library changes with the connected vault.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.sync),
                        label: const Text('Sync now'),
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                final report = await widget.sync.synchronize((
                                  value,
                                ) {
                                  if (mounted) setState(() => _status = value);
                                });
                                if (mounted) {
                                  setState(() => _status = '$report');
                                }
                              }),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                widget.sync.disconnect();
                                _status = 'Disconnected.';
                              }),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                ],
                if (_status case final status?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      label: status,
                      excludeSemantics: true,
                      child: Text(status),
                    ),
                  ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
