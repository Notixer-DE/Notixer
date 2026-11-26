import 'media_page.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/file_gateway.dart';
import '../data/linked_tasks.dart';
import '../data/notebook.dart';
import '../data/knowledge.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/markdown_document.dart';
import '../input/stylus_eraser.dart';
import '../live/desktop_live_broadcasts.dart';
import '../sync/sync_controller.dart';
import 'document_tab.dart';
import 'workspace_chrome.dart';
import 'editor.dart';
import 'library.dart';
import 'keyboard_settings.dart';
import 'markdown_editor.dart';
import 'todo_list_page.dart';
import 'knowledge_page.dart';
import 'study_page.dart';
import 'sync_page.dart';
import 'workspace_navigation.dart';
import 'workspace_today.dart';

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
  const DocumentWorkspace({
    super.key,
    required this.repository,
    this.initialArea = WorkspaceArea.today,
  });
  final LocalNotebookRepository repository;
  final WorkspaceArea initialArea;
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
  static const _destinations = [
    WorkspaceArea.today,
    WorkspaceArea.files,
    WorkspaceArea.tasks,
    WorkspaceArea.journal,
    WorkspaceArea.more,
  ];
  late WorkspaceArea _area = widget.initialArea;
  final _areaHistory = <WorkspaceArea>[];
  late final Set<WorkspaceArea> _visited = {WorkspaceArea.files, _area};
  int _homeRevision = 0, _request = 0;
  String? _requestedTaskView;
  bool _addJournalEntry = false, _showJournalToday = false;
  DateTime? _lastSyncedAt;
  List<String> _recent = [];
  bool _hasOpenedDocument = false;
  Future<void> _recentWrites = Future.value();
  File get _recentFile =>
      File('${widget.repository.directory.path}/.workspace-recent.json');
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

  Future<KnowledgeTask?> _changeKnowledgeTask(KnowledgeTask task) async {
    final tabs = _tabs.where((tab) => tab.note.id == task.note.id);
    final updated = tabs.firstOrNull?.controller.changeTask;
    final result =
        await (updated ?? KnowledgeStore(widget.repository).changeTask)(task);
    if (mounted && task.timerAction == null && task.workTime == null) {
      setState(() => _homeRevision++);
    }
    return result;
  }

  Future<void> _refreshOpenDocuments() async {
    for (final tab in _tabs.toList()) {
      await tab.controller.refreshMetadata?.call();
    }
  }

  Map<String, String> _openMarkdownSources() => {
    for (final tab in _tabs) tab.note.id: ?tab.controller.currentSource?.call(),
  };

  Future<void> _syncLinkedTask(
    String linkId,
    bool done, {
    String? excludeNoteId,
  }) async {
    await syncLinkedTaskStatus(
      widget.repository,
      linkId,
      done: done,
      excludeNoteId: excludeNoteId,
      updateOpenNote: (noteId, id, checked) async {
        final tab = _tabs.where((t) => t.note.id == noteId).firstOrNull;
        final handler = tab?.controller.syncLinkedTask;
        if (handler == null) return false;
        return handler(id, checked);
      },
    );
    if (mounted) {
      setState(() => _homeRevision++);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_shortcuts.load());
    unawaited(_readRecent());
    _sync.addListener(_workspaceSyncChanged);
    _library.onLegacyTasksMigrated = () {
      if (mounted) setState(() => _homeRevision++);
    };
    FileGateway.openDocument = openNotebook;
    FileGateway.changeKnowledgeTask = _changeKnowledgeTask;
    FileGateway.refreshOpenDocuments = _refreshOpenDocuments;
    FileGateway.openMarkdownSources = _openMarkdownSources;
    FileGateway.syncLinkedTask = _syncLinkedTask;
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

  Future<void> _readRecent() async {
    try {
      if (!await _recentFile.exists() || await _recentFile.length() > 65536) {
        return;
      }
      final recent = (jsonDecode(await _recentFile.readAsString()) as List)
          .whereType<String>()
          .take(12);
      if (mounted && !_hasOpenedDocument) {
        setState(() => _recent = recent.toList());
      }
    } on IOException {
      // Reading history is independent of the documents.
    } on FormatException {
      // Older or damaged state can be replaced by new activity.
    } on TypeError {
      // Ignore a history file with an unknown format.
    }
  }

  void _remember(Notebook note) {
    if (!note.isPdf && (!note.isMarkdown || note.isTodoList)) return;
    _hasOpenedDocument = true;
    final next = <String>{note.id, ..._recent}.take(12).toList();
    _recent = next;
    final file = _recentFile;
    _recentWrites = _recentWrites.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(jsonEncode(next), flush: true);
        await temporary.rename(file.path);
      } on IOException {
        // Document operations remain available when history cannot be saved.
      }
    });
  }

  void _workspaceSyncChanged() {
    if (!mounted || _lastSyncedAt == _sync.lastSyncedAt) return;
    setState(() {
      _lastSyncedAt = _sync.lastSyncedAt;
      _homeRevision++;
    });
  }

  Future<void> _openArea(
    WorkspaceArea area, {
    String? taskView,
    bool addEntry = false,
    bool showToday = false,
  }) async {
    if (_busy) return;
    if (_selected >= 0) await showLibrary();
    if (!mounted || _selected >= 0) return;
    _workspaceFocus.requestFocus();
    setState(() {
      if (area != _area) {
        if (_destinations.contains(area)) {
          _areaHistory.clear();
        } else if (_areaHistory.lastOrNull == area) {
          _areaHistory.removeLast();
        } else {
          _areaHistory.add(_area);
        }
      }
      _visited.add(area);
      _area = area;
      _requestedTaskView = taskView;
      _addJournalEntry = addEntry;
      _showJournalToday = showToday || addEntry;
      _request++;
    });
  }

  void _openSection(String section) {
    if (section == unsortedTodos) {
      unawaited(_openArea(WorkspaceArea.tasks, taskView: 'unsorted'));
      return;
    }
    unawaited(
      _openArea(
        WorkspaceArea.values.firstWhere((area) => area.label == section),
      ),
    );
  }

  void _backArea() {
    final previous = _areaHistory.isNotEmpty
        ? _areaHistory.removeLast()
        : (_area == _area.group ? WorkspaceArea.today : _area.group);
    setState(() {
      _area = previous;
      _visited.add(previous);

      _request++;
    });
    _workspaceFocus.requestFocus();
  }

  Future<void> _action(ShortcutAction? action) async {
    if (action == null) return;
    try {
      await action();
    } catch (error) {
      _message('Could not complete the action: $error');
    } finally {
      if (mounted) setState(() => _homeRevision++);
    }
  }

  Future<void> _startStudying() async {
    if (!await saveAll() || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StudyPage(
          repository: widget.repository,
          shortcuts: _shortcuts,
          startImmediately: true,
          workspaceSessions: _pdfSessions,
        ),
      ),
    );
    if (!mounted) return;
    await _refreshOpenDocuments();
    if (mounted) setState(() => _homeRevision++);
  }

  Future<void> _openSync() async {
    if (_tabs.isEmpty) {
      await _action(_library.commands[AppShortcut.syncSettings]);
      return;
    }
    await _sync.load();
    if (!mounted || !_routeCurrent) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SyncPage(
          controller: _sync,
          shortcuts: _shortcuts,
          hasOpenDocuments: true,
        ),
      ),
    );
  }

  Future<void> _saveWorkspacePreference(Future<void> Function() save) async {
    await _action(() async {
      await save();
      await _library.refresh?.call();
      await _library.syncQuickTodos?.call();
    });
  }

  Future<void> _showConflicts() async {
    await _openArea(WorkspaceArea.files);
    if (mounted && _selected < 0 && _area == WorkspaceArea.files) {
      await _action(_library.actions[LibraryWorkspaceAction.conflicts]);
    }
  }

  Widget _workspacePanel(WorkspaceArea area) {
    ListTile entry(String title, IconData icon, VoidCallback action) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right),
          onTap: action,
        );
    final catalog = widget.repository.catalog;
    final display = catalog.displayPreferences;
    final drawing = catalog.drawingPreferences;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: switch (area) {
              WorkspaceArea.more => [
                entry(
                  'Study',
                  Icons.school_outlined,
                  () => _action(_library.commands[AppShortcut.study]),
                ),
                if (Platform.isAndroid)
                  entry(
                    'Live Canvas',
                    Icons.cast,
                    () => _action(
                      _library.actions[LibraryWorkspaceAction.liveCanvas],
                    ),
                  ),
                entry(
                  'Search PDFs',
                  Icons.picture_as_pdf_outlined,
                  () => _action(
                    _library.actions[LibraryWorkspaceAction.searchPdfs],
                  ),
                ),
                entry(
                  'Templates',
                  Icons.dashboard_customize_outlined,
                  () => _openArea(WorkspaceArea.templates),
                ),
                entry(
                  'Backups and recovery',
                  Icons.backup_outlined,
                  () => _openArea(WorkspaceArea.backups),
                ),
                entry(
                  'Settings',
                  Icons.settings_outlined,
                  () => _openArea(WorkspaceArea.settings),
                ),
              ],
              WorkspaceArea.settings => [
                entry('Sync', Icons.cloud_sync_outlined, _openSync),
                entry(
                  'Keyboard shortcuts',
                  Icons.keyboard_outlined,
                  _openKeyboardSettings,
                ),
                entry(
                  'Backup settings',
                  Icons.backup_outlined,
                  () => _openArea(WorkspaceArea.backups),
                ),
                entry(
                  'Journal settings',
                  Icons.calendar_today_outlined,
                  () => _openArea(WorkspaceArea.journal),
                ),
                entry(
                  'Templates',
                  Icons.dashboard_customize_outlined,
                  () => _openArea(WorkspaceArea.templates),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Show folders in Files'),
                  subtitle: const Text('On wide screens'),
                  value: display.flag('librarySidebar', true),
                  onChanged: (value) => _saveWorkspacePreference(
                    () => display.set('librarySidebar', value),
                  ),
                ),
                SwitchListTile(
                  title: const Text('Show the Markdown sidebar'),
                  subtitle: const Text('When opening a note on a wide screen'),
                  value: display.flag('markdownSidebar', true),
                  onChanged: (value) => _saveWorkspacePreference(
                    () => display.set('markdownSidebar', value),
                  ),
                ),
                SwitchListTile(
                  title: const Text('Erase whole strokes'),
                  subtitle: const Text(
                    'Applies to drawing tools and the stylus side button',
                  ),
                  value: drawing.wholeStrokeEraser,
                  onChanged: (value) => _saveWorkspacePreference(
                    () => drawing.setWholeStrokeEraser(value),
                  ),
                ),
              ],
              _ => [],
            },
          ),
        ),
      ),
    );
  }

  Widget _knowledgeArea(WorkspaceArea area) => KnowledgePage(
    key: area == WorkspaceArea.search ? _search : ValueKey(area),
    repository: widget.repository,
    initialSection: area.label,
    embedded: true,
    active: _selected < 0 && _area == area,
    autofocusSearch: area == WorkspaceArea.search,
    request: _request,
    revision: _homeRevision,
    taskView: area == WorkspaceArea.tasks ? _requestedTaskView : null,
    addJournalEntry: area == WorkspaceArea.journal && _addJournalEntry,
    showToday: area == WorkspaceArea.journal && _showJournalToday,
    onOpenDestination: (destination) =>
        openNotebook(destination.note, anchor: destination.anchor),
    onChangeTask: (task) async {
      final updated = await _changeKnowledgeTask(task);
      if (task.deleting || task.quickTodo != null) {
        await _library.syncJournal?.call(
          task.quickTodo == null ? task.note : null,
        );
      }
      return updated;
    },
    shortcuts: _shortcuts,
    onQuickTodo: () async => await _library.addQuickTodo?.call() ?? false,
    onQuickTodosChanged: () => _action(_library.syncQuickTodos),
    onJournalChanged: (note) =>
        _action(() async => _library.syncJournal?.call(note)),
    onTaskPlanned: (note) =>
        _action(() async => _library.syncJournal?.call(note)),
    onOpenViews: () => _openArea(WorkspaceArea.views),
    onOpenGraph: () => _action(_library.commands[AppShortcut.graph]),
    onManageTemplates: () => _openArea(WorkspaceArea.templates),
    onNotebookTemplates: () =>
        _action(_library.commands[AppShortcut.templates]),
    onRecoverMedia: () =>
        _action(_library.actions[LibraryWorkspaceAction.recoverMedia]),
    onUseSavedView: (view) => _openSavedView(view),
    savedView: area == WorkspaceArea.search ? _savedView : null,
    savedViewRequest: _savedViewRequest,
    onOpenTrash: () => _action(_library.actions[LibraryWorkspaceAction.trash]),
    onOpenHistory: () =>
        _action(_library.actions[LibraryWorkspaceAction.history]),
  );

  final _search = GlobalKey<KnowledgePageState>();
  void _submitSearch() => _search.currentState?.submitSearch();

  KnowledgeView? _savedView;
  int _savedViewRequest = 0;

  void _openSavedView(KnowledgeView view) {
    _savedView = view;
    _savedViewRequest++;
    unawaited(_openArea(WorkspaceArea.search));
  }

  Widget _globalSearch() => IconButton(
    tooltip: _shortcuts.tooltip('Search', AppShortcut.knowledgeSearch),
    onPressed: () => _openArea(WorkspaceArea.search),
    icon: const Icon(Icons.search),
  );

  Widget _syncStatus() => ListenableBuilder(
    listenable: Listenable.merge([_sync, _library.conflicts]),
    builder: (context, _) {
      final conflicts = _library.conflicts.value;
      final (label, icon) = _sync.busy
          ? ('Sync in progress', Icons.sync)
          : _sync.error != null
          ? ('Sync failed', Icons.sync_problem)
          : conflicts > 0
          ? ('$conflicts sync conflicts', Icons.warning_amber_outlined)
          : !_sync.enabled
          ? ('Local library', Icons.cloud_off_outlined)
          : _sync.lastSyncedAt == null
          ? ('Sync connected', Icons.cloud_outlined)
          : ('Synchronized', Icons.cloud_done_outlined);
      return PopupMenuButton<ShortcutAction>(
        tooltip: label,
        icon: Icon(icon),
        onSelected: _action,
        itemBuilder: (_) => [
          PopupMenuItem(value: _openSync, child: const Text('Sync settings')),
          if (_sync.enabled)
            PopupMenuItem(
              enabled: _tabs.isEmpty && !_sync.busy,
              value: _library.commands[AppShortcut.syncNow],
              child: Text(
                _tabs.isEmpty ? 'Sync now' : 'Sync now · Close open tabs first',
              ),
            ),
          if (conflicts > 0)
            PopupMenuItem(
              value: _showConflicts,
              child: const Text('View conflicts'),
            ),
        ],
      );
    },
  );

  Widget _createMenu() => PopupMenuButton<ShortcutAction>(
    tooltip: 'Create',
    onSelected: _action,
    icon: const Icon(Icons.add_circle_outline),
    itemBuilder: (_) => [
      if (_library.commands[AppShortcut.newNote] case final create?)
        PopupMenuItem(value: create, child: const Text('New file')),
      if (_library.commands[AppShortcut.importFile] case final import?)
        PopupMenuItem(value: import, child: const Text('Import file')),
      if (_library.commands[AppShortcut.quickTodo] case final todo?)
        PopupMenuItem(value: todo, child: const Text('Quick to-do')),
      if (_library.actions[LibraryWorkspaceAction.capture] case final capture?)
        PopupMenuItem(value: capture, child: const Text('Capture to Inbox')),
    ],
  );

  Widget _workspaceHome(Widget files) {
    final areas = WorkspaceArea.values.where(_visited.contains).toList();
    return WorkspaceNavigation(
      destinations: _destinations,
      selected: _area,
      onSelect: _openArea,
      back: _destinations.contains(_area) ? null : _backArea,
      actions: [_globalSearch(), _syncStatus(), _createMenu()],
      child: IndexedStack(
        index: areas.indexOf(_area),
        children: [
          for (final area in areas)
            ExcludeFocus(
              key: ValueKey(area),
              excluding: _area != area || _selected >= 0,
              child: switch (area) {
                WorkspaceArea.files => files,
                WorkspaceArea.today => WorkspaceToday(
                  repository: widget.repository,
                  current: _selected < 0 && area == _area,
                  revision: _homeRevision,
                  recentIds: _recent,
                  onOpen: (note) => openNotebook(
                    note,
                    anchor: note.isMarkdown ? 'resume:reading' : null,
                  ),
                  onTasks: () =>
                      _openArea(WorkspaceArea.tasks, taskView: 'today'),
                  onStudy: _startStudying,
                  onJournal: ({required addEntry}) => _openArea(
                    WorkspaceArea.journal,
                    showToday: true,
                    addEntry: addEntry,
                  ),
                  onChangeTask: () => _action(_library.syncQuickTodos),
                ),
                WorkspaceArea.more ||
                WorkspaceArea.settings => _workspacePanel(area),
                _ => _knowledgeArea(area),
              },
            ),
        ],
      ),
    );
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
    if (index >= 0) {
      unawaited(_tabs[index].controller.refreshLinks?.call());
    }
  }

  Future<void> openNotebook(Notebook note, {String? anchor}) async {
    if (!mounted || _busy) return;
    final existing = _tabs.indexWhere((tab) => tab.note.id == note.id);
    if (existing >= 0) {
      _remember(note);
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
        _remember(note);
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
      await _recentWrites;
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

  Future<void> _openSettings() => _openArea(WorkspaceArea.settings);

  Future<void> _openKeyboardSettings() async {
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
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _selected < 0 &&
        !_destinations.contains(_area)) {
      _backArea();
      return KeyEventResult.handled;
    }
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
      AppShortcut.syncSettings => _openSync,
      AppShortcut.showLibrary => () => _openArea(WorkspaceArea.files),
      AppShortcut.knowledgeSearch => () => _openArea(WorkspaceArea.search),
      AppShortcut.knowledgeTasks => () => _openArea(WorkspaceArea.tasks),
      AppShortcut.knowledgeJournal => () => _openArea(WorkspaceArea.journal),
      AppShortcut.knowledgeSubmit
          when _area == WorkspaceArea.search && _selected < 0 =>
        _submitSearch,
      AppShortcut.knowledgeViews => () => _openArea(WorkspaceArea.views),
      AppShortcut.knowledgeBackups => () => _openArea(WorkspaceArea.backups),
      AppShortcut.knowledgeCapture =>
        _library.actions[LibraryWorkspaceAction.capture],
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
    await _openArea(WorkspaceArea.files);
    if (!_routeCurrent || _selected >= 0) return;
    await WidgetsBinding.instance.endOfFrame;
    if (_routeCurrent) {
      await _library.commands[AppShortcut.searchLibrary]?.call();
    }
  }

  Future<void> _runShortcut(AppShortcut action, ShortcutAction command) async {
    if (_busy || _shortcutRunning) return;
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

  Widget _documentTab(int index, double viewportWidth) {
    final tab = _tabs[index];
    return ListenableBuilder(
      listenable: tab.controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: (viewportWidth - 6).clamp(96, 280),
          ),
          child: Material(
            color: index == _selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: TextButton(
                    key: ValueKey('document-tab-${tab.note.id}'),
                    onPressed: _busy ? null : () => _select(index),
                    child: Text(
                      '${tab.controller.dirty ? '• ' : ''}${tab.controller.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close tab: ${tab.controller.title}',
                  onPressed: _busy ? null : () => closeNotebook(tab.note.id),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _workspaceFocus,
    autofocus: true,
    onKeyEvent: _handleShortcut,
    child: PopScope(
      canPop: _selected < 0 && _destinations.contains(_area),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selected >= 0) {
          showLibrary();
        } else if (!_destinations.contains(_area)) {
          _backArea();
        }
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
                        onPressed: _busy
                            ? null
                            : () => _openArea(WorkspaceArea.files),
                        icon: const Icon(Icons.library_books_outlined),
                      ),
                      IconButton(
                        tooltip: 'Hide document tabs',
                        onPressed: () => setState(() => _showTabs = false),
                        icon: const Icon(Icons.tab_unselected),
                      ),
                      _syncStatus(),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, bounds) => ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (var i = 0; i < _tabs.length; i++)
                                _documentTab(i, bounds.maxWidth),
                            ],
                          ),
                        ),
                      ),
                      if (_selected >= 0) ...[_globalSearch(), _createMenu()],
                    ],
                  ),
                ),
              ),
            ),
          if (Platform.isLinux || Platform.isWindows)
            DesktopLiveBroadcasts(sync: _sync),
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
                      tabsVisible: _tabs.isNotEmpty && _showTabs,
                      onShowTabs: _tabs.isNotEmpty && !_showTabs
                          ? () => setState(() => _showTabs = true)
                          : null,
                      child: IndexedStack(
                        index: _selected + 1,
                        children: [
                          ExcludeFocus(
                            excluding: _selected >= 0,
                            child: _workspaceHome(
                              LibraryPage(
                                key: const ValueKey('workspace-library'),
                                onWorkspaceSection: _openSection,
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
                                onChangeTask: _changeKnowledgeTask,
                                onRefreshDocuments: _refreshOpenDocuments,
                                beforeStudy: saveAll,
                                workspaceSessions: _pdfSessions,
                              ),
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
                                          onJournalChanged: (note) async =>
                                              _library.syncJournal?.call(note),
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
    FileGateway.changeKnowledgeTask = null;
    FileGateway.refreshOpenDocuments = null;
    FileGateway.openMarkdownSources = null;
    FileGateway.syncLinkedTask = null;
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
    _sync.removeListener(_workspaceSyncChanged);
    _library.onLegacyTasksMigrated = null;
    _library.conflicts.dispose();
    _sync.dispose();
    _workspaceFocus.dispose();
    _shortcuts.dispose();
    super.dispose();
  }
}
