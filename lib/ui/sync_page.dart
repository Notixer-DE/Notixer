import 'package:flutter/material.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_crypto.dart';
import '../sync/server_remote.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.controller});
  final SyncController controller;
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
                'Die ausgewählte Notiz ist nicht mehr vorhanden. Bitte die Sync-Auswahl erneut prüfen.',
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
          title: const Text('Einzelne Notiz auswählen'),
          children: [
            if (notes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Keine lokalen Notizen vorhanden.'),
              ),
            for (final note in notes)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, note.id),
                child: Text('${note.title}\n${note.documentPath}'),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
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
          content: Text(
            'Notizliste konnte nicht geladen werden. Bitte erneut versuchen.',
          ),
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
          content: Text(
            'Zuerst eine gültige Serveradresse ohne Pfad eingeben.',
          ),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('HTTP ohne Transportschutz erlauben?'),
        content: Text(
          'Für ${server.origin} wird kein TLS verwendet. Der Geräte-Zugangstoken '
          'und Verbindungsmetadaten können mitgelesen oder manipuliert werden. '
          'Ein gestohlener Token kann Zugriff auf dein Serverkonto ermöglichen. '
          'Die Notizinhalte bleiben Ende-zu-Ende verschlüsselt; das ersetzt HTTPS nicht. '
          'Nur für bewusst gewählte, vertrauenswürdige Netze verwenden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('HTTP trotzdem erlauben'),
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final sync = widget.controller;
      return AbsorbPointer(
        absorbing: _validating,
        child: PopScope(
          canPop: !sync.busy && !_validating,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Eigener Sync-Server'),
              automaticallyImplyLeading: !sync.busy,
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      'Notizen Ende-zu-Ende verschlüsselt synchronisieren',
                      style: TextStyle(fontSize: 22),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Nur deine Geräte entschlüsseln Notizen, PDFs, Titel, Tags und Ordnernamen. '
                      'Der Server sieht technische Kennungen, Datenmengen und Zugriffszeiten. '
                      'Offline bleibt Notixer vollständig nutzbar.',
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
                                  'HTTP aktiv – Verbindung ohne TLS',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Text(sync.serverUrl),
                                const Text(
                                  'Der Zugangstoken ist auf dem Transportweg ungeschützt. Ende-zu-Ende-Verschlüsselung schützt nur die Notizinhalte.',
                                ),
                                TextButton(
                                  onPressed: sync.busy
                                      ? null
                                      : sync.disableHttp,
                                  child: const Text(
                                    'HTTP-Verbindung deaktivieren',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Sync-Datei (optional)'),
                        subtitle: Text(_noteTitle ?? 'Alle Notizen'),
                        onTap: sync.busy ? null : _chooseNote,
                        trailing: _noteId == null
                            ? const Icon(Icons.chevron_right)
                            : IconButton(
                                tooltip: 'Auswahl aufheben',
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
                        'Die Auswahl gilt nur für den manuellen Abgleich. '
                        'Die Regeln für automatischen Sync bleiben unverändert.',
                      ),
                      FilledButton.icon(
                        onPressed: sync.busy ? null : _synchronize,
                        icon: const Icon(Icons.sync),
                        label: Text(
                          _noteId == null
                              ? 'Jetzt synchronisieren'
                              : 'Ausgewählte Notiz synchronisieren',
                        ),
                      ),
                      SwitchListTile.adaptive(
                        title: const Text('Automatisch synchronisieren'),
                        subtitle: const Text(
                          'Beim Start und nach Änderungen in der Übersicht. Geöffnete Notizen nach dem Schließen.',
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
                                      'Wiederherstellungsschlüssel sicher aufbewahren',
                                    ),
                                    content: SelectableText(
                                      'Dieser Schlüssel gibt Zugriff auf sämtliche Notizen. '
                                      'Nicht an den Serverbetreiber senden. Ohne ihn und ohne eingerichtetes Gerät sind die Daten verloren.\n\n$key',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Schließen'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                        child: const Text(
                          'Wiederherstellungsschlüssel anzeigen',
                        ),
                      ),
                      TextButton(
                        onPressed: sync.busy
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text(
                                      'Geräteschlüssel entfernen?',
                                    ),
                                    content: const Text(
                                      'Zugang und Wiederherstellungsschlüssel werden aus dem Schlüsselbund dieses Geräts entfernt. '
                                      'Nur fortfahren, wenn der Wiederherstellungsschlüssel sicher gesichert oder auf einem weiteren Gerät vorhanden ist.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('Abbrechen'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text(
                                          'Schlüssel gesichert, trennen',
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
                        child: const Text('Auf diesem Gerät trennen'),
                      ),
                    ],
                    const Divider(height: 40),
                    const Text(
                      'Neue Verbindung einrichten',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Text(
                      'Für jedes Gerät einen eigenen Zugangstoken beim Betreiber anlegen. '
                      'Auf allen Geräten desselben Kontos denselben Wiederherstellungsschlüssel verwenden. '
                      'Neue Schlüssel nur für ein noch leeres Konto erzeugen.',
                    ),
                    TextField(
                      controller: _server,
                      enabled: !sync.busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onChanged: (_) => setState(() => _allowHttp = false),
                      decoration: const InputDecoration(
                        labelText: 'Serveradresse',
                        hintText: 'https://sync.example.org',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'HTTP für diese neue Verbindung erlauben',
                      ),
                      subtitle: const Text(
                        'Unsicher: nur nach ausdrücklicher Bestätigung. HTTPS bleibt empfohlen. Bei geänderter Serveradresse erneut bestätigen. HTTP auf localhost bleibt wie bisher möglich.',
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
                        labelText: 'Geräte-Zugangstoken',
                      ),
                    ),
                    TextField(
                      controller: _key,
                      enabled: !sync.busy,
                      obscureText: !_showKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Wiederherstellungsschlüssel',
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
                      child: const Text('Schlüssel für neues Konto erzeugen'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: sync.busy
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text(
                                    'Wiederherstellungsschlüssel gesichert?',
                                  ),
                                  content: const Text(
                                    'Ohne diesen Schlüssel und ohne eingerichtetes Gerät lassen sich deine Notizen nicht wiederherstellen. '
                                    'Speichere ihn sicher außerhalb dieses Geräts. Der Serverbetreiber kann ihn nicht zurücksetzen. '
                                    'Beim anschließenden Abgleich werden alle lokalen Notizen mit diesem Serverkonto zusammengeführt.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Zurück'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Sicher gespeichert'),
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
                      child: const Text('Mit Server verbinden'),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Parallele Änderungen bleiben als Konfliktkopien erhalten. '
                      'Löschungen werden übertragen. Stiftfavoriten und leere Ordner bleiben lokal. '
                      'Bestehende Cloudkopien werden weder importiert noch gelöscht. '
                      'Vor dem Wechsel lokale .noter-Sicherungen erstellen.',
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
