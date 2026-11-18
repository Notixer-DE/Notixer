import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse, PointerDeviceKind;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/catalog.dart';
import '../data/document_session.dart';
import '../data/file_gateway.dart';
import '../data/notebook.dart';
import '../data/markdown_document.dart';
import '../data/paper.dart';
import '../input/stylus_eraser.dart';
import 'editor_pane.dart';
import 'page_manager.dart';
import 'preset_dialog.dart';
import 'editor_toolbar.dart';
import 'template_library.dart';
import 'noter_theme.dart';
import 'document_tab.dart';
import 'workspace_chrome.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.note,
    required this.bytes,
    required this.repository,
    this.initialPage,
    this.initialQuery = '',
    this.initialTapeId,
    this.tabController,
    this.workspaceSessions,
    this.onLibrary,
    this.onReviewRated,
  });
  final Notebook note;
  final Uint8List bytes;
  final NotebookRepository repository;
  final int? initialPage;
  final String initialQuery;
  final String? initialTapeId;
  final DocumentTabController? tabController;
  final WorkspacePdfSessions? workspaceSessions;
  final Future<void> Function()? onLibrary;
  final VoidCallback? onReviewRated;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _Pane {
  _Pane(this.session);
  final DocumentSession session;
  final key = GlobalKey<EditorPaneState>();
  final region = GlobalKey();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  final Map<String, DocumentSession> _sessions = {};
  final Map<String, PenPreset> _preferredPresets = {};
  final List<_Pane> _panes = [];
  int _active = 0;
  bool _allowPop = false, _leaving = false, _busy = false;
  bool _showChrome = !Platform.isAndroid;
  final _showBarsKey = GlobalKey();
  bool? _stacked;
  double _fraction = 0.5;
  _Pane get active => _panes[_active];
  DocumentSession get session => active.session;
  Future<bool> Function()? _previousClose;
  StylusEraser? Function(PointerEvent)? _previousResolver;
  bool Function(PointerEvent)? _previousInterceptor;
  late final Future<bool> Function() _closeHandler = _saveAll;
  late final StylusEraser? Function(PointerEvent) _eraserResolver =
      _resolveEraser;
  late final bool Function(PointerEvent) _inputInterceptor;
  @override
  void initState() {
    super.initState();
    if (widget.initialTapeId != null) _showChrome = true;
    WidgetsBinding.instance.addObserver(this);
    final initial = _create(widget.note, widget.bytes);
    _panes.add(_Pane(initial));
    _previousClose = FileGateway.beforeClose;
    _previousResolver = NoterBinding.resolveEraser;
    _previousInterceptor = NoterBinding.interceptEvent;

    _inputInterceptor = (event) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
      // The reveal button lies over the canvas. Custom lasso/learning gestures
      // must let a new contact on that button reach Flutter's normal hit test.
      if (event is PointerDownEvent) {
        final box = _showBarsKey.currentContext?.findRenderObject();
        if (box is RenderBox &&
            box.hasSize &&
            (box.localToGlobal(Offset.zero) & box.size).contains(
              event.position,
            )) {
          return false;
        }
      }
      for (final pane in _panes) {
        if (pane.key.currentState?.handleCustomInput(event) == true) {
          return true;
        }
      }
      return false;
    };
    if (widget.tabController case final tab?) {
      tab.attach(
        this,
        save: _saveAll,
        eraser: _eraserResolver,
        input: _inputInterceptor,
        pause: _pauseTab,
        anchor: (anchor) async {
          final page = markdownPdfPage(anchor);
          if (page == null) {
            _message('Invalid PDF page link: $anchor');
            return;
          }
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          final index = _panes.indexWhere(
            (pane) => pane.session.note.id == widget.note.id,
          );
          if (index < 0) return;
          final pane = _panes[index];
          if (_active != index) {
            setState(() => _active = index);
            pane.key.currentState?.activateTools();
          }
          final found = await pane.key.currentState?.revealLinkedPage(page - 1);
          if (found != true && mounted) {
            _message('PDF page $page does not exist.');
          }
        },
      );
    } else {
      FileGateway.beforeClose = _closeHandler;
      NoterBinding.resolveEraser = _eraserResolver;
      NoterBinding.interceptEvent = _inputInterceptor;
    }
    widget.repository.catalog.load().catchError((Object e) {
      if (mounted) _message('$e');
    });
  }

  DocumentSession _create(Notebook note, Uint8List bytes) {
    final existing = _sessions[note.id];
    if (existing != null) return existing;
    final value =
        (widget.workspaceSessions?.acquire(note, bytes) ??
              DocumentSession(note, bytes, widget.repository))
          ..addListener(_changed);
    _sessions[note.id] = value;
    return value;
  }

  void _changed() {
    if (mounted) {
      widget.tabController?.update(
        _sessions[widget.note.id]?.note.title ?? widget.note.title,
        _sessions.values.any((s) => s.dirty || s.saving),
      );
      setState(() {});
    }
  }

  StylusEraser? _resolveEraser(PointerEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true) return null;
    if (event.kind == PointerDeviceKind.touch &&
        NoterBinding.stylusContactActive) {
      return session.eraser;
    }
    for (var i = 0; i < _panes.length; i++) {
      final box = _panes[i].region.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (Offset.zero & box.size).contains(
            box.globalToLocal(event.position),
          )) {
        if (event is PointerDownEvent && _active != i) {
          setState(() => _active = i);
          _panes[i].key.currentState?.activateTools();
        }
        return _panes[i].session.eraser;
      }
    }
    return null;
  }

  void _pauseTab() {
    for (final pane in _panes) {
      pane.key.currentState?.finishInput();
    }
    for (final session in _sessions.values) {
      NoterBinding.unregister(session.eraser);
    }
  }

  Future<bool> _saveAll() async {
    // Different documents retain independent positions. If two panes display
    // the same document, the active pane takes precedence over the other.
    for (final pane in _panes) {
      pane.key.currentState?.finishInput();
    }
    final pages = <String, int>{};
    for (final pane in [..._panes.where((p) => p != active), active]) {
      final page = pane.key.currentState?.pageForPersistence;
      if (page != null) pages[pane.session.note.id] = page;
    }
    var success = true;
    for (final s in _sessions.values.toList()) {
      if (!await s.save()) success = false;
    }
    await widget.repository.flush();
    try {
      await widget.repository.catalog.readingPositions.save(pages);
    } catch (_) {
      if (mounted) {
        _message('Could not save the last opened page.');
      }
    }
    return success;
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  Future<void> _perform(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) _message('Action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    if (await _saveAll()) {
      if (!mounted) return;
      if (widget.onLibrary != null) {
        await widget.onLibrary!();
        _leaving = false;
        return;
      }
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } else {
      _leaving = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      for (final s in _sessions.values) {
        NoterBinding.unregister(s.eraser);
      }
      _saveAll();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async =>
      widget.tabController != null || await _saveAll()
      ? AppExitResponse.exit
      : AppExitResponse.cancel;

  Future<void> _openSide() => _perform(() async {
    final notes = await widget.repository.list();
    if (!mounted) return;
    final choice = await showDialog<Notebook>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Open second view'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, session.note),
            child: const Text('Open the same note again'),
          ),
          for (final note in notes.where(
            (n) => !n.isMarkdown && n.id != session.note.id,
          ))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, note),
              child: Text(note.title),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (!await _saveAll()) return;
    final bytes = await widget.repository.load(choice.id);
    if (!mounted) return;
    final next = _create(choice, bytes);
    setState(() {
      if (_panes.length == 1) {
        _panes.add(_Pane(next));
      } else {
        _panes[1] = _Pane(next);
      }
      _active = 1;
    });
    _releaseUnused();
  });
  void _releaseUnused() {
    final unused = _sessions.keys
        .where((id) => !_panes.any((p) => p.session.note.id == id))
        .toList();
    for (final id in unused) {
      final s = _sessions.remove(id)!;
      NoterBinding.unregister(s.eraser);
      s.removeListener(_changed);
      // The replaced pane is unmounted at the end of this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseSession(s));
    }
  }

  Future<void> _closeSide() async {
    if (!await _saveAll() || !mounted) return;
    setState(() {
      _panes.removeLast();
      _active = 0;
    });
    _releaseUnused();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) active.key.currentState?.activateTools();
    });
  }

  Future<void> _export(bool archive) => _perform(() async {
    final target = session;
    bool withTapes = false;
    if (!archive) {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Export PDF'),
          content: const Text('Should study covers be visible in the PDF?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('With study covers'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Without study covers'),
            ),
          ],
        ),
      );
      if (result == null) return;
      withTapes = result;
    }
    if (!await target.save()) return;
    final bytes = archive
        ? await widget.repository.exportArchive(target.note)
        : await target.exportSnapshot(withTapes: withTapes);
    final name = target.note.title.replaceAll(
      RegExp(r'[/\\:*?"<>|\x00-\x1F]'),
      '_',
    );
    if (await FileGateway().save(
          '$name.${archive ? 'noter' : 'pdf'}',
          bytes,
          archive ? 'application/octet-stream' : 'application/pdf',
        ) &&
        mounted) {
      _message('File exported.');
    }
  });
  Future<void> _addPage() => _perform(() async {
    final s = session;
    final bytes = await createPaper(
      s.note.paper == 'pdf' ? 'blank' : s.note.paper,
      lineColor: s.note.lineColor,
    );
    s.editing.finishInk();
    s.editing.insertPagesFromBytes(bytes);
  });
  Future<void> _image() => _perform(() async {
    final pane = active;
    final bytes = await FileGateway().pickImage();
    if (bytes == null || !mounted) return;
    pane.key.currentState?.normalTool();
    final editing = pane.session.editing;
    final page = (pane.key.currentState?.viewer.currentPage ?? 0).clamp(
      0,
      editing.document.pageCount - 1,
    );
    final box = editing.document.page(page).cropBox;
    if (!await editing.placeImageAsync(
      page,
      (box.left + box.right) / 2,
      (box.bottom + box.top) / 2,
      bytes,
    )) {
      throw const FormatException(
        'Could not read the image. Please select PNG or JPEG.',
      );
    }
    editing.selectAnnotation(
      page,
      editing.document.page(page).annotations.length - 1,
    );
  });
  Future<void> _pages() async {
    final pane = active;
    await showDialog<void>(
      context: context,
      builder: (_) => PageManager(
        session: pane.session,
        currentPage: pane.key.currentState?.viewer.currentPage ?? 0,
        onPage: (page) {
          pane.key.currentState?.navigation.jumpToPage(page);
        },
        onCopyTo: (note, pages) async {
          final source = await pane.session.editing.editablePages(pages);
          final open = _sessions[note.id];
          if (open != null) {
            open.editing.insertEditablePages(source);
            if (!await open.save()) throw StateError(open.error!);
          } else {
            final target = DocumentSession(
              note,
              await widget.repository.load(note.id),
              widget.repository,
            );
            try {
              await target.ready;
              if (!target.inkReady) throw StateError(target.error!);
              target.editing.insertEditablePages(source);
              if (!await target.save()) throw StateError(target.error!);
            } finally {
              target.dispose();
            }
          }
        },
      ),
    );
  }

  Future<void> _saveTemplate({required bool singlePage}) async {
    final target = session;
    final page = active.key.currentState?.viewer.currentPage ?? 0;
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    target.editing.finishInk();
    final suggestion = singlePage
        ? '${target.note.title} – Page ${page + 1}'
        : target.note.title;
    final name = await askTemplateName(
      context,
      initial: suggestion.length > 120
          ? suggestion.substring(0, 120)
          : suggestion,
    );
    if (name == null || !mounted) return;
    await _perform(() async {
      await target.repository.templates.save(
        name,
        Uint8List.fromList(target.editing.bytes),
        ink: target.ink.snapshot(),
        page: singlePage ? page : null,
      );
      if (mounted) _message('Template saved.');
    });
  }

  Future<void> _insertTemplate() async {
    final pane = active;
    final entry = await pickTemplate(context, widget.repository.templates);
    if (entry == null || !mounted) return;
    await _perform(() async {
      final pages = await widget.repository.templates.instantiateEditable(
        entry.id,
      );
      if (!mounted) return;
      pane.session.editing.finishInk();
      final at = (pane.key.currentState?.viewer.currentPage ?? 0) + 1;
      pane.session.editing.insertEditablePages(pages, at: at);
      pane.key.currentState?.navigation.jumpToPage(at);
    });
  }

  Future<void> _preset(PenPreset preset) => _perform(() async {
    final targetPane = active;
    final targetSession = targetPane.session;
    await widget.repository.catalog.drawingPreferences.setPressureSensitive(
      preset.tool,
      preset.pressureSensitive,
    );
    if (!mounted || !_panes.contains(targetPane)) return;
    targetPane.key.currentState?.normalTool();
    targetSession.editing.finishInk();
    targetSession.eraser.setBaseTool(
      preset.tool == 'highlight' ? PdfEditTool.highlight : PdfEditTool.ink,
    );
    targetSession.preferences
      ..color = Color(preset.color)
      ..strokeWidth = preset.width
      ..opacity = preset.opacity;
  });

  Future<void> _editPreset([int? index]) async {
    final catalog = widget.repository.catalog;
    index ??= await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Edit pen preset'),
        children: [
          for (var i = 0; i < catalog.presets.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(catalog.presets[i].name),
            ),
        ],
      ),
    );
    if (index == null || !mounted) return;
    final preset = await showDialog<PenPreset>(
      context: context,
      builder: (_) => PresetDialog(preset: catalog.presets[index!]),
    );
    if (preset != null) await _perform(() => catalog.setPreset(index!, preset));
  }

  Future<void> _action(String action) async {
    switch (action) {
      case 'finger':
        session.preferences.fingerDrawsInk =
            !session.preferences.fingerDrawsInk;
      case 'singlePage':
        active.key.currentState?.toggleSinglePage();
      case 'addPage':
        await _addPage();
      case 'textSelect':
        active.key.currentState?.selectText();
      case 'image':
        await _image();
      case 'paste':
        active.key.currentState?.normalTool();
        session.editing.pasteAnnotations(
          active.key.currentState?.viewer.currentPage ?? 0,
        );
      case 'pages':
        await _pages();
      case 'pageTemplate':
        await _saveTemplate(singlePage: true);
      case 'notebookTemplate':
        await _saveTemplate(singlePage: false);
      case 'insertTemplate':
        await _insertTemplate();
      case 'search':
        active.key.currentState?.toggleSearch();
      case 'split':
        await _openSide();
      case 'orientation':
        setState(
          () =>
              _stacked = !(_stacked ?? MediaQuery.sizeOf(context).width < 700),
        );
      case 'closeSplit':
        await _closeSide();
      case 'loupe':
        active.key.currentState?.toggleLoupe();
      case 'lasso':
        active.key.currentState?.toggleLasso();
      case 'tape':
        active.key.currentState?.toggleTape();
      case 'learn':
        active.key.currentState?.toggleLearning();
      case 'reveal':
        active.key.currentState?.revealAll();
      case 'cover':
        active.key.currentState?.coverAll();
      case 'presets':
        await _editPreset();
      case 'pdf':
        await _export(false);
      case 'noter':
        await _export(true);
    }
  }

  Widget _pane(int index) {
    final pane = _panes[index];
    return Container(
      key: pane.region,
      decoration: BoxDecoration(
        border: Border.all(
          color: _panes.length > 1 && _active == index
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: EditorPane(
        key: pane.key,
        session: pane.session,
        onSaveAll: _saveAll,
        onReviewRated: widget.onReviewRated == null
            ? null
            : () {
                widget.onReviewRated!();
                _leave();
              },
        onModeChanged: _changed,
        active: _active == index,
        split: _panes.length > 1,
        showChrome: _showChrome,
        initialPage: index == 0 ? widget.initialPage : null,
        initialQuery: index == 0 ? widget.initialQuery : '',
        initialTapeId: index == 0 ? widget.initialTapeId : null,
        onActivate: () {
          if (_active != index) {
            setState(() => _active = index);
            pane.key.currentState?.activateTools();
          }
        },
      ),
    );
  }

  Widget _workspace() => LayoutBuilder(
    builder: (context, constraints) {
      if (_panes.length == 1) return _pane(0);
      final stacked =
          (_stacked ?? constraints.maxWidth < 700) &&
          constraints.maxHeight >= 488;
      final extent =
          (stacked ? constraints.maxHeight : constraints.maxWidth) - 48;
      final lower = ((stacked ? 220.0 : 160.0) / extent).clamp(.25, .5);
      final upper = 1 - lower;
      final fraction = _fraction.clamp(lower, upper);
      final divider = Semantics(
        label: 'View sizes',
        value: '${(fraction * 100).round()} percent',
        increasedValue:
            '${((_fraction + .1).clamp(lower, upper) * 100).round()} percent',
        decreasedValue:
            '${((_fraction - .1).clamp(lower, upper) * 100).round()} percent',
        slider: true,
        onIncrease: () =>
            setState(() => _fraction = (fraction + .1).clamp(lower, upper)),
        onDecrease: () =>
            setState(() => _fraction = (fraction - .1).clamp(lower, upper)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => setState(
            () => _fraction =
                (_fraction.clamp(lower, upper) +
                        (stacked ? d.delta.dy : d.delta.dx) / extent)
                    .clamp(lower, upper),
          ),
          child: SizedBox(
            width: stacked ? null : 48,
            height: stacked ? 48 : null,
            child: Center(
              child: Icon(
                stacked ? Icons.drag_handle : Icons.drag_indicator,
                size: 20,
              ),
            ),
          ),
        ),
      );
      return Flex(
        direction: stacked ? Axis.vertical : Axis.horizontal,
        children: [
          SizedBox(
            width: stacked ? null : extent * fraction,
            height: stacked ? extent * fraction : null,
            child: _pane(0),
          ),
          divider,
          Expanded(child: _pane(1)),
        ],
      );
    },
  );
  void _releaseSession(DocumentSession session) {
    final pool = widget.workspaceSessions;
    if (pool == null) {
      session.dispose();
    } else {
      pool.release(session);
    }
  }

  @override
  void dispose() {
    widget.tabController?.detach(this);
    WidgetsBinding.instance.removeObserver(this);
    if (identical(FileGateway.beforeClose, _closeHandler)) {
      FileGateway.beforeClose = _previousClose;
    }
    if (identical(NoterBinding.resolveEraser, _eraserResolver)) {
      NoterBinding.resolveEraser = _previousResolver;
    }
    if (identical(NoterBinding.interceptEvent, _inputInterceptor)) {
      NoterBinding.interceptEvent = _previousInterceptor;
    }
    for (final s in _sessions.values) {
      NoterBinding.unregister(s.eraser);
      s.removeListener(_changed);
      _releaseSession(s);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: widget.tabController != null || _allowPop,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && widget.tabController == null) _leave();
    },
    child: Scaffold(
      backgroundColor: Colors.white,
      appBar: !_showChrome
          ? null
          : AppBar(
              toolbarHeight: NoterTheme.headerHeight(context),
              leadingWidth: DocumentTabsChrome.leadingWidth(context),
              leading: DocumentNavigation(
                child: IconButton(
                  tooltip: 'Back to library',
                  onPressed: _leave,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              title: Text(session.note.title, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Hide toolbars',
                  onPressed: () => setState(() => _showChrome = false),
                  icon: const Icon(Icons.fullscreen),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Tools and export',
                  enabled: !_busy,
                  onSelected: _action,
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'finger',
                      checked: session.preferences.fingerDrawsInk,
                      child: const Text('Finger drawing'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'singlePage',
                      checked: active.key.currentState?.singlePage ?? false,
                      child: const Text('Single-page view'),
                    ),
                    const PopupMenuItem(
                      value: 'addPage',
                      child: Text('Add page'),
                    ),
                    const PopupMenuItem(
                      value: 'textSelect',
                      child: Text('Select and highlight text'),
                    ),
                    const PopupMenuItem(
                      value: 'search',
                      child: Text('Search PDF'),
                    ),
                    const PopupMenuItem(
                      value: 'image',
                      child: Text('Insert image'),
                    ),
                    if (session.editing.hasAnnotationClipboard)
                      const PopupMenuItem(
                        value: 'paste',
                        child: Text('Paste selection'),
                      ),
                    const PopupMenuItem(
                      value: 'pages',
                      child: Text('Manage pages'),
                    ),
                    const PopupMenuItem(
                      value: 'insertTemplate',
                      child: Text('Insert from template'),
                    ),
                    const PopupMenuItem(
                      value: 'pageTemplate',
                      child: Text('Save current page as template'),
                    ),
                    const PopupMenuItem(
                      value: 'notebookTemplate',
                      child: Text('Save note as template'),
                    ),
                    const PopupMenuItem(
                      value: 'lasso',
                      child: Text('Lasso selection'),
                    ),
                    const PopupMenuItem(
                      value: 'loupe',
                      child: Text('Writing magnifier'),
                    ),
                    const PopupMenuItem(
                      value: 'tape',
                      child: Text('Draw study cover'),
                    ),
                    const PopupMenuItem(
                      value: 'learn',
                      child: Text('Toggle study mode'),
                    ),
                    const PopupMenuItem(
                      value: 'reveal',
                      child: Text('Reveal all'),
                    ),
                    const PopupMenuItem(
                      value: 'cover',
                      child: Text('Hide all'),
                    ),
                    const PopupMenuItem(
                      value: 'split',
                      child: Text('Open second view'),
                    ),
                    if (_panes.length > 1) ...const [
                      PopupMenuItem(
                        value: 'orientation',
                        child: Text('Arrange views'),
                      ),
                      PopupMenuItem(
                        value: 'closeSplit',
                        child: Text('Close second view'),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'presets',
                      child: Text('Edit pen presets'),
                    ),
                    const PopupMenuItem(
                      value: 'pdf',
                      child: Text('Export as PDF'),
                    ),
                    const PopupMenuItem(
                      value: 'noter',
                      child: Text('Save as Notixer file'),
                    ),
                  ],
                ),
              ],
            ),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_showChrome)
                  EditorToolbar(
                    session: session,
                    catalog: widget.repository.catalog,
                    lassoActive: active.key.currentState?.lassoActive ?? false,
                    tapeActive: active.key.currentState?.tapeActive ?? false,
                    learningActive:
                        active.key.currentState?.learningActive ?? false,
                    preferredPreset: _preferredPresets[session.note.id],
                    onTextSelection: () =>
                        active.key.currentState?.selectText(),
                    onTool: (tool) {
                      active.key.currentState?.normalTool();
                      session.eraser.setBaseTool(tool);
                    },
                    onLasso: () => active.key.currentState?.toggleLasso(),
                    onTape: () => active.key.currentState?.toggleTape(),
                    onImage: _image,
                    onPreset: (preset) {
                      _preferredPresets[session.note.id] = preset;
                      _preset(preset);
                    },
                    onEditPreset: _editPreset,
                  ),
                Expanded(child: _workspace()),
                for (final s in _sessions.values.where((s) => s.error != null))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${s.note.title}: ${s.error}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () => s.save(),
                          child: const Text('Retry'),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              final omitInk = s.inkLoadFailed;
                              if (omitInk) {
                                final proceed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text(
                                      'Recover PDF without handwriting?',
                                    ),
                                    content: const Text(
                                      'The corrupted ink layer cannot be exported. '
                                      'The base PDF will be saved separately. '
                                      'The original note and its ink journal remain unchanged.',
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
                                        child: const Text('Export base PDF'),
                                      ),
                                    ],
                                  ),
                                );
                                if (proceed != true) return;
                              }
                              await FileGateway().save(
                                'Note-recovery.pdf',
                                await s.exportSnapshot(withoutInk: omitInk),
                                'application/pdf',
                              );
                            } catch (e) {
                              if (mounted) _message('$e');
                            }
                          },
                          child: const Text('Recover PDF'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!_showChrome && DocumentTabsChrome.action(context) != null)
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
          if (!_showChrome)
            PositionedDirectional(
              top: 8,
              end: 8,
              child: SafeArea(
                child: SizedBox(
                  key: _showBarsKey,
                  width: 48,
                  height: 48,
                  child: IconButton.filledTonal(
                    tooltip: 'Show toolbars',
                    onPressed: () => setState(() => _showChrome = true),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
