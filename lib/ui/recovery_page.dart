import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import '../data/notebook.dart';
import '../data/markdown_document.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'markdown_style.dart';
import 'noter_theme.dart';

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, required this.repository, this.note});
  final LocalNotebookRepository repository;
  final Notebook? note;

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  List<RecoveryEntry> _entries = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(_refresh);
  }

  Future<void> _refresh() async {
    final entries = await widget.repository.recovery(id: widget.note?.id);
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = 'Aktion fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Endgültig löschen'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _purge(RecoveryEntry entry) async {
    if (!await _confirm(
          'Endgültig löschen?',
          '„${entry.note.title}“ und alle lokalen früheren Stände werden '
              'unwiderruflich gelöscht. Server-Versionen werden nicht entfernt.',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      await widget.repository.purgeTrash(entry.note.id);
      await _refresh();
    });
  }

  Future<void> _clearHistory() async {
    if (!await _confirm(
          'Versionshistorie löschen?',
          'Alle lokalen früheren Stände dieser Notiz werden unwiderruflich '
              'gelöscht. Die aktuelle Notiz und Server-Versionen bleiben erhalten.',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      await widget.repository.clearHistory(widget.note!.id);
      await _refresh();
    });
  }

  Future<void> _preview(RecoveryEntry entry) async {
    final restore = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            _RecoveryPreview(repository: widget.repository, entry: entry),
      ),
    );
    if (restore != true || !mounted) return;
    await _run(() async {
      final note = await widget.repository.restore(entry);
      if (mounted) Navigator.pop(context, note);
    });
  }

  Future<void> _history(RecoveryEntry entry) async {
    final note = await Navigator.of(context).push<Notebook>(
      MaterialPageRoute(
        builder: (_) =>
            RecoveryPage(repository: widget.repository, note: entry.note),
      ),
    );
    if (note != null && mounted) Navigator.pop(context, note);
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.note != null;
    final bytes = _entries.fold<int>(0, (sum, entry) => sum + entry.size);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(history ? 'Versionshistorie' : 'Papierkorb'),
          actions: [
            if (history)
              IconButton(
                tooltip: 'Versionshistorie löschen',
                onPressed: _busy || _entries.isEmpty ? null : _clearHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            IconButton(
              tooltip: 'Neu laden',
              onPressed: _busy ? null : () => _run(_refresh),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  history
                      ? '${widget.note!.title}\nVor dem Überschreiben wird höchstens '
                            'alle fünf Minuten ein früherer Stand gesichert; bei '
                            'Sync-Ersetzungen immer. Maximal 20 Stände / 512 MiB je '
                            'Notiz. Wiederherstellen erzeugt eine neue Kopie.'
                      : 'Gelöschte Notizen bleiben hier ohne Zeitlimit. '
                            'Wiederherstellen erzeugt eine neue Kopie; das Original '
                            'bleibt im Papierkorb. Papierkorb und Historie sind nur '
                            'auf diesem Gerät verfügbar.',
                ),
              ),
              if (_entries.isNotEmpty)
                Text(
                  '${_entries.length} ${_entries.length == 1 ? 'Eintrag' : 'Einträge'} · '
                  '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: _entries.isEmpty && !_busy && _error == null
                    ? Center(
                        child: Text(
                          history
                              ? 'Noch keine früheren Stände vorhanden.'
                              : 'Der Papierkorb ist leer.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return ListTile(
                            leading: const Icon(Icons.restore_page_outlined),
                            title: Text(entry.note.title),
                            subtitle: Text(
                              '${history ? 'Gesichert' : 'Zuletzt bearbeitet'}: '
                              '${_date(history ? entry.recorded : entry.note.modified)}\n'
                              'Vorschau öffnen und als neue Notiz wiederherstellen',
                            ),
                            isThreeLine: true,
                            onTap: _busy ? null : () => _preview(entry),
                            trailing: history
                                ? null
                                : PopupMenuButton<String>(
                                    enabled: !_busy,
                                    tooltip: 'Papierkorbaktionen',
                                    onSelected: (value) => value == 'history'
                                        ? _history(entry)
                                        : _purge(entry),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'history',
                                        child: Text('Versionshistorie'),
                                      ),
                                      PopupMenuItem(
                                        value: 'purge',
                                        child: Text('Endgültig löschen'),
                                      ),
                                    ],
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryPreview extends StatefulWidget {
  const _RecoveryPreview({required this.repository, required this.entry});
  final LocalNotebookRepository repository;
  final RecoveryEntry entry;

  @override
  State<_RecoveryPreview> createState() => _RecoveryPreviewState();
}

class _RecoveryPreviewState extends State<_RecoveryPreview> {
  late final Future<Object> _document = widget.repository
      .recoveryPdf(widget.entry)
      .then(
        (bytes) async => widget.entry.note.isMarkdown
            ? await decodeMarkdownAsync(bytes)
            : PdfDocument.open(bytes),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Vorschau: ${widget.entry.note.title}')),
    body: SafeArea(
      child: FutureBuilder<Object>(
        future: _document,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Vorschau konnte nicht geladen werden: ${snapshot.error}',
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Schreibgeschützte Vorschau. Der aktuelle Stand '
                  'und die Sicherung bleiben unverändert.',
                ),
              ),
              Expanded(
                child: snapshot.data is MarkdownDocument
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: MarkdownBody(
                          styleSheet: noterMarkdownStyle(context),
                          data: (snapshot.data! as MarkdownDocument).source,
                          selectable: true,
                          imageBuilder: (_, _, _) =>
                              const Text('[Bild in Sicherung]'),
                        ),
                      )
                    : PdfViewerTheme(
                        data: const PdfViewerThemeData(
                          canvasColor: NoterTheme.workspace,
                          selectionHandleColor: NoterTheme.accent,
                          annotationChromeColor: NoterTheme.accent,
                        ),
                        child: PdfViewer(
                          document: snapshot.data! as PdfDocument,
                          interactiveForms: false,
                          contextMenuEnabled: false,
                          textSelectionEditing: false,
                          textSelectionMarkup: false,
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.restore),
                  label: const Text('Als neue Notiz wiederherstellen'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
