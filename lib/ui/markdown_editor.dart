import 'markdown_zoom_surface.dart';
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
import 'markdown_source_edit.dart';
import 'workspace_chrome.dart';
import 'document_tab.dart';
import 'library_graph_page.dart';
import 'organize_dialog.dart';
import '../data/knowledge.dart';
import 'knowledge_page.dart';
import 'wiki_link_suggestions.dart';

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
          appBar: AppBar(title: const Text('Open text note')),
          body: Center(
            child: snapshot.hasError
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Could not load text note: ${snapshot.error}'),
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
  final _wikiKey = GlobalKey<WikiLinkSuggestionsState>();
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
  bool _showSidebar = true;
  double _sourceZoom = 1;
  double _readingZoom = 1;
  double get _activeZoom => _source ? _sourceZoom : _readingZoom;
  void _setZoom(double value) => setState(() {
    if (_source) {
      _sourceZoom = value.clamp(.7, 2.5);
    } else {
      _readingZoom = value.clamp(.7, 2.5);
    }
  });
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
          setState(() => _message = 'Could not save the reading position.');
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
    _focus.onKeyEvent = (_, event) {
      if (!HardwareKeyboard.instance.isControlPressed &&
          !HardwareKeyboard.instance.isMetaPressed &&
          (_wikiKey.currentState?.handleKey(event) ?? false)) {
        return KeyEventResult.handled;
      }
      final keyboard = HardwareKeyboard.instance;
      if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
          !keyboard.isAltPressed) {
        final key = event.logicalKey;
        final zoomIn = [
          LogicalKeyboardKey.equal,
          LogicalKeyboardKey.add,
          LogicalKeyboardKey.numpadAdd,
        ].contains(key);
        final zoomOut = [
          LogicalKeyboardKey.minus,
          LogicalKeyboardKey.numpadSubtract,
        ].contains(key);
        final reset =
            key == LogicalKeyboardKey.digit0 ||
            key == LogicalKeyboardKey.numpad0;
        if (zoomIn || zoomOut || reset) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            setState(
              () => _sourceZoom = reset
                  ? 1
                  : (_sourceZoom + (zoomIn ? .1 : -.1)).clamp(.7, 2.5),
            );
          }
          return KeyEventResult.handled;
        }
      }
      if (event.logicalKey != LogicalKeyboardKey.tab ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isMetaPressed ||
          _busy ||
          _leaving) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _text.value = indentMarkdown(
          _text.value,
          outdent: HardwareKeyboard.instance.isShiftPressed,
        );
      }
      return KeyEventResult.handled;
    };
    _title = TextEditingController(text: widget.note.title);
    _source = _text.text.isEmpty || _text.text == '- [ ] First task\n';
    _previousClose = FileGateway.beforeClose;
    if (widget.tabController case final tab?) {
      tab.attach(this, save: _saveBeforeClose, anchor: _anchor);
      tab.completeTask = _applyTask;
      tab.refreshMetadata = () async {
        final notes = await widget.repository.list();
        if (!mounted) return;
        final current = notes.where((n) => n.id == _session.note.id);
        if (current.isNotEmpty) {
          _session.note = current.first;
          _changed();
          await _reload();
        }
      };
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
        setState(() => _message = 'Could not load links: $e');
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
      if (mounted) setState(() => _message = 'Action failed: $e');
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
      throw const FormatException('The note was deleted.');
    }
    note = current.single;
    final page = note.isMarkdown ? null : markdownPdfPage(anchor);
    if (!note.isMarkdown && anchor.isNotEmpty) {
      if (page == null) {
        throw const FormatException(
          'Use #page= followed by a positive page number for PDF links.',
        );
      }
      final bytes = await widget.repository.load(note.id);
      final count = await markdownPdfPageCount(bytes);
      if (page > count) {
        throw FormatException('PDF page $page does not exist ($count pages).');
      }
    }
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
            initialPage: page == null ? null : page - 1,
            initialQuery: markdownPdfQuote(anchor),
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
          throw const FormatException('Could not open the link.');
        }
      });
      return;
    }
    final note = MarkdownLibrary.target(_notes, _session.note, href);
    if (note == null) {
      setState(() => _message = 'Link target not found or unsupported: $href');
      return;
    }
    if (note.id == _session.note.id) {
      _anchor(uri.fragment);
    } else {
      await _open(note, anchor: uri.fragment);
    }
  }

  Future<void> _anchor(String anchor) async {
    if (anchor == 'edit:end') {
      setState(() => _source = true);
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
        _focus.requestFocus();
      }
      return;
    }
    final line = int.tryParse(
      anchor.startsWith('line=') ? anchor.substring(5) : '',
    );
    if (line != null && line > 0) {
      setState(() => _source = true);
      var offset = 0;
      for (var i = 1; i < line; i++) {
        final next = _text.text.indexOf('\n', offset);
        if (next < 0) break;
        offset = next + 1;
      }
      final end = _text.text.indexOf('\n', offset);
      _text.selection = TextSelection(
        baseOffset: offset,
        extentOffset: end < 0 ? _text.text.length : end,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
        _focus.requestFocus();
      }
      return;
    }
    if (_source) {
      setState(() => _source = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final found = await _previewKey.currentState?.scrollToHeading(anchor);
    if (found != true && mounted) {
      setState(() => _message = 'Heading not found: $anchor');
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

  void _codeBlock() {
    final selection = _text.selection;
    final selected = selection.isValid && !selection.isCollapsed
        ? _text.text.substring(selection.start, selection.end)
        : '';
    var length = 3;
    for (final match in RegExp(r'`+').allMatches(selected)) {
      if (match.group(0)!.length >= length) length = match.group(0)!.length + 1;
    }
    final fence = '`' * length;
    _insert('\n$fence\n', '\n$fence\n', 'Code');
  }

  Future<void> _applyTask(KnowledgeTask task) async {
    if (task.note.id != _session.note.id ||
        markdownRevision(_text.text) != task.revision ||
        !markdownOpenTasks(_text.text).any((t) => t.offset == task.offset)) {
      throw const FormatException('The task changed. Reload the list first.');
    }
    _text.text = _text.text.replaceRange(task.offset, task.offset + 1, 'x');
    if (!await _session.save()) {
      throw const FormatException('Could not save the task.');
    }
  }

  Future<void> _knowledge(String section) async {
    if (!await _saveBeforeClose() || !mounted) return;
    final destination = await Navigator.push<KnowledgeDestination>(
      context,
      MaterialPageRoute(
        builder: (_) => KnowledgePage(
          repository: widget.repository,
          initialSection: section,
          onCompleteTask: (task) async {
            if (task.note.id == _session.note.id) {
              await _applyTask(task);
            } else if (FileGateway.completeKnowledgeTask != null) {
              await FileGateway.completeKnowledgeTask!(task);
            } else {
              await KnowledgeStore(widget.repository).completeTask(task);
            }
          },
        ),
      ),
    );
    if (!mounted) return;
    await FileGateway.refreshOpenDocuments?.call();
    final notes = await widget.repository.list();
    final current = notes.where((n) => n.id == _session.note.id);
    if (current.isNotEmpty) _session.note = current.first;
    await _reload();
    if (destination != null && mounted) {
      await _open(destination.note, anchor: destination.anchor);
    }
  }

  Future<void> _outline() async {
    final headings = markdownHeadingTargets(_text.text);
    final slug = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Outline'),
        content: SizedBox(
          width: 400,
          height: 360,
          child: headings.isEmpty
              ? const Center(child: Text('No headings yet.'))
              : ListView(
                  children: [
                    for (final heading in headings)
                      ListTile(
                        contentPadding: EdgeInsets.only(
                          left: (heading.level - 1) * 12.0,
                        ),
                        title: Text(heading.title),
                        subtitle: Text('#${heading.slug}'),
                        onTap: () => Navigator.pop(context, heading.slug),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (slug != null && mounted) await _anchor(slug);
  }

  Future<void> _insertTemplate({bool saveCurrent = false}) async {
    final store = KnowledgeStore(widget.repository);
    await store.load();
    if (!mounted) return;
    if (saveCurrent) {
      store.templates.add(
        MarkdownTemplate(
          LocalNotebookRepository.newId(),
          _session.note.title,
          _text.text,
        ),
      );
      await store.save();
      if (mounted) {
        setState(
          () => _message =
              'Markdown template saved. Manage it in Knowledge hub → Templates.',
        );
      }
      return;
    }
    final template = await showDialog<MarkdownTemplate>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Insert Markdown template'),
        children: [
          for (final t in store.templates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Text(t.name),
            ),
          if (store.templates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Create templates in Knowledge hub → Templates.'),
            ),
        ],
      ),
    );
    if (template != null && mounted) {
      _insertLiteral(template.render(DateTime.now(), _session.note.title));
    }
  }

  Future<void> _graphView() async {
    final note = await Navigator.push<Notebook>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryGraphPage(
          repository: widget.repository,
          sourceOverrides: {_session.note.id: _text.text},
          focusNoteId: _session.note.id,
        ),
      ),
    );
    if (note != null && mounted) await _open(note);
  }

  Future<void> _organize() async {
    final note = await showDialog<Notebook>(
      context: context,
      builder: (_) =>
          OrganizeDialog(note: _session.note, repository: widget.repository),
    );
    if (note != null && mounted) {
      _session.organize(note);
      if (await _saveBeforeClose() && mounted) await _reload();
    }
  }

  Future<(String, String)?> _pdfPageLink(Notebook note) async {
    try {
      final bytes = await widget.repository.load(note.id);
      final count = await markdownPdfPageCount(bytes);
      if (!mounted) return null;
      final form = GlobalKey<FormState>();
      var page = '1';
      return await showDialog<(String, String)>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Link to PDF page: ${note.title}'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: page,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Page number',
                helperText: '1–$count',
              ),
              onChanged: (value) => page = value,
              validator: (value) {
                final number = int.tryParse(value ?? '');
                return number == null || number < 1 || number > count
                    ? 'Enter a page from 1 to $count.'
                    : null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  final number = int.parse(page);
                  Navigator.pop(context, (
                    '${note.title} · Page $number',
                    Uri.parse(
                      MarkdownLibrary.linkTo(_session.note, note),
                    ).replace(fragment: 'page=$number').toString(),
                  ));
                }
              },
              child: const Text('Insert page link'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not load PDF pages: $error');
      }
      return null;
    }
  }

  Future<(String, String)?> _headingLink(Notebook note) async {
    try {
      final source = note.id == _session.note.id
          ? _text.text
          : (await decodeMarkdownAsync(
              await widget.repository.load(note.id),
            )).source;
      final headings = markdownHeadingTargets(source);
      if (!mounted) return null;
      return await showDialog<(String, String)>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Link to heading: ${note.title}'),
          content: SizedBox(
            width: 400,
            height: 320,
            child: headings.isEmpty
                ? const Center(child: Text('This note has no headings yet.'))
                : ListView.builder(
                    itemCount: headings.length,
                    itemBuilder: (context, index) {
                      final heading = headings[index];
                      final base = note.id == _session.note.id
                          ? ''
                          : MarkdownLibrary.linkTo(_session.note, note);
                      final href = Uri.parse(
                        base,
                      ).replace(fragment: heading.slug).toString();
                      return ListTile(
                        title: Text(heading.title),
                        subtitle: Text('H${heading.level} · #${heading.slug}'),
                        onTap: () =>
                            Navigator.pop(context, (heading.title, href)),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not load headings: $error');
      return null;
    }
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
          title: const Text('Insert link'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: 'Find note'),
                  onChanged: (v) => update(() => query = v),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.segment),
                  title: const Text('Heading in this note'),
                  onTap: () async {
                    final result = await _headingLink(_session.note);
                    if (result != null && context.mounted) {
                      Navigator.pop(context, result);
                    }
                  },
                ),
                for (final note in _notes.where(
                  (n) => n.title.toLowerCase().contains(query.toLowerCase()),
                ))
                  ListTile(
                    dense: true,
                    title: Text(note.title),
                    subtitle: Text(
                      note.isMarkdown ? 'Text note' : 'PDF / handwriting',
                    ),
                    trailing: note.isMarkdown
                        ? IconButton(
                            tooltip: 'Link to heading in ${note.title}',
                            icon: const Icon(Icons.segment),
                            onPressed: () async {
                              final result = await _headingLink(note);
                              if (result != null && context.mounted) {
                                Navigator.pop(context, result);
                              }
                            },
                          )
                        : IconButton(
                            tooltip: 'Link to page in ${note.title}',
                            icon: const Icon(Icons.find_in_page_outlined),
                            onPressed: () async {
                              final result = await _pdfPageLink(note);
                              if (result != null && context.mounted) {
                                Navigator.pop(context, result);
                              }
                            },
                          ),
                    onTap: () => Navigator.pop(context, (
                      note.title,
                      MarkdownLibrary.linkTo(_session.note, note),
                    )),
                  ),
                const Divider(),
                TextField(
                  controller: label,
                  decoration: const InputDecoration(labelText: 'Link text'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: 'Web address (https://…)',
                  ),
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
              child: const Text('Insert web link'),
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
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg'],
          mimeTypes: ['image/png', 'image/jpeg'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > MarkdownDocument.maxAssetBytes) {
      throw const FormatException('The image is too large (32 MB).');
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
        setState(() => _message = 'Note exported as a .noter file.');
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
            ? 'Markdown exported with linked notes and images.'
            : 'Markdown exported. Use ZIP export for local images and linked notes.',
      );
    }
  });

  Future<void> _newNote() => _run(() async {
    if (!await _session.save() || !mounted) return;
    final title = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New text note'),
        content: TextField(
          controller: title,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, title.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    title.dispose();
    if (result == null || !mounted) return;
    final note = await MarkdownLibrary(
      widget.repository,
    ).create(result.isEmpty ? 'Text note' : result);
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
        ...[
          tool(
            'Zoom out (Ctrl+-)',
            Icons.text_decrease,
            () => _setZoom(_activeZoom - .1),
          ),
          Tooltip(
            message: _source
                ? 'Reset editor zoom (Ctrl+0)'
                : 'Reset reading zoom (Ctrl+0)',
            child: TextButton(
              onPressed: () => _setZoom(1),
              child: Text('${(_activeZoom * 100).round()}%'),
            ),
          ),
          tool(
            'Zoom in (Ctrl++)',
            Icons.text_increase,
            () => _setZoom(_activeZoom + .1),
          ),
          const ToolbarSeparator(),
        ],
        tool('Undo', Icons.undo, undo.value.canUndo ? undo.undo : null),
        tool('Redo', Icons.redo, undo.value.canRedo ? undo.redo : null),
        const ToolbarSeparator(),
        tool('Heading', Icons.title, () => _insert('\n## ', '\n', 'Heading')),
        tool('Bold', Icons.format_bold, () => _insert('**', '**')),
        tool('Italic', Icons.format_italic, () => _insert('*', '*')),
        const ToolbarSeparator(),
        tool(
          'Bullet list',
          Icons.format_list_bulleted,
          () => _insert('\n- ', '\n', 'List item'),
        ),
        tool(
          'Checklist',
          Icons.checklist,
          () => _insert('\n- [ ] ', '\n', 'Task'),
        ),
        tool('Quote', Icons.format_quote, () => _insert('\n> ', '\n', 'Quote')),
        tool('Insert link', Icons.link, _linkDialog),
        tool('Insert image', Icons.image_outlined, _image),
        tool('Code', Icons.code, () => _insert('`', '`')),
        tool('Code block', Icons.integration_instructions_outlined, _codeBlock),
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
        Text('Linked from', style: Theme.of(context).textTheme.titleSmall),
        if (_backlinks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'No backlinks yet.',
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
                'My notes',
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
                  hintText: 'Search notes',
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
                            note.isMarkdown ? 'Markdown' : 'PDF / handwriting',
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
                label: const Text('New text note'),
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('All notes'),
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
                  'FOLDERS',
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
                label: const Text('Back to library'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => MarkdownZoomSurface(
    enabled: !_source,
    zoom: _readingZoom,
    onChanged: _setZoom,
    child: CallbackShortcuts(
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
              padding: EdgeInsets.fromLTRB(
                phone ? 0 : 36,
                0,
                phone ? 0 : 36,
                0,
              ),
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
                                    hintText: 'Title',
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
                                        ? 'Text note'
                                        : value.trim(),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Offstage(
                                  offstage: !_source,
                                  child: WikiLinkSuggestions(
                                    key: _wikiKey,
                                    controller: _text,
                                    note: _session.note,
                                    notes: _notes,
                                    repository: widget.repository,
                                  ),
                                ),
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
                                        hintText: 'Write your note …',
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        filled: false,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        height: 1.7,
                                        fontSize: 14 * _sourceZoom,
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
                                      label: const Text('Edit text'),
                                    ),
                                  ),
                                if (!_source && _text.text.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'Your thoughts start here. Tap “Edit text”.',
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
                              zoom: _readingZoom,
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
                            sliver: SliverToBoxAdapter(
                              child: _backlinkFooter(),
                            ),
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
                      tooltip: 'Show toolbars',
                      onPressed: () => setState(() => _showChrome = true),
                      child: const Icon(Icons.fullscreen_exit),
                    ),
              appBar: !_showChrome
                  ? null
                  : AppBar(
                      toolbarHeight: NoterTheme.headerHeight(context),
                      leadingWidth: DocumentTabsChrome.leadingWidth(context),
                      leading: DocumentNavigation(
                        child: IconButton(
                          tooltip: 'Back to library',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: _leave,
                        ),
                      ),
                      title: Text(
                        _session.note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      actions: [
                        if (desktop)
                          IconButton(
                            tooltip: _showSidebar
                                ? 'Hide sidebar'
                                : 'Show sidebar',
                            icon: const Icon(Icons.view_sidebar_outlined),
                            onPressed: () =>
                                setState(() => _showSidebar = !_showSidebar),
                          ),
                        IconButton(
                          tooltip: 'Hide toolbars',
                          onPressed: () => setState(() => _showChrome = false),
                          icon: const Icon(Icons.fullscreen),
                        ),
                        IconButton(
                          tooltip: _showNotes
                              ? 'Hide note list'
                              : 'Show note list',
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
                          tooltip: 'Save',
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
                          tooltip: 'Note actions',
                          onSelected: (value) {
                            if (value == 'knowledge') {
                              _knowledge('Search');
                            } else if (value == 'journal') {
                              _knowledge('Journal');
                            } else if (value == 'tasks') {
                              _knowledge('Tasks');
                            } else if (value == 'outline') {
                              _outline();
                            } else if (value == 'template') {
                              _insertTemplate();
                            } else if (value == 'save-template') {
                              _insertTemplate(saveCurrent: true);
                            } else if (value == 'graph') {
                              _graphView();
                            } else if (value == 'organize') {
                              _organize();
                            } else {
                              _export(value);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'knowledge',
                              child: Text('Knowledge hub'),
                            ),
                            PopupMenuItem(
                              value: 'journal',
                              child: Text('Journal'),
                            ),
                            PopupMenuItem(
                              value: 'tasks',
                              child: Text('All open tasks'),
                            ),
                            PopupMenuItem(
                              value: 'outline',
                              child: Text('Outline'),
                            ),
                            PopupMenuItem(
                              value: 'template',
                              child: Text('Insert Markdown template'),
                            ),
                            PopupMenuItem(
                              value: 'save-template',
                              child: Text('Save as Markdown template'),
                            ),
                            PopupMenuItem(
                              value: 'graph',
                              child: Text('Graph view'),
                            ),
                            PopupMenuItem(
                              value: 'organize',
                              child: Text('Folders and tags'),
                            ),
                            PopupMenuItem(
                              value: 'md',
                              child: Text('Export Markdown (.md)'),
                            ),
                            PopupMenuItem(
                              value: 'bundle',
                              child: Text(
                                'With linked notes and images (.zip)',
                              ),
                            ),
                            PopupMenuItem(
                              value: 'rescue',
                              child: Text('Export Notixer backup'),
                            ),
                          ],
                        ),
                      ],
                    ),
              body: Stack(
                children: [
                  SafeArea(
                    child: Row(
                      children: [
                        if (desktop && _showChrome && _showSidebar)
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
                                                visualDensity:
                                                    VisualDensity.compact,
                                                minimumSize:
                                                    WidgetStatePropertyAll(
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
                                                    const WidgetStatePropertyAll(
                                                      16,
                                                    ),
                                              ),
                                              segments: const [
                                                ButtonSegment(
                                                  value: false,
                                                  label: Text('Formatted'),
                                                  icon: Icon(
                                                    Icons.article_outlined,
                                                  ),
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
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
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
                                          child: const Text('Retry'),
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
                  if (!_showChrome &&
                      DocumentTabsChrome.action(context) != null)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: SafeArea(
                        child: IconButton.filledTonal(
                          tooltip: 'Show document tabs',
                          onPressed: DocumentTabsChrome.action(context),
                          icon: const Icon(Icons.tab),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
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
