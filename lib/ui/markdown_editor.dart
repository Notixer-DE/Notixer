import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../data/file_gateway.dart';
import '../data/markdown_document.dart';
import '../data/markdown_library.dart';
import '../data/markdown_session.dart';
import '../data/notebook.dart';
import 'editor.dart';
import 'noter_theme.dart';
import 'markdown_preview.dart';
import 'workspace_chrome.dart';
import 'document_tab.dart';

class MarkdownEditorPage extends StatefulWidget {
  const MarkdownEditorPage({
    super.key,
    required this.note,
    required this.bytes,
    required this.repository,
    this.initialAnchor = '',
    this.tabController,
    this.onLibrary,
    this.onOpenNotebook,
  });
  final Notebook note;
  final Uint8List bytes;
  final LocalNotebookRepository repository;
  final String initialAnchor;
  final DocumentTabController? tabController;
  final Future<void> Function()? onLibrary;
  final OpenNotebookTab? onOpenNotebook;

  @override
  State<MarkdownEditorPage> createState() => _MarkdownLoaderState();
}

class _MarkdownLoaderState extends State<MarkdownEditorPage> {
  late final _document = decodeMarkdownAsync(widget.bytes);
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _document,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: const Text('Textnotiz öffnen')),
          body: Center(
            child: snapshot.hasError
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Textnotiz konnte nicht geladen werden: ${snapshot.error}',
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        );
      }
      return _LoadedMarkdownEditor(
        note: widget.note,
        document: snapshot.data!,
        repository: widget.repository,
        initialAnchor: widget.initialAnchor,
        tabController: widget.tabController,
        onLibrary: widget.onLibrary,
        onOpenNotebook: widget.onOpenNotebook,
      );
    },
  );
}

class _LoadedMarkdownEditor extends StatefulWidget {
  const _LoadedMarkdownEditor({
    required this.note,
    required this.document,
    required this.repository,
    required this.initialAnchor,
    this.tabController,
    this.onLibrary,
    this.onOpenNotebook,
  });
  final Notebook note;
  final MarkdownDocument document;
  final LocalNotebookRepository repository;
  final String initialAnchor;
  final DocumentTabController? tabController;
  final Future<void> Function()? onLibrary;
  final OpenNotebookTab? onOpenNotebook;
  @override
  State<_LoadedMarkdownEditor> createState() => _MarkdownEditorPageState();
}

