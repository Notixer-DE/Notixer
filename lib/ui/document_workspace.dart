import 'media_page.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/file_gateway.dart';
import '../data/notebook.dart';
import '../data/knowledge.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/markdown_document.dart';
import '../input/stylus_eraser.dart';
import '../sync/sync_controller.dart';
import 'document_tab.dart';
import 'workspace_chrome.dart';
import 'editor.dart';
import 'library.dart';
import 'keyboard_settings.dart';
import 'markdown_editor.dart';
import 'todo_list_page.dart';

class _OpenDocument {
  _OpenDocument(this.note, this.bytes, this.anchor, KeyboardShortcuts shortcuts)
    : controller = DocumentTabController(note.title, shortcuts: shortcuts);
  final Notebook note;
  final Uint8List bytes;
  final String? anchor;
  int? get initialPdfPage {
    final page = markdownPdfPage(anchor ?? '');
    return page == null ? null : page - 1;
  }

  final DocumentTabController controller;
}

/// Tabs own mounted editor instances, including undo, zoom and unsaved changes.
class DocumentWorkspace extends StatefulWidget {
  const DocumentWorkspace({super.key, required this.repository});
  final LocalNotebookRepository repository;
  @override
  State<DocumentWorkspace> createState() => DocumentWorkspaceState();
}

