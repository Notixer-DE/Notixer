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
      if (mounted) setState(() => _error = 'Action failed: $e');
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _purge(RecoveryEntry entry) async {
    if (!await _confirm(
          'Delete permanently?',
          '„${entry.note.title}“ and all previous local versions will be '
              'permanently deleted. Server versions will not be removed.',
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
          'Clear version history?',
          'All previous local versions of this note will be permanently '
              'deleted. The current note and server versions are preserved.',
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
          title: Text(history ? 'Version history' : 'Trash'),
          actions: [
            if (history)
              IconButton(
                tooltip: 'Clear version history',
                onPressed: _busy || _entries.isEmpty ? null : _clearHistory,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            IconButton(
              tooltip: 'Reload',
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
                      ? '${widget.note!.title}\nBefore overwriting, a previous version is saved at most '
                            'once every five minutes; before '
                            'sync replacements, always. Maximum 20 versions / 512 MiB per '
                            'note. Restoring creates a new copy.'
                      : 'Deleted notes stay here without a time limit. '
                            'Restoring creates a new copy; the original '
                            'stays in the trash. Trash and history are only '
                            'available on this device.',
                ),
              ),
              if (_entries.isNotEmpty)
                Text(
                  '${_entries.length} ${_entries.length == 1 ? 'entry' : 'entries'} · '
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
                              ? 'No previous versions yet.'
                              : 'The trash is empty.',
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
                              'Open a preview and restore as a new note',
                            ),
                            isThreeLine: true,
                            onTap: _busy ? null : () => _preview(entry),
                            trailing: history
                                ? null
                                : PopupMenuButton<String>(
                                    enabled: !_busy,
                                    tooltip: 'Trash actions',
                                    onSelected: (value) => value == 'history'
                                        ? _history(entry)
                                        : _purge(entry),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'history',
                                        child: Text('Version history'),
                                      ),
                                      PopupMenuItem(
                                        value: 'purge',
                                        child: Text('Delete permanently'),
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
    appBar: AppBar(title: Text('Preview: ${widget.entry.note.title}')),
    body: SafeArea(
      child: FutureBuilder<Object>(
        future: _document,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load the preview: ${snapshot.error}'),
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
                  'Read-only preview. The current version '
                  'and backup remain unchanged.',
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
                              const Text('[Image in backup]'),
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
                  label: const Text('Restore as a new note'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