class _MarkdownEditorPageState extends State<_LoadedMarkdownEditor>
    with WidgetsBindingObserver {
  late MarkdownSession _session;
  late final TextEditingController _text;
  late final TextEditingController _title;
  final _focus = FocusNode();
  var _undo = UndoHistoryController();
  var _titleUndo = UndoHistoryController();
  final _titleFocus = FocusNode();
  final _scroll = ScrollController();
  final _previewKey = GlobalKey<MarkdownPreviewState>();
  List<Notebook> _notes = [], _backlinks = [];
  String? _folder, _message;
  String _query = '';
  bool _showNotes = false, _source = false, _busy = false, _canPop = false;
  bool _showChrome = true;
  bool _leaving = false;
  bool _loadingNotes = true;
  int _loadGeneration = 0;
  bool _updating = false;
  Future<bool> Function()? _previousClose;
  late final Future<bool> Function() _closeHandler = _saveBeforeClose;
  Future<bool> _saveBeforeClose() async {
    final noteId = _session.note.id;
    final offset = _scroll.hasClients ? _scroll.offset : null;
    final saved = await _session.save();
    if (offset != null) {
      try {
        await widget.repository.catalog.readingPositions.saveMarkdown(
          noteId,
          offset,
        );
      } catch (_) {
        if (mounted) {
          setState(
            () => _message = 'Leseposition konnte nicht gespeichert werden.',
          );
        }
      }
    }
    return saved;
  }

  Future<void> _restorePosition() async {
    final id = _session.note.id;
    final positions = widget.repository.catalog.readingPositions;
    await positions.load();
    await _previewKey.currentState?.ready;
    if (!mounted || id != _session.note.id || !_scroll.hasClients) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || id != _session.note.id || !_scroll.hasClients) return;
    _scroll.jumpTo(
      positions.markdownOffset(id).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  void initState() {
    super.initState();
    _session = MarkdownSession(widget.note, widget.document, widget.repository)
      ..addListener(_changed);
    _text = TextEditingController(text: _session.document.source)
      ..addListener(_edited);
    _title = TextEditingController(text: widget.note.title);
    _source = _text.text.isEmpty || _text.text == '- [ ] Erste Aufgabe\n';
    _previousClose = FileGateway.beforeClose;
    if (widget.tabController case final tab?) {
      tab.attach(this, save: _saveBeforeClose, anchor: _anchor);
    } else {
      FileGateway.beforeClose = _closeHandler;
    }
    WidgetsBinding.instance.addObserver(this);
    _undo.addListener(_changed);
    _titleUndo.addListener(_changed);
    _titleFocus.addListener(_changed);
    _reload();
    if (widget.initialAnchor.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _anchor(widget.initialAnchor),
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
    }
  }

  void _changed() {
    if (mounted) {
      widget.tabController?.update(
        _session.note.title,
        _session.dirty || _session.saving,
      );
      setState(() {});
    }
  }

  void _edited() {
    if (!_updating && _text.text != _session.document.source) {
      _session.update(_session.document.copy(source: _text.text));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_saveBeforeClose());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async =>
      widget.tabController != null || await _saveBeforeClose()
      ? AppExitResponse.exit
      : AppExitResponse.cancel;

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    if (mounted) setState(() => _loadingNotes = true);
    try {
      final notes = await widget.repository.list();
      final backlinks = await MarkdownLibrary(
        widget.repository,
      ).backlinks(_session.note);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _notes = notes;
          _backlinks = backlinks;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Verknüpfungen konnten nicht geladen werden: $e',
        );
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadingNotes = false);
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = 'Aktion fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _leaving) return;
    setState(() => _leaving = true);
    if (!await _saveBeforeClose() || !mounted) {
      if (mounted) setState(() => _leaving = false);
      return;
    }
    if (widget.onLibrary != null) {
      await widget.onLibrary!();
      if (mounted) setState(() => _leaving = false);
      return;
    }
    setState(() => _canPop = true);
    Navigator.pop(context);
  }

  Future<void> _open(Notebook note, {String anchor = ''}) => _run(() async {
    if (!await _saveBeforeClose() || !mounted) return;
    final current = (await widget.repository.list())
        .where((n) => n.id == note.id)
        .toList();
    if (current.isEmpty) {
      throw const FormatException('Die Notiz wurde gelöscht.');
    }
    note = current.single;
    if (widget.onOpenNotebook != null) {
      await widget.onOpenNotebook!(note, anchor: anchor);
      return;
    }
    if (!note.isMarkdown) {
      final bytes = await widget.repository.load(note.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => EditorPage(
            note: note,
            bytes: bytes,
            repository: widget.repository,
          ),
        ),
      );
      // The PDF editor owns the desktop close handler while its route is open.
      FileGateway.beforeClose = _closeHandler;
      await _reload();
      return;
    }
    final document = await decodeMarkdownAsync(
      await widget.repository.load(note.id),
    );
    if (!mounted) return;
    _session.removeListener(_changed);
    _session.dispose();
    _session = MarkdownSession(note, document, widget.repository)
      ..addListener(_changed);
    final oldUndo = _undo, oldTitleUndo = _titleUndo;
    oldUndo.removeListener(_changed);
    oldTitleUndo.removeListener(_changed);
    _undo = UndoHistoryController()..addListener(_changed);
    _titleUndo = UndoHistoryController()..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldUndo.dispose();
      oldTitleUndo.dispose();
    });
    _updating = true;
    _text.text = document.source;
    _title.text = note.title;
    _updating = false;
    _source = false;
    setState(() {});
    await _reload();
    if (anchor.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _anchor(anchor));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
    }
  });

  Future<void> _follow(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      await _run(() async {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw const FormatException('Der Link konnte nicht geöffnet werden.');
        }
      });
      return;
    }
    final note = MarkdownLibrary.target(_notes, _session.note, href);
    if (note == null) {
      setState(
        () =>
            _message = 'Linkziel nicht gefunden oder nicht unterstützt: $href',
      );
      return;
    }
    if (note.id == _session.note.id) {
      _anchor(Uri.decodeComponent(uri.fragment));
    } else {
      await _open(note, anchor: Uri.decodeComponent(uri.fragment));
    }
  }

  Future<void> _anchor(String anchor) async {
    final found = await _previewKey.currentState?.scrollToHeading(anchor);
    if (found != true && mounted) {
      setState(() => _message = 'Überschrift nicht gefunden: $anchor');
    }
  }

  void _insert(
    String before, [
    String after = '',
    String placeholder = 'Text',
  ]) {
    final selection = _text.selection;
    final start = selection.isValid ? selection.start : _text.text.length;
    final end = selection.isValid ? selection.end : start;
    final selected = start == end
        ? placeholder
        : _text.text.substring(start, end);
    final replacement = '$before$selected$after';
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(start, end, replacement),
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + selected.length,
      ),
    );
    setState(() => _source = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _insertLiteral(String value) {
    final selection = _text.selection;
    final start = selection.isValid ? selection.start : _text.text.length;
    final end = selection.isValid ? selection.end : start;
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(start, end, value),
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    setState(() => _source = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _linkDialog() async {
    final url = TextEditingController();
    final label = TextEditingController();
    String query = '';
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: const Text('Link einfügen'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: 'Notiz suchen'),
                  onChanged: (v) => update(() => query = v),
                ),
                const SizedBox(height: 8),
                for (final note in _notes.where(
                  (n) => n.title.toLowerCase().contains(query.toLowerCase()),
                ))
                  ListTile(
                    dense: true,
                    title: Text(note.title),
                    subtitle: Text(
                      note.isMarkdown ? 'Textnotiz' : 'PDF / Handschrift',
                    ),
                    onTap: () => Navigator.pop(context, (
                      note.title,
                      MarkdownLibrary.linkTo(_session.note, note),
                    )),
                  ),
                const Divider(),
                TextField(
                  controller: label,
                  decoration: const InputDecoration(labelText: 'Linktext'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: 'Webadresse (https://…)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () {
                final uri = Uri.tryParse(url.text.trim());
                if (uri != null &&
                    ['https', 'http'].contains(uri.scheme) &&
                    uri.host.isNotEmpty) {
                  Navigator.pop(context, (
                    label.text.trim().isEmpty
                        ? url.text.trim()
                        : label.text.trim(),
                    uri.toString(),
                  ));
                }
              },
              child: const Text('Weblink einfügen'),
            ),
          ],
        ),
      ),
    );
    // Dialog disposal finishes after the exit animation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    url.dispose();
    label.dispose();
    if (result != null && mounted) {
      final selection = _text.selection;
      final selected = selection.isValid && !selection.isCollapsed
          ? _text.text.substring(selection.start, selection.end)
          : result.$1;
      _insertLiteral('[${markdownLabel(selected)}](<${result.$2}>)');
    }
  }

  Future<void> _image() => _run(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Bilder',
          extensions: ['png', 'jpg', 'jpeg'],
          mimeTypes: ['image/png', 'image/jpeg'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > MarkdownDocument.maxAssetBytes) {
      throw const FormatException('Bild zu groß (32 MB).');
    }
    final bytes = await file.readAsBytes();
    final (document, path) = await addMarkdownImageAsync(
      _session.document,
      bytes,
      p.extension(file.name).substring(1),
    );
    if (!mounted) return;
    _session.update(document.copy(source: _text.text));
    _insertLiteral(
      '![${markdownLabel(p.basenameWithoutExtension(file.name))}]($path)',
    );
  });

  Future<void> _export(String kind) => _run(() async {
    if (kind == 'rescue') {
      final saved = await _session.save();
      final bytes = saved
          ? await widget.repository.exportArchive(_session.note)
          : await LocalNotebookRepository.encodeAsync(
              _session.note.copy(
                folderName: widget.repository.catalog.folderName(
                  _session.note.folderId,
                ),
              ),
              await encodeMarkdownAsync(_session.document),
            );
      final path = await FileGateway().save(
        '${_session.note.id}.noter',
        bytes,
        'application/zip',
      );
      if (mounted && path) {
        setState(() => _message = 'Notiz als .noter-Datei exportiert.');
      }
      return;
    }
    if (!await _session.save()) return;
    final bytes = kind == 'bundle'
        ? await MarkdownLibrary(widget.repository).exportBundle(_session.note)
        : Uint8List.fromList(utf8.encode(_text.text));
    final saved = await FileGateway().save(
      kind == 'bundle'
          ? '${_session.note.id}-markdown.zip'
          : p.posix.basename(_session.note.documentPath),
      bytes,
      kind == 'bundle' ? 'application/zip' : 'text/markdown',
    );
    if (saved && mounted) {
      setState(
        () => _message = kind == 'bundle'
            ? 'Markdown mit verknüpften Notizen und Bildern exportiert.'
            : 'Markdown exportiert. Für lokale Bilder und verknüpfte Notizen bitte den ZIP-Export verwenden.',
      );
    }
  });

  Future<void> _newNote() => _run(() async {
    if (!await _session.save() || !mounted) return;
    final title = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Neue Textnotiz'),
        content: TextField(
          controller: title,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Titel'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, title.text.trim()),
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    title.dispose();
    if (result == null || !mounted) return;
    final note = await MarkdownLibrary(
      widget.repository,
    ).create(result.isEmpty ? 'Textnotiz' : result);
    await _reload();
    // End the current operation before opening through the guarded navigator.
    if (mounted) {
      setState(() => _busy = false);
      await _open(note);
      if (mounted) setState(() => _source = true);
    }
  });

  Widget _toolbarContents() {
    final undo = _titleFocus.hasFocus ? _titleUndo : _undo;
    Widget tool(String label, IconData icon, VoidCallback? action) =>
        IconButton(
          tooltip: label,
          onPressed: _busy || _leaving ? null : action,
          icon: Icon(icon, size: 18),
        );
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      children: [
        tool('Rückgängig', Icons.undo, undo.value.canUndo ? undo.undo : null),
        tool('Wiederholen', Icons.redo, undo.value.canRedo ? undo.redo : null),
        const ToolbarSeparator(),
        tool(
          'Überschrift',
          Icons.title,
          () => _insert('\n## ', '\n', 'Überschrift'),
        ),
        tool('Fett', Icons.format_bold, () => _insert('**', '**')),
        tool('Kursiv', Icons.format_italic, () => _insert('*', '*')),
        const ToolbarSeparator(),
        tool(
          'Aufzählung',
          Icons.format_list_bulleted,
          () => _insert('\n- ', '\n', 'Listeneintrag'),
        ),
        tool(
          'Checkliste',
          Icons.checklist,
          () => _insert('\n- [ ] ', '\n', 'Aufgabe'),
        ),
        tool('Zitat', Icons.format_quote, () => _insert('\n> ', '\n', 'Zitat')),
        tool('Link einfügen', Icons.link, _linkDialog),
        tool('Bild einfügen', Icons.image_outlined, _image),
        tool('Code', Icons.code, () => _insert('`', '`')),
      ],
    );
  }

  Widget _toolbar() => WorkspaceToolbar(child: _toolbarContents());

  Widget _backlinkFooter() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        const Divider(),
        Text('Verlinkt aus', style: Theme.of(context).textTheme.titleSmall),
        if (_backlinks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Noch keine Rückverweise.',
              style: TextStyle(color: NoterTheme.muted),
            ),
          ),
        for (final note in _backlinks)
          TextButton.icon(
            onPressed: () => _open(note),
            icon: const Icon(Icons.link, size: 16),
            label: Text(note.title),
          ),
      ],
    );
  }

  Widget _list({VoidCallback? refresh, bool closeOnTap = false}) {
    final notes = _notes.where(
      (n) =>
          (_folder == null || n.folderId == _folder) &&
          n.title.toLowerCase().contains(_query.toLowerCase()),
    );
    return WorkspaceSidebar(
      child: Material(
        color: Colors.white,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Meine Notizen',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: NoterTheme.muted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Notizen suchen',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) {
                  setState(() => _query = value);
                  refresh?.call();
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final note in notes)
                    ListTile(
                      selected: note.id == _session.note.id,
                      selectedTileColor: NoterTheme.active,
                      dense: NoterTheme.desktopControls(context),
                      leading: Icon(
                        note.isMarkdown
                            ? Icons.description_outlined
                            : Icons.picture_as_pdf_outlined,
                        size: 18,
                      ),
                      title: Text(
                        note.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: DocumentTypeBadge(
                            note.isMarkdown ? 'Markdown' : 'PDF / Handschrift',
                          ),
                        ),
                      ),
                      onTap: _busy
                          ? null
                          : () {
                              if (closeOnTap) Navigator.pop(context);
                              _open(note);
                            },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rail({VoidCallback? refresh, bool closeOnCreate = false}) =>
      WorkspaceSidebar(
        child: Material(
          color: Colors.white,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Notixer',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        if (closeOnCreate) Navigator.pop(context);
                        _newNote();
                      },
                icon: const Icon(Icons.add),
                label: const Text('Neue Textnotiz'),
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Alle Notizen'),
                leading: const Icon(Icons.grid_view_outlined),
                selected: _folder == null,
                onTap: () {
                  setState(() {
                    _folder = null;
                    _showNotes = true;
                  });
                  refresh?.call();
                },
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'ORDNER',
                  style: TextStyle(fontSize: 11, letterSpacing: 1.5),
                ),
              ),
              for (final folder in widget.repository.catalog.folders)
                ListTile(
                  title: Text(folder.name),
                  leading: const Icon(Icons.folder_outlined),
                  selected: _folder == folder.id,
                  onTap: () {
                    setState(() {
                      _folder = folder.id;
                      _showNotes = true;
                    });
                    refresh?.call();
                  },
                ),
              const Divider(),
              TextButton.icon(
                onPressed: _leave,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Zur Bibliothek'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
          _session.save(),
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
          _session.save(),
    },
    child: PopScope(
      canPop: widget.tabController != null || _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.tabController == null) _leave();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 1000;
          final phone = constraints.maxWidth < 600;
          final inset = phone ? 18.0 : 36.0;
          final paper = Padding(
            padding: EdgeInsets.fromLTRB(phone ? 0 : 36, 0, phone ? 0 : 36, 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ColoredBox(
                  color: Colors.white,
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          phone ? 24 : 68,
                          inset,
                          0,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: DocumentTypeBadge('MD'),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                key: const ValueKey('markdown-title'),
                                controller: _title,
                                undoController: _titleUndo,
                                focusNode: _titleFocus,
                                readOnly: _busy || _leaving,
                                maxLength: 120,
                                minLines: 1,
                                maxLines: null,
                                inputFormatters: [
                                  FilteringTextInputFormatter
                                      .singleLineFormatter,
                                ],
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(
                                      fontSize: 30,
                                      height: 1.3,
                                      fontWeight: FontWeight.w500,
                                    ),
                                decoration: const InputDecoration(
                                  hintText: 'Titel',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                  counterText: '',
                                ),
                                onChanged: (value) => _session.rename(
                                  value.trim().isEmpty
                                      ? 'Textnotiz'
                                      : value.trim(),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Offstage(
                                offstage: !_source,
                                child: SizedBox(
                                  height: (constraints.maxHeight - 240).clamp(
                                    300.0,
                                    900.0,
                                  ),
                                  child: TextField(
                                    key: const ValueKey('markdown-source'),
                                    controller: _text,
                                    undoController: _undo,
                                    readOnly: _busy || _leaving,
                                    focusNode: _focus,
                                    maxLines: null,
                                    expands: true,
                                    keyboardType: TextInputType.multiline,
                                    decoration: const InputDecoration(
                                      hintText: 'Schreibe deine Notiz …',
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      height: 1.7,
                                      fontSize: 14,
                                      color: NoterTheme.ink,
                                    ),
                                  ),
                                ),
                              ),
                              if (!_source)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: () {
                                      setState(() => _source = true);
                                      _focus.requestFocus();
                                    },
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 17,
                                    ),
                                    label: const Text('Text bearbeiten'),
                                  ),
                                ),
                              if (!_source && _text.text.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Deine Gedanken beginnen hier. Tippe auf „Text bearbeiten“.',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (!_source) ...[
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: inset),
                          sliver: MarkdownPreview(
                            key: _previewKey,
                            document: _session.document,
                            scrollController: _scroll,
                            onFollow: _follow,
                            onToggle: (offset, checked) {
                              if (_busy || _leaving) return;
                              _text.text = _text.text.replaceRange(
                                offset,
                                offset + 1,
                                checked ? 'x' : ' ',
                              );
                            },
                          ),
                        ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(inset, 0, inset, 48),
                          sliver: SliverToBoxAdapter(child: _backlinkFooter()),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
          return Scaffold(
            backgroundColor: phone ? Colors.white : NoterTheme.workspace,
            floatingActionButton: _showChrome
                ? null
                : FloatingActionButton.small(
                    tooltip: 'Leisten einblenden',
                    onPressed: () => setState(() => _showChrome = true),
                    child: const Icon(Icons.fullscreen_exit),
                  ),
            appBar: !_showChrome
                ? null
                : AppBar(
                    toolbarHeight: NoterTheme.headerHeight(context),
                    leading: IconButton(
                      tooltip: 'Zur Bibliothek',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _leave,
                    ),
                    title: Text(
                      _session.note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Leisten ausblenden',
                        onPressed: () => setState(() => _showChrome = false),
                        icon: const Icon(Icons.fullscreen),
                      ),
                      IconButton(
                        tooltip: _showNotes
                            ? 'Notizliste ausblenden'
                            : 'Notizliste einblenden',
                        icon: const Icon(Icons.view_sidebar_outlined),
                        onPressed: () {
                          if (desktop) {
                            setState(() => _showNotes = !_showNotes);
                          } else {
                            showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (context) => StatefulBuilder(
                                builder: (context, update) => SizedBox(
                                  height:
                                      MediaQuery.sizeOf(context).height * .7,
                                  child: Column(
                                    children: [
                                      SizedBox(
                                        height: 200,
                                        child: _rail(
                                          refresh: () => update(() {}),
                                          closeOnCreate: true,
                                        ),
                                      ),
                                      Expanded(
                                        child: _list(
                                          refresh: () => update(() {}),
                                          closeOnTap: true,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Speichern',
                        onPressed: _busy || _leaving || _session.saving
                            ? null
                            : () => _session.save(),
                        icon: Icon(
                          _session.error != null
                              ? Icons.error_outline
                              : _session.saving
                              ? Icons.sync
                              : _session.dirty
                              ? Icons.save_outlined
                              : Icons.check_circle_outline,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Markdown exportieren',
                        onSelected: _export,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'md',
                            child: Text('Markdown (.md) exportieren'),
                          ),
                          PopupMenuItem(
                            value: 'bundle',
                            child: Text(
                              'Mit verknüpften Notizen und Bildern (.zip)',
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rescue',
                            child: Text('Notixer-Sicherung exportieren'),
                          ),
                        ],
                      ),
                    ],
                  ),
            body: SafeArea(
              child: Row(
                children: [
                  if (desktop && _showChrome)
                    SizedBox(width: 196, child: _rail()),
                  if (desktop && _showChrome && _showNotes)
                    SizedBox(width: 244, child: _list()),
                  Expanded(
                    child: Column(
                      children: [
                        if (_busy || _loadingNotes)
                          const LinearProgressIndicator(),
                        if (_showChrome)
                          WorkspaceToolbar(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Row(
                                children: [
                                  if (!phone) ...[
                                    Expanded(
                                      flex: 2,
                                      child: _toolbarContents(),
                                    ),
                                    const ToolbarSeparator(),
                                  ],
                                  Expanded(
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: SegmentedButton<bool>(
                                        showSelectedIcon: false,
                                        style: ButtonStyle(
                                          visualDensity: VisualDensity.compact,
                                          minimumSize: WidgetStatePropertyAll(
                                            Size(
                                              0,
                                              NoterTheme.desktopControls(
                                                    context,
                                                  )
                                                  ? 32
                                                  : 44,
                                            ),
                                          ),
                                          iconSize:
                                              const WidgetStatePropertyAll(16),
                                        ),
                                        segments: const [
                                          ButtonSegment(
                                            value: false,
                                            label: Text('Formatiert'),
                                            icon: Icon(Icons.article_outlined),
                                          ),
                                          ButtonSegment(
                                            value: true,
                                            label: Text('Markdown'),
                                            icon: Icon(Icons.code),
                                          ),
                                        ],
                                        selected: {_source},
                                        onSelectionChanged: (value) {
                                          setState(
                                            () => _source = value.single,
                                          );
                                          if (!_source) {
                                            _focus.unfocus();
                                            _session.save();
                                            _reload();
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Tooltip(
                                    message: _session.status,
                                    child: Semantics(
                                      label: _session.status,
                                      liveRegion: true,
                                      child: Icon(
                                        _session.error != null
                                            ? Icons.error_outline
                                            : _session.saving
                                            ? Icons.sync
                                            : _session.dirty
                                            ? Icons.edit_outlined
                                            : Icons.check_circle_outline,
                                        size: 18,
                                        color: _session.error != null
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : NoterTheme.accent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_session.error != null || _message != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _session.error ?? _message!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                                if (_session.error != null)
                                  TextButton(
                                    onPressed: () => _session.save(),
                                    child: const Text('Erneut versuchen'),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(child: paper),
                        if (phone && _showChrome) _toolbar(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  @override
  void dispose() {
    widget.tabController?.detach(this);
    WidgetsBinding.instance.removeObserver(this);
    if (identical(FileGateway.beforeClose, _closeHandler)) {
      FileGateway.beforeClose = _previousClose;
    }
    _session.removeListener(_changed);
    _session.dispose();
    _text.dispose();
    _title.dispose();
    _focus.dispose();
    _undo.dispose();
    _titleUndo.dispose();
    _titleFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