class DocumentWorkspaceState extends State<DocumentWorkspace>
    with WidgetsBindingObserver {
  final _tabs = <_OpenDocument>[];
  final _library = LibraryWorkspaceController();
  final _workspaceFocus = FocusNode(debugLabel: 'Document workspace');
  late final _shortcuts = KeyboardShortcuts(
    File('${widget.repository.directory.path}/.keyboard-shortcuts.json'),
  );
  late final _sync = SyncController(widget.repository);
  late final _pdfSessions = WorkspacePdfSessions(widget.repository);
  int _selected = -1;
  bool _busy = false, _showTabs = true;
  bool _shortcutRunning = false;
  Future<bool> Function()? _previousClose, _previousWorkspaceClose;
  StylusEraser? Function(PointerEvent)? _previousResolver;
  bool Function(PointerEvent)? _previousInterceptor;
  late final Future<bool> Function() _closeHandler = saveAll;
  late final StylusEraser? Function(PointerEvent) _resolver = _resolve;
  late final bool Function(PointerEvent) _interceptor = _intercept;
  List<String> get openNotebookIds =>
      List.unmodifiable(_tabs.map((tab) => tab.note.id));
  String? get activeNotebookId =>
      _selected < 0 ? null : _tabs[_selected].note.id;

  Future<void> _completeKnowledgeTask(KnowledgeTask task) async {
    final tabs = _tabs.where((tab) => tab.note.id == task.note.id);
    if (tabs.isNotEmpty && tabs.first.controller.completeTask != null) {
      await tabs.first.controller.completeTask!(task);
    } else {
      await KnowledgeStore(widget.repository).completeTask(task);
    }
  }

  Future<void> _refreshOpenDocuments() async {
    for (final tab in _tabs.toList()) {
      await tab.controller.refreshMetadata?.call();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_shortcuts.load());
    FileGateway.openDocument = openNotebook;
    FileGateway.completeKnowledgeTask = _completeKnowledgeTask;
    FileGateway.refreshOpenDocuments = _refreshOpenDocuments;
    WidgetsBinding.instance.addObserver(this);
    _previousClose = FileGateway.beforeClose;
    _previousWorkspaceClose = FileGateway.workspaceBeforeClose;
    _previousResolver = NoterBinding.resolveEraser;
    _previousInterceptor = NoterBinding.interceptEvent;
    FileGateway.beforeClose = _closeHandler;
    FileGateway.workspaceBeforeClose = _closeHandler;
    NoterBinding.resolveEraser = _resolver;
    NoterBinding.interceptEvent = _interceptor;
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  StylusEraser? _resolve(PointerEvent event) =>
      _routeCurrent && _selected >= 0 && !_busy
      ? _tabs[_selected].controller.resolveEraser?.call(event)
      : null;
  bool _intercept(PointerEvent event) =>
      _routeCurrent &&
      _selected >= 0 &&
      (_busy ||
          _tabs[_selected].controller.interceptEvent?.call(event) == true);

  void _select(int index) {
    if (_busy || _selected == index) return;
    if (_selected >= 0) _tabs[_selected].controller.deactivate();
    _workspaceFocus.requestFocus();
    setState(() => _selected = index);
  }

  Future<void> openNotebook(Notebook note, {String? anchor}) async {
    if (!mounted || _busy) return;
    final existing = _tabs.indexWhere((tab) => tab.note.id == note.id);
    if (existing >= 0) {
      _select(existing);
      if (anchor != null && (anchor.isNotEmpty || note.isMarkdown)) {
        await _tabs[existing].controller.revealAnchor?.call(anchor);
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await widget.repository.load(note.id);
      if (!mounted) return;
      if (_selected >= 0) _tabs[_selected].controller.deactivate();
      _workspaceFocus.requestFocus();
      setState(() {
        _tabs.add(_OpenDocument(note, bytes, anchor, _shortcuts));
        _selected = _tabs.length - 1;
      });
    } catch (error) {
      _message('Could not open the note: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> saveAll() async {
    try {
      for (final tab in _tabs.toList()) {
        if (!await tab.controller.save()) return false;
      }
      await widget.repository.flush();
      return true;
    } catch (error) {
      _message('Could not save changes: $error');
      return false;
    }
  }

  Future<void> showLibrary() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await saveAll() || !mounted) return;
      if (_selected >= 0) _tabs[_selected].controller.deactivate();
      _workspaceFocus.requestFocus();
      setState(() => _selected = -1);
      await _library.refresh?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> closeNotebook(String id) async {
    final index = _tabs.indexWhere((tab) => tab.note.id == id);
    if (_busy || index < 0) return false;
    setState(() => _busy = true);
    final tab = _tabs[index];
    try {
      if (!await tab.controller.save() || !mounted) return false;
      await widget.repository.flush();
      tab.controller.deactivate();
      if (_sync.enabled && _sync.automatic && !_sync.busy) {
        await _sync.synchronize(noteId: id, onlyIfChanged: true);
      }
      if (!mounted) return false;
      setState(() {
        _tabs.removeAt(index);
        if (_selected == index) {
          _selected = _tabs.isEmpty ? -1 : index.clamp(0, _tabs.length - 1);
        } else if (_selected > index) {
          _selected--;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => tab.controller.dispose(),
      );
      await _library.refresh?.call();
      return true;
    } catch (error) {
      _message('Could not close the tab: $error');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async =>
      await saveAll() ? AppExitResponse.exit : AppExitResponse.cancel;

  Future<void> _openSettings() async {
    await _shortcuts.load();
    if (!mounted || !_routeCurrent) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => KeyboardSettingsPage(shortcuts: _shortcuts),
      ),
    );
    if (mounted) setState(() {});
  }

  KeyEventResult _handleShortcut(FocusNode node, KeyEvent event) {
    if (!_routeCurrent) return KeyEventResult.ignored;
    final action = _shortcuts.match(event);
    if (action == null) return KeyEventResult.ignored;
    final command = _commandFor(action);
    if (command == null) return KeyEventResult.ignored;
    unawaited(_runShortcut(action, command));
    return KeyEventResult.handled;
  }

  ShortcutAction? _commandFor(AppShortcut action) {
    final tab = _selected < 0 ? null : _tabs[_selected];
    return switch (action) {
      AppShortcut.settings => _openSettings,
      AppShortcut.showLibrary => showLibrary,
      AppShortcut.nextTab => _tabs.isEmpty ? null : () => _moveTab(1),
      AppShortcut.previousTab => _tabs.isEmpty ? null : () => _moveTab(-1),
      AppShortcut.closeTab =>
        tab == null
            ? null
            : () async {
                await closeNotebook(tab.note.id);
              },
      AppShortcut.toggleTabs => () => setState(() => _showTabs = !_showTabs),
      AppShortcut.save => () async {
        await saveAll();
      },
      AppShortcut.searchLibrary => _focusLibrarySearch,
      _ =>
        _library.commands[action] ?? tab?.controller.commandFor?.call(action),
    };
  }

  void _moveTab(int direction) {
    final index = _selected < 0
        ? (direction > 0 ? 0 : _tabs.length - 1)
        : (_selected + direction) % _tabs.length;
    _select(index);
  }

  Future<void> _focusLibrarySearch() async {
    if (_selected >= 0) await showLibrary();
    if (!_routeCurrent || _selected >= 0) return;
    await WidgetsBinding.instance.endOfFrame;
    if (_routeCurrent) {
      await _library.commands[AppShortcut.searchLibrary]?.call();
    }
  }

  Future<void> _runShortcut(AppShortcut action, ShortcutAction command) async {
    if (_busy || _shortcutRunning || _sync.busy) return;
    _shortcutRunning = true;
    try {
      if ((action == AppShortcut.importFile || action == AppShortcut.newNote) &&
          !await saveAll()) {
        return;
      }
      if (_routeCurrent) await command();
    } catch (error) {
      _message('Could not run ${action.label.toLowerCase()}: $error');
    } finally {
      _shortcutRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _workspaceFocus,
    autofocus: true,
    onKeyEvent: _handleShortcut,
    child: PopScope(
      canPop: _selected < 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selected >= 0) showLibrary();
      },
      child: Column(
        children: [
          if (_tabs.isNotEmpty && _showTabs)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  key: const ValueKey('document-tabs-bar'),
                  height: 44,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Open library and another note',
                        onPressed: _busy ? null : showLibrary,
                        icon: const Icon(Icons.library_books_outlined),
                      ),
                      IconButton(
                        tooltip: 'Hide document tabs',
                        onPressed: () => setState(() => _showTabs = false),
                        icon: const Icon(Icons.tab_unselected),
                      ),
                      Expanded(
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (var i = 0; i < _tabs.length; i++)
                              ListenableBuilder(
                                listenable: _tabs[i].controller,
                                builder: (context, _) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                    vertical: 2,
                                  ),
                                  child: Material(
                                    color: i == _selected
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.secondaryContainer
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextButton(
                                          key: ValueKey(
                                            'document-tab-${_tabs[i].note.id}',
                                          ),
                                          onPressed: _busy
                                              ? null
                                              : () => _select(i),
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 200,
                                            ),
                                            child: Text(
                                              '${_tabs[i].controller.dirty ? '• ' : ''}${_tabs[i].controller.title}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip:
                                              'Close tab: ${_tabs[i].controller.title}',
                                          onPressed: _busy
                                              ? null
                                              : () => closeNotebook(
                                                  _tabs[i].note.id,
                                                ),
                                          icon: const Icon(
                                            Icons.close,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  ignoring: _busy,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: _tabs.isNotEmpty && _showTabs,
                    child: DocumentTabsChrome(
                      onShowTabs: _tabs.isNotEmpty && !_showTabs
                          ? () => setState(() => _showTabs = true)
                          : null,
                      child: IndexedStack(
                        index: _selected + 1,
                        children: [
                          ExcludeFocus(
                            excluding: _selected >= 0,
                            child: LibraryPage(
                              key: const ValueKey('workspace-library'),
                              repository: widget.repository,
                              syncController: _sync,
                              workspaceController: _library,
                              onSettings: _openSettings,
                              shortcuts: _shortcuts,
                              hasOpenDocuments: () => _tabs.isNotEmpty,
                              isNotebookOpen: (id) =>
                                  _pdfSessions.contains(id) ||
                                  _tabs.any((tab) => tab.note.id == id),
                              onOpenNotebook: (note) => openNotebook(note),
                              onOpenDestination: openNotebook,
                              onCompleteTask: _completeKnowledgeTask,
                              onRefreshDocuments: _refreshOpenDocuments,
                            ),
                          ),
                          for (var i = 0; i < _tabs.length; i++)
                            KeyedSubtree(
                              key: ValueKey(
                                'document-body-${_tabs[i].note.id}',
                              ),
                              child: TickerMode(
                                enabled: _selected == i,
                                child: FocusScope(
                                  canRequestFocus: _selected == i,
                                  child: _tabs[i].note.isMedia
                                      ? MediaPage(
                                          name: _tabs[i].note.title,
                                          bytes: _tabs[i].bytes,
                                          format: _tabs[i].note.mediaFormat!,
                                          note: _tabs[i].note,
                                          repository: widget.repository,
                                          tabController: _tabs[i].controller,
                                          onLibrary: showLibrary,
                                        )
                                      : _tabs[i].note.isTodoList
                                      ? TodoListPage(
                                          note: _tabs[i].note,
                                          bytes: _tabs[i].bytes,
                                          repository: widget.repository,
                                          initialAnchor: _tabs[i].anchor ?? '',
                                          tabController: _tabs[i].controller,
                                          onLibrary: showLibrary,
                                        )
                                      : _tabs[i].note.isMarkdown
                                      ? MarkdownEditorPage(
                                          note: _tabs[i].note,
                                          bytes: _tabs[i].bytes,
                                          repository: widget.repository,
                                          initialAnchor: _tabs[i].anchor,
                                          tabController: _tabs[i].controller,
                                          onLibrary: showLibrary,
                                          onOpenNotebook: openNotebook,
                                          onQuickTodosChanged: () async =>
                                              _library.syncQuickTodos?.call(),
                                        )
                                      : EditorPage(
                                          note: _tabs[i].note,
                                          bytes: _tabs[i].bytes,
                                          repository: widget.repository,
                                          tabController: _tabs[i].controller,
                                          initialPage: _tabs[i].initialPdfPage,
                                          initialQuery: markdownPdfQuote(
                                            _tabs[i].anchor ?? '',
                                          ),
                                          workspaceSessions: _pdfSessions,
                                          onLibrary: showLibrary,
                                        ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FileGateway.openDocument = null;
    FileGateway.completeKnowledgeTask = null;
    FileGateway.refreshOpenDocuments = null;
    if (identical(FileGateway.beforeClose, _closeHandler)) {
      FileGateway.beforeClose = _previousClose;
    }
    if (identical(FileGateway.workspaceBeforeClose, _closeHandler)) {
      FileGateway.workspaceBeforeClose = _previousWorkspaceClose;
    }
    if (identical(NoterBinding.resolveEraser, _resolver)) {
      NoterBinding.resolveEraser = _previousResolver;
    }
    if (identical(NoterBinding.interceptEvent, _interceptor)) {
      NoterBinding.interceptEvent = _previousInterceptor;
    }
    for (final tab in _tabs) {
      tab.controller.dispose();
    }
    _pdfSessions.dispose();
    _sync.dispose();
    _workspaceFocus.dispose();
    _shortcuts.dispose();
    super.dispose();
  }
}
