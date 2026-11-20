import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import '../sync/device_pairing.dart';
import 'device_pairing_scanner.dart';
import '../data/keyboard_shortcuts.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_crypto.dart';
import '../sync/server_remote.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.controller, this.shortcuts});
  final SyncController controller;
  final KeyboardShortcuts? shortcuts;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final _server = TextEditingController(text: widget.controller.serverUrl);
  final _token = TextEditingController();
  final _key = TextEditingController();
  bool _showKey = false;
  bool _allowHttp = false;
  String? _noteId;
  String? _noteTitle;
  bool _validating = false;

  Future<void> _scanPairing() async {
    final sync = widget.controller;
    if (sync.busy) return;
    final pairing = await Navigator.of(context).push<DevicePairing>(
      MaterialPageRoute(builder: (_) => const DevicePairingScanner()),
    );
    if (!mounted || pairing == null) return;
    final form = GlobalKey<FormState>();
    String key = pairing.recoveryKey ?? '';
    final wantsKey = pairing.needsKey && key.isEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Connect to this sync server?'),
        content: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(pairing.server.origin),
              const SizedBox(height: 8),
              Text(
                sync.enabled
                    ? 'This will replace the current connection. The next sync merges your local notes with the new account.'
                    : 'The next sync merges your local notes with this account.',
              ),
              if (wantsKey)
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Recovery key'),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (value) => key = value.trim(),
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Enter the existing recovery key.'
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Pair device'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final generated = key.isEmpty;
    if (generated) key = await SyncCrypto.generateRecoveryKey();
    if (!mounted) return;
    await sync.pair(pairing, key);
    if (!mounted) return;
    final connected = sync.error == null;
    if (connected) {
      _server.text = sync.serverUrl;
      _token.clear();
      _key.clear();
      setState(() => _allowHttp = false);
    }
    if (generated) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Back up your recovery key'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                connected
                    ? 'Keep this key somewhere safe. You can also find it later in Sync settings.'
                    : 'Pairing did not finish. Save this key in case the server already registered it, then generate a new pairing code.',
              ),

              const SizedBox(height: 12),
              SelectableText(key),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _synchronize() async {
    final sync = widget.controller;
    if (_validating || sync.busy) return;
    setState(() => _validating = true);
    try {
      if (_noteId != null) {
        final selected = (await sync.repository.list()).where(
          (n) => n.id == _noteId,
        );
        if (!mounted) return;
        if (selected.isEmpty) {
          setState(() {
            _noteId = null;
            _noteTitle = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The selected note no longer exists. Please check the sync selection again.',
              ),
            ),
          );
          return;
        }
        setState(() => _noteTitle = selected.single.title);
      }
      await sync.synchronize(noteId: _noteId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  Future<void> _chooseNote() async {
    try {
      final notes = await widget.controller.repository.list();
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Select a single note'),
          children: [
            if (notes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No local notes available.'),
              ),
            for (final note in notes)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, note.id),
                child: Text('${note.title}\n${note.documentPath}'),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (!mounted || selected == null) return;
      setState(() {
        _noteId = selected;
        _noteTitle = notes.firstWhere((note) => note.id == selected).title;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load the note list. Please try again.'),
        ),
      );
    }
  }

  Future<void> _setHttpAllowed(bool value) async {
    if (!value) {
      setState(() => _allowHttp = false);
      return;
    }
    final address = _server.text;
    Uri server;
    try {
      server = validateServerUrl(address, allowInsecureHttp: true);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('First enter a valid server address without a path.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Allow HTTP without transport security?'),
        content: Text(
          '${server.origin} does not use TLS. The device access token '
          'and connection metadata can be read or modified in transit. '
          'A stolen token can provide access to your server account. '
          'Note contents remain end-to-end encrypted; this does not replace HTTPS. '
          'Use only on trusted networks you have deliberately chosen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow HTTP anyway'),
          ),
        ],
      ),
    );
    if (mounted && address == _server.text && confirmed == true) {
      setState(() => _allowHttp = true);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.shortcuts != null,
    onKeyEvent: (_, event) {
      if (ModalRoute.of(context)?.isCurrent != true ||
          !widget.controller.enabled ||
          widget.shortcuts?.match(event) != AppShortcut.syncNow) {
        return KeyEventResult.ignored;
      }
      unawaited(_synchronize());
      return KeyEventResult.handled;
    },
    child: _buildSyncPage(),
  );

  Widget _buildSyncPage() => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final sync = widget.controller;
      return AbsorbPointer(
        absorbing: _validating,
        child: PopScope(
          canPop: !sync.busy && !_validating,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Self-hosted sync server'),
              automaticallyImplyLeading: !sync.busy,
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      'Sync your library',
                      style: TextStyle(fontSize: 22),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Notes, media, templates and preferences use end-to-end encryption. '
                      'The server sees technical identifiers, data sizes and access times. '
                      'Notixer remains fully usable offline.',
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(sync.error ?? sync.status),
                    ),
                    if (sync.busy || _validating)
                      const LinearProgressIndicator(),
                    if (sync.enabled) ...[
                      const SizedBox(height: 12),
                      if (sync.usesHttp)
                        Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'HTTP active – connection without TLS',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Text(sync.serverUrl),
                                const Text(
                                  'The access token is unprotected in transit. End-to-end encryption only protects note contents.',
                                ),
                                TextButton(
                                  onPressed: sync.busy
                                      ? null
                                      : sync.disableHttp,
                                  child: const Text('Disable HTTP connection'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Sync note (optional)'),
                        subtitle: Text(
                          _noteTitle ??
                              'Entire library, templates and preferences',
                        ),
                        onTap: sync.busy ? null : _chooseNote,
                        trailing: _noteId == null
                            ? const Icon(Icons.chevron_right)
                            : IconButton(
                                tooltip: 'Clear selection',
                                onPressed: sync.busy
                                    ? null
                                    : () => setState(() {
                                        _noteId = null;
                                        _noteTitle = null;
                                      }),
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      const Text(
                        'This selection only applies to manual sync. '
                        'Automatic sync rules remain unchanged.',
                      ),
                      FilledButton.icon(
                        onPressed: sync.busy ? null : _synchronize,
                        icon: const Icon(Icons.sync),
                        label: Text(
                          _noteId == null ? 'Sync now' : 'Sync selected note',
                        ),
                      ),
                      SwitchListTile.adaptive(
                        title: const Text('Automatic sync'),
                        subtitle: const Text(
                          'At startup and after changes in the library. Open notes sync after closing.',
                        ),
                        value: sync.automatic,
                        onChanged: sync.busy ? null : sync.setAutomatic,
                      ),
                      TextButton(
                        onPressed: sync.busy
                            ? null
                            : () async {
                                final key = await sync.recoveryKey();
                                if (!context.mounted || key == null) return;
                                await showDialog<void>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text(
                                      'Keep your recovery key safe',
                                    ),
                                    content: SelectableText(
                                      'This key provides access to all notes. '
                                      'Do not send it to the server operator. Without it or a configured device, the data is lost.\n\n$key',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Close'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                        child: const Text('Show recovery key'),
                      ),
                      TextButton(
                        onPressed: sync.busy
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Remove device key?'),
                                    content: const Text(
                                      'Credentials and the recovery key will be removed from this device\'s keychain. '
                                      'Only continue if the recovery key is safely backed up or available on another device.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text(
                                          'Key backed up, disconnect',
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await sync.disconnect();
                                  if (mounted && !sync.enabled) {
                                    setState(() {
                                      _noteId = null;
                                      _noteTitle = null;
                                    });
                                  }
                                }
                              },
                        child: const Text('Disconnect this device'),
                      ),
                    ],
                    const Divider(height: 40),
                    const Text(
                      'Set up a new connection',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Text(
                      'Ask the server operator for a separate access token for each device. '
                      'Use the same recovery key on all devices belonging to the same account. '
                      'Only generate new keys for an empty account.',
                    ),
                    if (defaultTargetPlatform == TargetPlatform.android) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: sync.busy ? null : _scanPairing,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan pairing QR code'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: _server,
                      enabled: !sync.busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onChanged: (_) => setState(() => _allowHttp = false),
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://sync.example.org',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow HTTP for this new connection'),
                      subtitle: const Text(
                        'Insecure: requires explicit confirmation. HTTPS is recommended. Confirm again if the server address changes. HTTP remains available on localhost.',
                      ),
                      value: _allowHttp,
                      onChanged:
                          sync.busy ||
                              Uri.tryParse(_server.text.trim())?.scheme !=
                                  'http'
                          ? null
                          : _setHttpAllowed,
                    ),
                    TextField(
                      controller: _token,
                      enabled: !sync.busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Device access token',
                      ),
                    ),
                    TextField(
                      controller: _key,
                      enabled: !sync.busy,
                      obscureText: !_showKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Recovery key',
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _showKey = !_showKey),
                          icon: Icon(
                            _showKey ? Icons.visibility_off : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: sync.busy || sync.enabled
                          ? null
                          : () async {
                              final key =
                                  await SyncCrypto.generateRecoveryKey();
                              if (!mounted) return;
                              setState(() {
                                _key.text = key;
                                _showKey = true;
                              });
                            },
                      child: const Text('Generate key for a new account'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: sync.busy
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Recovery key backed up?'),
                                  content: const Text(
                                    'Without this key or a configured device, your notes cannot be recovered. '
                                    'Store it safely outside this device. The server operator cannot reset it. '
                                    'The next sync will merge all local notes with this server account.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Back'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Safely saved'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true || !mounted) return;
                              await sync.connect(
                                _server.text,
                                _token.text,
                                _key.text,
                                allowHttp: _allowHttp,
                              );
                              if (mounted && sync.error == null) {
                                _token.clear();
                                _key.clear();
                                setState(() => _allowHttp = false);
                              }
                            },
                      child: const Text('Connect to server'),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Concurrent changes are preserved as conflict copies. '
                      'Deletions, pen presets and empty folders are also synced. '
                      'Existing cloud copies are neither imported nor deleted. '
                      'Create local .noter backups before switching.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
