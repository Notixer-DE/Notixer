import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import '../data/templates.dart';
import 'pdf_thumbnail.dart';

Future<NoteTemplate?> pickTemplate(
  BuildContext context,
  TemplateRepository repository,
) => Navigator.of(context).push<NoteTemplate>(
  MaterialPageRoute(
    builder: (_) => TemplateLibrary(repository: repository, picking: true),
  ),
);

Future<String?> askTemplateName(
  BuildContext context, {
  String initial = 'Eigene Vorlage',
  bool rename = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TemplateNameDialog(initial: initial, rename: rename),
);

class TemplateLibrary extends StatefulWidget {
  const TemplateLibrary({
    super.key,
    required this.repository,
    this.picking = false,
  });
  final TemplateRepository repository;
  final bool picking;
  @override
  State<TemplateLibrary> createState() => _TemplateLibraryState();
}

class _TemplateLibraryState extends State<TemplateLibrary> {
  List<NoteTemplate> _entries = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _run(_refresh);
  }

  Future<void> _refresh() async {
    final entries = await widget.repository.list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _error = widget.repository.readErrors.isEmpty
          ? null
          : 'Einige Vorlagen konnten nicht gelesen werden: ${widget.repository.readErrors.join(', ')}';
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = 'Vorlagenaktion fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(NoteTemplate entry) async {
    Uint8List? bytes;
    await _run(() async {
      bytes = await widget.repository.preview(entry.id);
    });
    if (!mounted || bytes == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => TemplatePreview(name: entry.name, bytes: bytes!),
    );
  }

  Future<void> _rename(NoteTemplate entry) async {
    final name = await askTemplateName(
      context,
      initial: entry.name,
      rename: true,
    );
    if (name == null || !mounted) return;
    await _run(() async {
      await widget.repository.rename(entry.id, name);
      await _refresh();
    });
  }

  Future<void> _delete(NoteTemplate entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Vorlage löschen?'),
        content: Text(
          '„${entry.name}“ wird gelöscht. Bereits erstellte Notizen bleiben unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await widget.repository.delete(entry.id);
      await _refresh();
    });
  }

  Widget _entry(NoteTemplate entry) => Card(
    key: ValueKey(entry.id),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!entry.builtIn)
                PopupMenuButton<String>(
                  tooltip: 'Vorlagenaktionen',
                  enabled: !_busy,
                  onSelected: (value) =>
                      value == 'rename' ? _rename(entry) : _delete(entry),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
                    PopupMenuItem(value: 'delete', child: Text('Löschen')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${entry.kind == TemplateKind.page ? 'Seitenvorlage' : 'Notizvorlage'} · '
            '${entry.pageCount} ${entry.pageCount == 1 ? 'Seite' : 'Seiten'}'
            '${entry.builtIn ? ' · Startvorlage' : ''}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _preview(entry),
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Vorschau'),
              ),
              if (widget.picking)
                FilledButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, entry),
                  child: const Text('Verwenden'),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.picking ? 'Vorlage auswählen' : 'Vorlagen'),
        automaticallyImplyLeading: !_busy,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Offline auf diesem Gerät. Jede Verwendung erzeugt eine unabhängige Kopie '
                      'ohne Ordner, Tags oder Lernfortschritt.',
                    ),
                    if (!_busy && _entries.every((entry) => entry.builtIn))
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'Eigene Vorlagen speicherst du im Editor über '
                          '„Aktuelle Seite als Vorlage speichern“ oder „Notiz als Vorlage speichern“.',
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_error!),
                        ),
                      ),
                    const SizedBox(height: 12),
                    for (final entry in _entries) _entry(entry),
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

class TemplatePreview extends StatefulWidget {
  const TemplatePreview({super.key, required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
  @override
  State<TemplatePreview> createState() => _TemplatePreviewState();
}

class _TemplatePreviewState extends State<TemplatePreview> {
  late final _document = PdfDocument.open(widget.bytes);
  int _page = 0;
  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 720,
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Vorschau schließen',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final page = _document.page(_page);
                  final sideways = page.rotation % 180 != 0;
                  final width = sideways
                      ? page.cropBox.height
                      : page.cropBox.width;
                  final height = sideways
                      ? page.cropBox.width
                      : page.cropBox.height;
                  final scale = math.min(
                    constraints.maxWidth / width,
                    constraints.maxHeight / height,
                  );
                  return Center(
                    child: SizedBox(
                      width: width * scale,
                      height: height * scale,
                      child: PdfThumbnail(page: page),
                    ),
                  );
                },
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Vorherige Vorlagenseite',
                onPressed: _page == 0 ? null : () => setState(() => _page--),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  'Seite ${_page + 1} von ${_document.pageCount}',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Nächste Vorlagenseite',
                onPressed: _page + 1 == _document.pageCount
                    ? null
                    : () => setState(() => _page++),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _TemplateNameDialog extends StatefulWidget {
  const _TemplateNameDialog({required this.initial, required this.rename});
  final String initial;
  final bool rename;
  @override
  State<_TemplateNameDialog> createState() => _TemplateNameDialogState();
}

class _TemplateNameDialogState extends State<_TemplateNameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  String? get _error {
    try {
      templateName(_name.text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.rename ? 'Vorlage umbenennen' : 'Vorlage speichern'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 120,
      decoration: InputDecoration(labelText: 'Vorlagenname', errorText: _error),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_error == null) Navigator.pop(context, templateName(_name.text));
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: _error != null
            ? null
            : () => Navigator.pop(context, templateName(_name.text)),
        child: const Text('Speichern'),
      ),
    ],
  );
}
