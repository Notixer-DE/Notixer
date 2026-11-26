import 'dart:async';
import '../data/media_gateway.dart';
import 'notebook_cover.dart';
import 'media_acquisition.dart';
import 'media_page.dart';
import '../data/media.dart';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../data/notebook.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/file_gateway.dart';
import '../data/paper.dart';
import '../data/templates.dart';
import 'editor.dart';
import 'organize_dialog.dart';
import 'sync_page.dart';
import '../sync/sync_controller.dart';
import 'recovery_page.dart';
import 'pdf_search_page.dart';
import 'notebook_preview.dart';
import 'noter_theme.dart';
import 'library_navigation.dart';
import 'study_page.dart';
import '../data/markdown_library.dart';
import '../data/todo_list.dart';
import 'markdown_editor.dart';
import 'todo_list_page.dart';
import 'template_library.dart';
import 'workspace_chrome.dart';
import 'sync_button.dart';
import 'document_tab.dart';
import 'library_graph_page.dart';
import 'knowledge_page.dart';
import 'quick_todo_dialog.dart';
import 'inbox_capture_dialog.dart';
import '../live/live_host_page.dart';
import '../data/knowledge.dart';
import '../data/markdown_document.dart';
import '../editor/operations.dart' show exportPdfBytesAsync;
import '../sync/library_extras_sync.dart';
import '../sync/notebook_sync.dart' show SettingsConflictNote;

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.repository,
    this.syncController,
    this.onOpenNotebook,
    this.workspaceController,
    this.onSettings,
    this.shortcuts,
    this.isNotebookOpen,
    this.hasOpenDocuments,
    this.onOpenDestination,
    this.onChangeTask,
    this.onRefreshDocuments,
    this.onWorkspaceSection,
    this.beforeStudy,
    this.workspaceSessions,
  });
  final void Function(String)? onWorkspaceSection;
  final Future<bool> Function()? beforeStudy;
  final WorkspacePdfSessions? workspaceSessions;
  final OpenNotebookTab? onOpenDestination;
  final Future<KnowledgeTask?> Function(KnowledgeTask)? onChangeTask;
  final Future<void> Function()? onRefreshDocuments;
  final LocalNotebookRepository repository;
  final SyncController? syncController;
  final Future<void> Function(Notebook)? onOpenNotebook;
  final LibraryWorkspaceController? workspaceController;
  final Future<void> Function()? onSettings;
  final KeyboardShortcuts? shortcuts;
  final bool Function(String id)? isNotebookOpen;
  final bool Function()? hasOpenDocuments;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final SyncController _sync =
      widget.syncController ?? SyncController(widget.repository);
  late final _previews = NotebookPreviewCache(widget.repository);
  List<Notebook> _notes = [];
  String _query = '';
  String? _folderFilter, _tagFilter;
  String _kind = 'all';
  bool _grid = false;
  bool _showNavigation = true;
  String? _previewId;
  bool _canPreview = false;
  ImportedMedia? _pendingMedia;
  List<String> _recoverableCaptures = [];
  final _scaffold = GlobalKey<ScaffoldState>();
  final _searchFocus = FocusNode();
  final _searchText = TextEditingController();
  final _selectedNotes = <String>{};
  bool _selecting = false;
  String? _error;
  bool _loading = true, _actionBusy = false;
  bool get _busy => _actionBusy || _sync.busy;
  bool get _hasOpenDocuments => widget.hasOpenDocuments?.call() ?? false;
  bool _isOpen(Notebook note) => widget.isNotebookOpen?.call(note.id) ?? false;
  @override
  void initState() {
    super.initState();
    if (widget.workspaceController case final workspace?) {
      workspace.refresh = _refresh;
      workspace.syncQuickTodos = _syncQuickTodos;
      workspace.syncJournal = _syncChangedNote;
      workspace.addQuickTodo = _quickTodo;
      workspace.actions = {
        LibraryWorkspaceAction.capture: _captureInbox,
        if (Platform.isAndroid) LibraryWorkspaceAction.liveCanvas: _liveCanvas,
        LibraryWorkspaceAction.conflicts: _showConflicts,
        LibraryWorkspaceAction.recoverMedia: _recoverCapture,
      };
      workspace.commands = {
        AppShortcut.knowledgeSearch: () => _knowledge(autofocusSearch: true),
        AppShortcut.importFile: _import,
        AppShortcut.newNote: _create,
        AppShortcut.quickTodo: _quickTodo,
        AppShortcut.searchLibrary: _focusSearch,
        AppShortcut.graph: _graphView,
        AppShortcut.study: _study,
        AppShortcut.templates: _templates,
        AppShortcut.syncSettings: _syncSettings,
        AppShortcut.syncNow: _syncNow,
        AppShortcut.knowledgeTasks: () => _knowledge(section: 'Tasks'),
        AppShortcut.knowledgeJournal: () => _knowledge(section: 'Journal'),
        AppShortcut.knowledgeCapture: () =>
            _knowledge(section: 'Inbox', sharedText: ''),
        AppShortcut.knowledgeViews: () => _knowledge(section: 'Views'),
        AppShortcut.knowledgeBackups: () => _knowledge(section: 'Backups'),
      };
    }
    _sync.addListener(_syncChanged);
    MediaGateway.recoveredCapture.addListener(_captureRecovered);
    FileGateway.sharedText.addListener(_sharedCapture);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sharedCapture());
    _initializeSync();
  }

  void _captureRecovered() {
    if (mounted) _refresh();
  }

  void _syncChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initializeSync() async {
    await _refresh();
    if (!mounted) return;
    await _perform(() async {
      await _sync.load();
      if (_sync.enabled && _sync.automatic) {
        await _sync.synchronize();
        await _refresh();
      }
    });
  }

  Future<void> _autoSync(Map<String, String> before) async {
    if (_sync.enabled && _sync.automatic) {
      final after = await _noteStates();
      for (final id in {...before.keys, ...after.keys}) {
        if (before[id] != after[id] &&
            !(widget.isNotebookOpen?.call(id) ?? false)) {
          await _sync.synchronize(noteId: id, onlyIfChanged: true);
          // Preserve the first failure rather than clearing it on the next ID.
          if (_sync.error != null) break;
        }
      }
      if (_sync.error == null) await _sync.synchronizePreferences();
      await _refresh();
    }
  }

  // Metadata includes the persisted save timestamp, so autosaves and edits in
  // secondary panes are included without reading/hashing every document.
  Future<Map<String, String>> _noteStates() async {
    await widget.repository.catalog.load();
    return {
      for (final note in await widget.repository.list())
        note.id: jsonEncode(
          note
              .copy(
                folderName: widget.repository.catalog.folderName(note.folderId),
                clearFolder: note.folderId == null,
              )
              .toJson(),
        ),
    };
  }

  Future<void> _quickTodoSync = Future.value();

  Future<void> _syncQuickTodos() {
    final pending = _quickTodoSync.then((_) => _syncChangedNote(null));
    _quickTodoSync = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<void> _syncChangedNote(Notebook? note) async {
    if (!mounted || _busy || !_sync.enabled || !_sync.automatic) return;
    if (note == null) {
      await _sync.synchronizePreferences();
    } else if (!_isOpen(note)) {
      await _sync.synchronize(noteId: note.id, onlyIfChanged: true);
    }
  }

  Future<void> _syncSettings() async {
    if (_hasOpenDocuments) return;
    await _perform(() async {
      await _sync.load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              SyncPage(controller: _sync, shortcuts: widget.shortcuts),
        ),
      );
      await _refresh();
    }, autoSync: false);
  }

  void _focusSearch() {
    final searchContext = _searchFocus.context;
    if (searchContext != null) Scrollable.ensureVisible(searchContext);
    _searchFocus.requestFocus();
  }

  Future<void> _syncNow() async {
    if (_hasOpenDocuments || _busy) return;
    await _sync.load();
    if (!mounted) return;
    if (!_sync.enabled) {
      await _syncSettings();
      return;
    }
    await _perform(() async {
      await _sync.synchronize();
      await _refresh();
    }, autoSync: false);
  }

  @override
  void dispose() {
    widget.workspaceController?.refresh = null;
    widget.workspaceController?.syncQuickTodos = null;
    widget.workspaceController?.syncJournal = null;
    widget.workspaceController?.commands = const {};
    widget.workspaceController?.actions = const {};
    widget.workspaceController?.addQuickTodo = null;
    _sync.removeListener(_syncChanged);
    MediaGateway.recoveredCapture.removeListener(_captureRecovered);
    FileGateway.sharedText.removeListener(_sharedCapture);
    if (widget.syncController == null) _sync.dispose();
    _previews.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  static bool _isConflict(Notebook note) =>
      (note.isSettingsConflict && !note.isArchivedSettingsConflict) ||
      note.id.startsWith('conflict_');

  void _showConflicts() {
    _searchFocus.unfocus();
    setState(() {
      _query = '';
      _searchText.clear();
      _folderFilter = null;
      _tagFilter = null;
      _kind = 'conflicts';
    });
  }

  Future<void> _refresh() async {
    try {
      await widget.repository.catalog.load();
      var notes = await widget.repository.list();
      String? migrationWarning;
      var migrated = false;
      try {
        migrated = await KnowledgeStore(widget.repository).migrateQuickTodos(
          notes,
          isOpen: (id) => widget.isNotebookOpen?.call(id) ?? false,
        );
        if (migrated) notes = await widget.repository.list();
      } catch (error) {
        notes = await widget.repository.list();
        migrationWarning = 'Could not move older quick to-dos: $error';
      }
      final captures = MediaGateway.canCapture
          ? await MediaGateway.pendingCaptures()
          : const <String>[];
      if (mounted) {
        final conflicts = widget.workspaceController?.conflicts;
        if (conflicts != null) {
          conflicts.value = notes.where(_isConflict).length;
        }
        setState(() {
          _notes = notes;
          final available = {for (final note in notes) note.id};
          _selectedNotes.removeWhere((id) => !available.contains(id));
          _recoverableCaptures = captures;
          _showNavigation = widget.repository.catalog.displayPreferences.flag(
            'librarySidebar',
            true,
          );
          if (_tagFilter != null &&
              !notes.any((n) => n.tags.contains(_tagFilter))) {
            _tagFilter = null;
          }
          _loading = false;
          _error = widget.repository.readErrors.isEmpty
              ? migrationWarning ?? widget.repository.catalog.loadWarning
              : 'Some note files could not be read: ${widget.repository.readErrors.join(', ')}';
        });
        if (migrated) widget.workspaceController?.onLegacyTasksMigrated?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load notes: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _perform(
    Future<void> Function() action, {
    bool autoSync = true,
  }) async {
    if (!mounted || _busy) return;
    setState(() => _actionBusy = true);
    try {
      final before = autoSync && _sync.enabled && _sync.automatic
          ? await _noteStates()
          : null;
      if (!mounted) return;
      await action();
      if (before != null && mounted) await _autoSync(before);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Action failed: $e'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _recoverCapture() async {
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unfinished media imports'),
        content: SizedBox(
          width: 400,
          height: 280,
          child: ListView(
            children: [
              for (final path in _recoverableCaptures)
                ListTile(
                  leading: const Icon(Icons.perm_media_outlined),
                  title: Text(p.basename(path)),
                  onTap: () => Navigator.pop(context, path),
                  trailing: IconButton(
                    tooltip: 'Discard captured file',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await MediaGateway.discardCapture(path);
                      if (context.mounted) Navigator.pop(context);
                      await _refresh();
                    },
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
        ],
      ),
    );
    if (path == null || !mounted) return;
    try {
      _pendingMedia = await MediaGateway.consumeCapture(path);
      await _addMedia();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not recover captured media: $error')),
        );
      }
    }
  }

  Future<void> _addMedia() => _perform(() async {
    final media = _pendingMedia ?? await acquireMedia(context);
    if (media == null || !mounted) return;
    _pendingMedia = media;
    final now = DateTime.now();
    try {
      final note = await widget.repository.save(
        Notebook(
          id: LocalNotebookRepository.newId(),
          title: p.basenameWithoutExtension(media.name),
          created: now,
          modified: now,
          paper: 'media:${media.format.extension}',
          folderId: _folderFilter?.isNotEmpty == true ? _folderFilter : null,
          tags: _tagFilter == null ? const [] : [_tagFilter!],
        ),
        media.bytes,
      );
      _pendingMedia = null;
      await media.release();
      await _refresh();
      await _open(note);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Media could not be saved: $error'),
            action: SnackBarAction(label: 'Retry', onPressed: _addMedia),
          ),
        );
      }
    }
  });

  Future<void> _open(Notebook note) async {
    if (widget.onOpenNotebook != null) {
      await widget.onOpenNotebook!(note);
      return;
    }
    final bytes = await widget.repository.load(note.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => note.isMedia
            ? MediaPage(
                name: note.title,
                bytes: bytes,
                format: note.mediaFormat!,
                note: note,
                repository: widget.repository,
              )
            : note.isTodoList
            ? TodoListPage(
                note: note,
                bytes: bytes,
                repository: widget.repository,
              )
            : note.isMarkdown
            ? MarkdownEditorPage(
                note: note,
                bytes: bytes,
                repository: widget.repository,
              )
            : EditorPage(
                note: note,
                bytes: bytes,
                repository: widget.repository,
                shortcuts: widget.shortcuts,
              ),
      ),
    );
    await _refresh();
  }

  Future<void> _searchPdfs() => _perform(() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfSearchPage(
          notes: _notes.where((n) => n.isPdf).toList(),
          repository: widget.repository,
          shortcuts: widget.shortcuts,
        ),
      ),
    );
    await _refresh();
  });

  Future<void> _study() => _perform(() async {
    if (!(await widget.beforeStudy?.call() ?? true) || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudyPage(
          repository: widget.repository,
          shortcuts: widget.shortcuts,
          workspaceSessions: widget.workspaceSessions,
        ),
      ),
    );
    if (!mounted) return;
    await widget.onRefreshDocuments?.call();
    await _refresh();
  });

  Future<void> _templates() => _perform(() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            TemplateLibrary(repository: widget.repository.templates),
      ),
    );
  });

  Future<void> _create() async {
    final choice = await showDialog<(String, String, NoteTemplate?, int)>(
      context: context,
      builder: (_) => _NewNoteDialog(templates: widget.repository.templates),
    );
    if (choice == null) return;
    if (choice.$2 == 'media') {
      await _addMedia();
      return;
    }
    await _perform(() async {
      final template = choice.$3 == null
          ? null
          : await widget.repository.templates.instantiateEditable(
              choice.$3!.id,
            );
      var note = switch (choice.$2) {
        'markdown' when template == null => await MarkdownLibrary(
          widget.repository,
        ).create(choice.$1),
        'todo' when template == null => await createTodoList(
          widget.repository,
          choice.$1,
        ),
        _ => await widget.repository.create(
          choice.$1,
          template?.bytes ?? await createPaper(choice.$2, lineColor: choice.$4),
          paper: choice.$3 == null ? choice.$2 : 'pdf',
          lineColor: choice.$4,
        ),
      };
      if (template != null && template.ink.strokes.isNotEmpty) {
        note = await widget.repository.saveWithInk(
          note,
          template.bytes,
          template.ink,
        );
      }
      await _refresh();
      await _open(note);
    });
  }

  Future<void> _import({VoidCallback? onImported}) => _perform(() async {
    final file = await FileGateway().pick();
    if (file == null) return;
    if (await file.length() > 256 * 1024 * 1024) {
      throw const FormatException('The file is too large (maximum 256 MB).');
    }
    final bytes = await file.readAsBytes();
    final extension = p.extension(file.name).toLowerCase();
    if (extension == '.zip') {
      final imported = await MarkdownLibrary(
        widget.repository,
      ).importBundle(bytes);
      await _refresh();
      onImported?.call();
      await _open(imported.first);
      return;
    }
    final mediaFormat = MediaFormat.of(extension);
    final note = mediaFormat != null
        ? await widget.repository.create(
            p.basenameWithoutExtension(file.name),
            bytes,
            paper: 'media:${mediaFormat.extension}',
          )
        : extension == '.md'
        ? await MarkdownLibrary(widget.repository).importText(file.name, bytes)
        : extension == '.noter'
        ? await widget.repository.importArchive(bytes)
        : await widget.repository.create(
            p.basenameWithoutExtension(file.name),
            bytes,
          );
    await _refresh();
    onImported?.call();
    await _open(note);
  });
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (FileGateway.sharedText.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sharedCapture());
    }
  }

  bool _handlingShare = false;
  void _sharedCapture() {
    if (!mounted ||
        _handlingShare ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final text = FileGateway.sharedText.value;
    if (text == null) return;
    _handlingShare = true;
    _presentSharedText(text);
  }

  Future<void> _presentSharedText(String text) async {
    var opened = false;
    try {
      await _knowledge(
        section: 'Inbox',
        sharedText: text,
        onOpening: () {
          opened = true;
          if (FileGateway.sharedText.value == text) {
            FileGateway.sharedText.value = null;
          }
        },
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open capture: $error')),
        );
      }
    } finally {
      _handlingShare = false;
      if (mounted && !opened && FileGateway.sharedText.value != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Shared text is pending. Save your open notes, then retry.',
            ),
            action: SnackBarAction(
              label: 'Retry capture',
              onPressed: _sharedCapture,
            ),
          ),
        );
      } else if (mounted && opened && FileGateway.sharedText.value != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sharedCapture());
      }
    }
  }

  Future<void> _captureInbox() async {
    final capture = await showInboxCaptureDialog(context);
    if (capture == null || !mounted) return;
    Notebook? captured;
    await _perform(() async {
      captured = await KnowledgeStore(
        widget.repository,
      ).capture(capture.$1, capture.$2);
      await _refresh();
    });
    if (!mounted || captured == null) return;
    await _syncChangedNote(captured);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Saved to Inbox'),
        action: SnackBarAction(
          label: 'Open Inbox',
          onPressed: () => _openWorkspaceSection('Inbox'),
        ),
      ),
    );
  }

  void _openWorkspaceSection(String section) {
    if (widget.onWorkspaceSection case final open?) {
      open(section);
    } else {
      unawaited(_knowledge(section: section));
    }
  }

  Widget _knowledgeLinks() {
    final inbox = _notes
        .where((note) => note.tags.any((tag) => tag.toLowerCase() == 'inbox'))
        .length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ActionChip(
            avatar: const Icon(Icons.inbox_outlined),
            label: Text(inbox == 0 ? 'Inbox' : 'Inbox · $inbox'),
            onPressed: _busy ? null : () => _openWorkspaceSection('Inbox'),
          ),
          if (widget.onWorkspaceSection == null) ...[
            const SizedBox(width: 8),
            ActionChip(
              avatar: const Icon(Icons.checklist),
              label: const Text('Tasks'),
              onPressed: _busy ? null : () => _openWorkspaceSection('Tasks'),
            ),
            const SizedBox(width: 8),
            ActionChip(
              avatar: const Icon(Icons.calendar_today_outlined),
              label: const Text('Journal'),
              onPressed: _busy ? null : () => _openWorkspaceSection('Journal'),
            ),
          ],
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.sell_outlined),
            label: const Text('Tags'),
            onPressed: _busy ? null : () => _openWorkspaceSection('Tags'),
          ),
          if (widget.onWorkspaceSection != null) ...[
            const SizedBox(width: 8),
            ActionChip(
              avatar: const Icon(Icons.delete_outline),
              label: const Text('Trash'),
              onPressed: _busy ? null : _recovery,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _knowledge({
    String section = 'Search',
    String? sharedText,
    VoidCallback? onOpening,
    bool autofocusSearch = false,
  }) async {
    if (!await FileGateway.prepareClose() || !mounted) return;
    if ((onOpening != null || autofocusSearch) &&
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    onOpening?.call();
    final destination = await Navigator.push<KnowledgeDestination>(
      context,
      MaterialPageRoute(
        builder: (_) => KnowledgePage(
          repository: widget.repository,
          initialSection: section,
          sharedText: sharedText,
          onChangeTask: (task) async {
            final updated =
                await (widget.onChangeTask ??
                    KnowledgeStore(widget.repository).changeTask)(task);
            if (task.deleting) await _syncChangedNote(task.note);
            return updated;
          },
          autofocusSearch: autofocusSearch,
          shortcuts: widget.shortcuts,
          onImportFile: (onImported) => _import(onImported: onImported),
          onQuickTodo: _quickTodo,
          onQuickTodosChanged: _syncQuickTodos,
          onJournalChanged: _syncChangedNote,
          onTaskPlanned: _syncChangedNote,
        ),
      ),
    );
    await widget.onRefreshDocuments?.call();
    if (!mounted) return;
    await _refresh();
    if (destination == null || !mounted) return;
    if (widget.onOpenDestination != null) {
      await widget.onOpenDestination!(
        destination.note,
        anchor: destination.anchor,
      );
      return;
    }
    final bytes = await widget.repository.load(destination.note.id);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => destination.note.isMedia
            ? MediaPage(
                name: destination.note.title,
                bytes: bytes,
                format: destination.note.mediaFormat!,
                note: destination.note,
                repository: widget.repository,
              )
            : destination.note.isTodoList
            ? TodoListPage(
                note: destination.note,
                bytes: bytes,
                repository: widget.repository,
                initialAnchor: destination.anchor,
              )
            : destination.note.isMarkdown
            ? MarkdownEditorPage(
                note: destination.note,
                bytes: bytes,
                repository: widget.repository,
                initialAnchor: destination.anchor,
              )
            : EditorPage(
                note: destination.note,
                bytes: bytes,
                repository: widget.repository,
                shortcuts: widget.shortcuts,
                initialPage: markdownPdfPage(destination.anchor) == null
                    ? null
                    : markdownPdfPage(destination.anchor)! - 1,
              ),
      ),
    );
    await _refresh();
  }

  Future<bool> _quickTodo() async {
    var added = false;
    await _perform(() async {
      added = await showQuickTodoDialog(context, widget.repository);
      if (added && mounted) await _refresh();
    });
    if (added && mounted && ModalRoute.of(context)?.isCurrent == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('To-do added.'),
          action: SnackBarAction(
            label: 'View to-dos',
            onPressed: () => _openWorkspaceSection(unsortedTodos),
          ),
        ),
      );
    }
    return added;
  }

  Future<void> _graphView() async {
    final note = await Navigator.push<Notebook>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryGraphPage(repository: widget.repository),
      ),
    );
    if (note != null && mounted) await _perform(() => _open(note));
  }

  Future<void> _organize(Notebook note) async {
    final updated = await showDialog<Notebook>(
      context: context,
      builder: (_) => OrganizeDialog(note: note, repository: widget.repository),
    );
    if (updated == null) return;
    await _perform(() async {
      await widget.repository.save(
        updated,
        await widget.repository.load(note.id),
      );
      await _refresh();
    });
  }

  Future<void> _folders() => _perform(() async {
    await showDialog<void>(
      context: context,
      builder: (_) => FolderManager(repository: widget.repository),
    );
    if (_folderFilter != null &&
        _folderFilter!.isNotEmpty &&
        widget.repository.catalog.folderName(_folderFilter) == null) {
      _folderFilter = null;
    }
    await _refresh();
  });

  Future<void> _rename(Notebook note) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _TitleDialog(initial: note.title),
    );
    if (title == null) return;
    await _perform(() async {
      await widget.repository.save(
        note.copy(title: title),
        await widget.repository.load(note.id),
      );
      await _refresh();
    });
  }

  Future<void> _exportFile(Notebook note) => _perform(() async {
    final repository = widget.repository;
    final Uint8List bytes;
    if (note.isTodoList) {
      bytes = await repository.exportArchive(note);
    } else if (note.isPdf) {
      final pdf = await repository.loadPdf(note.id);
      bytes = await exportPdfBytesAsync(pdf);
    } else {
      final stored = await repository.load(note.id);
      bytes = note.isMarkdown
          ? utf8.encode((await decodeMarkdownAsync(stored)).source)
          : stored;
    }
    if (!mounted) return;
    final mime =
        note.mediaFormat?.mime ??
        (note.isTodoList
            ? 'application/zip'
            : note.isPdf
            ? 'application/pdf'
            : 'text/markdown');
    final name = FileGateway.exportName(
      note.title,
      note.isTodoList ? 'noter' : note.extension,
    );
    if (await FileGateway().save(name, bytes, mime) && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File saved.')));
    }
  }, autoSync: false);

  Future<void> _resolveSettingConflict(Notebook note, {required bool accept}) =>
      _perform(() async {
        if (accept && _hasOpenDocuments) {
          throw StateError(
            'Close open tabs before applying the alternative setting.',
          );
        }
        await LibraryExtrasSync.resolveSettingConflict(
          widget.repository,
          note.id,
          accept: accept,
        );
        await _refresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                accept
                    ? 'Alternative setting applied. Conflict archived.'
                    : 'Conflict archived. Current setting kept.',
              ),
            ),
          );
        }
      });

  Future<bool> _confirmDelete({Notebook? note, required int count}) async {
    final subject = note == null
        ? '$count ${count == 1 ? 'note' : 'notes'}'
        : '“${note.title}”';
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: Text(
              note == null ? 'Move selected notes to trash?' : 'Delete note?',
            ),
            content: Text(
              '$subject will be moved to the local trash. '
              '${_sync.enabled ? 'The deletion will reach other devices on the next server sync.' : 'Items in the trash can be restored as copies.'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _delete(Notebook note) async {
    if (!await _confirmDelete(note: note, count: 1) || !mounted) return;
    await _perform(() async {
      await widget.repository.delete(note.id);
      await _refresh();
    });
  }

  void _closeSelection() => setState(() {
    _selecting = false;
    _selectedNotes.clear();
  });

  void _toggleSelection(Notebook note) {
    if (_busy || _isOpen(note)) return;
    setState(() {
      _selecting = true;
      if (!_selectedNotes.add(note.id)) _selectedNotes.remove(note.id);
    });
  }

  List<Notebook> get _selection =>
      _notes.where((note) => _selectedNotes.contains(note.id)).toList();

  Future<void> _moveSelected() async {
    final selection = _selection;
    if (_busy || selection.isEmpty) return;
    final folder = await pickMoveFolder(
      context,
      widget.repository.catalog.folders,
    );
    if (folder == null || !mounted) return;
    final repository = widget.repository;
    final name = repository.catalog.folderName(folder);
    if (folder.isNotEmpty && name == null) return;
    await _applySelection(selection, 'moved', (id) async {
      final snapshot = await repository.snapshotForSync(id);
      if (snapshot == null) {
        throw const FormatException('The note was removed.');
      }
      final (note, bytes, ink) =
          await LocalNotebookRepository.decodeInkValidated(snapshot.archive);
      if (note.folderId == (folder.isEmpty ? null : folder)) return;
      final moved = await LocalNotebookRepository.encodeAsync(
        note.copy(
          folderId: folder.isEmpty ? null : folder,
          folderName: name,
          clearFolder: folder.isEmpty,
          modified: DateTime.now(),
        ),
        bytes,
        ink: ink,
      );
      await repository.applySync(id, snapshot.raw, moved);
    });
  }

  Future<void> _deleteSelected() async {
    final selection = _selection;
    if (_busy ||
        selection.isEmpty ||
        !await _confirmDelete(count: selection.length) ||
        !mounted) {
      return;
    }
    await _applySelection(
      selection,
      'moved to trash',
      widget.repository.delete,
    );
  }

  Future<void> _applySelection(
    List<Notebook> selection,
    String result,
    Future<void> Function(String id) action,
  ) => _perform(() async {
    final failures = <String>[];
    var completed = 0;
    for (final note in selection) {
      try {
        if (_isOpen(note)) {
          throw const FormatException('Close the note before changing it.');
        }
        await action(note.id);
        _selectedNotes.remove(note.id);
        completed++;
      } catch (error) {
        failures.add('${note.title}: $error');
      }
    }
    await _refresh();
    if (!mounted) return;
    if (_selectedNotes.isEmpty) _closeSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$completed ${completed == 1 ? 'note' : 'notes'} $result.'
          '${failures.isEmpty ? '' : '\nCould not change ${failures.length}. ${failures.join('. ')}'}',
        ),
      ),
    );
  });

  Future<void> _recovery({Notebook? note}) => _perform(() async {
    final restored = await Navigator.of(context).push<Notebook>(
      MaterialPageRoute(
        builder: (_) => RecoveryPage(repository: widget.repository, note: note),
      ),
    );
    await _refresh();
    if (restored != null) await _open(restored);
  });

  @override
  Widget build(BuildContext context) {
    final visible = _notes
        .where((n) => n.title.toLowerCase().contains(_query.toLowerCase()))
        .where(
          (n) =>
              !n.isArchivedSettingsConflict ||
              _query.isNotEmpty ||
              _folderFilter != null ||
              _tagFilter != null,
        )
        .where(
          (n) =>
              _folderFilter == null ||
              (_folderFilter == ''
                  ? widget.repository.catalog.folderName(n.folderId) == null
                  : n.folderId == _folderFilter),
        )
        .where((n) => _tagFilter == null || n.tags.contains(_tagFilter))
        .where(
          (n) =>
              _kind == 'all' ||
              (_kind == 'conflicts' && _isConflict(n)) ||
              (_kind == 'markdown' && n.isMarkdown && !n.isTodoList) ||
              (_kind == 'todo' && n.isTodoList) ||
              (_kind == 'pdf' && n.paper == 'pdf') ||
              (_kind == 'notes' && n.isPdf && n.paper != 'pdf') ||
              (_kind == 'media' && n.isMedia),
        )
        .toList();
    final hiddenSelection =
        _selectedNotes.length -
        visible.where((note) => _selectedNotes.contains(note.id)).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 760 && constraints.maxHeight >= 440;
        final phone = NoterTheme.mobileLayout(constraints.maxWidth);
        _canPreview =
            constraints.maxWidth >= 1000 && constraints.maxHeight >= 480;
        final preview = _canPreview && !_selecting
            ? visible.where((note) => note.id == _previewId).firstOrNull
            : null;
        return Scaffold(
          key: _scaffold,
          drawer: wide ? null : Drawer(child: SafeArea(child: _navigation())),
          appBar: AppBar(
            leadingWidth: DocumentTabsChrome.leadingWidth(context),
            leading: DocumentNavigation(
              child: _selecting
                  ? IconButton(
                      tooltip: 'Close selection',
                      onPressed: _busy ? null : _closeSelection,
                      icon: const Icon(Icons.close),
                    )
                  : IconButton(
                      tooltip: wide && _showNavigation
                          ? 'Hide folders'
                          : 'Show folders',
                      icon: Icon(
                        wide && _showNavigation
                            ? Icons.folder_open_outlined
                            : Icons.folder_outlined,
                      ),
                      onPressed: () {
                        if (!wide) {
                          _scaffold.currentState?.openDrawer();
                          return;
                        }
                        setState(() => _showNavigation = !_showNavigation);
                        widget.repository.catalog.displayPreferences
                            .set('librarySidebar', _showNavigation)
                            .catchError((Object _) {});
                      },
                    ),
            ),
            toolbarHeight: NoterTheme.headerHeight(context),
            titleSpacing: _selecting ? 4 : null,
            title: _selecting
                ? Text(
                    '${_selectedNotes.length} selected',
                    overflow: TextOverflow.ellipsis,
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.draw_outlined,
                        color: NoterTheme.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.onWorkspaceSection == null
                              ? 'Notixer'
                              : 'Files',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
            actions: _selecting
                ? _selectionActions(visible)
                : widget.onWorkspaceSection != null
                ? [
                    IconButton(
                      tooltip: 'Reload files',
                      onPressed: _busy ? null : _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip:
                          widget.shortcuts?.tooltip(
                            'Add to-do',
                            AppShortcut.quickTodo,
                          ) ??
                          'Add to-do',
                      onPressed: _busy ? null : _quickTodo,
                      icon: const Icon(Icons.playlist_add),
                    ),
                    IconButton(
                      tooltip: 'Capture to Inbox',
                      onPressed: _busy ? null : _captureInbox,
                      icon: const Icon(Icons.move_to_inbox_outlined),
                    ),
                    if (!_hasOpenDocuments)
                      SyncButton(
                        controller: _sync,
                        disabled: _busy,
                        onSynchronized: _refresh,
                        onOpenDetails: _syncSettings,
                      ),
                    IconButton(
                      tooltip:
                          widget.shortcuts?.tooltip(
                            'Knowledge hub',
                            AppShortcut.knowledgeSearch,
                          ) ??
                          'Knowledge hub',
                      onPressed: _busy ? null : _knowledge,
                      icon: const Icon(Icons.manage_search),
                    ),
                    _libraryActions(),
                  ],
          ),
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide && _showNavigation)
                  SizedBox(width: 220, child: _navigation()),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.all(phone ? 16 : 20),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _libraryHeading(context, visible.length),
                                  if (!_selecting) ...[
                                    const SizedBox(height: 10),
                                    _knowledgeLinks(),
                                  ],
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _searchText,
                                          focusNode: _searchFocus,
                                          decoration: const InputDecoration(
                                            hintText: 'Search note titles',
                                            prefixIcon: Icon(Icons.search),
                                          ),
                                          onChanged: (value) =>
                                              setState(() => _query = value),
                                        ),
                                      ),
                                      if (!_selecting)
                                        IconButton(
                                          tooltip: 'Select notes',
                                          onPressed:
                                              _busy || visible.every(_isOpen)
                                              ? null
                                              : () => setState(
                                                  () => _selecting = true,
                                                ),
                                          icon: const Icon(Icons.checklist),
                                        ),
                                      IconButton(
                                        tooltip: _grid
                                            ? 'List view'
                                            : 'Grid view',
                                        onPressed: () =>
                                            setState(() => _grid = !_grid),
                                        icon: Icon(
                                          _grid
                                              ? Icons.view_list_outlined
                                              : Icons.grid_view_outlined,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final (id, label) in [
                                        ('all', 'All'),
                                        ('markdown', 'Text'),
                                        ('todo', 'To-do lists'),
                                        ('notes', 'Notebooks'),
                                        ('pdf', 'PDFs'),
                                        ('media', 'Media'),
                                        if (_notes.any(_isConflict) ||
                                            _kind == 'conflicts')
                                          ('conflicts', 'Conflicts'),
                                      ])
                                        ChoiceChip(
                                          label: Text(label),
                                          selected: _kind == id,
                                          onSelected: (_) =>
                                              setState(() => _kind = id),
                                        ),
                                      if (_tagFilter != null)
                                        InputChip(
                                          label: Text('#$_tagFilter'),
                                          deleteButtonTooltipMessage:
                                              'Clear tag filter',
                                          onDeleted: () =>
                                              setState(() => _tagFilter = null),
                                        ),
                                      if (_folderFilter != null ||
                                          _kind != 'all')
                                        ActionChip(
                                          label: const Text('Reset filters'),
                                          onPressed: () => setState(() {
                                            _folderFilter = null;
                                            _tagFilter = null;
                                            _kind = 'all';
                                          }),
                                        ),
                                    ],
                                  ),
                                  if (hiddenSelection > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        '$hiddenSelection selected outside the current filters.',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ),
                                  ListenableBuilder(
                                    listenable: _sync,
                                    builder: (context, _) =>
                                        _sync.enabled || _sync.error != null
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                            ),
                                            child: Semantics(
                                              liveRegion: true,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    _sync.error ?? _sync.status,
                                                    style: TextStyle(
                                                      color: _sync.error == null
                                                          ? null
                                                          : Theme.of(
                                                              context,
                                                            ).colorScheme.error,
                                                    ),
                                                  ),
                                                  if (_sync.error != null)
                                                    TextButton(
                                                      onPressed: _busy
                                                          ? null
                                                          : _syncSettings,
                                                      child: const Text(
                                                        'Open sync details',
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                  if (_busy) const LinearProgressIndicator(),
                                  if (_error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (_loading)
                            const SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(child: CircularProgressIndicator()),
                            )
                          else if (visible.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.edit_note,
                                        size: 64,
                                        color: NoterTheme.accent,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _hasFilters
                                            ? 'No matching notes found.'
                                            : 'Your first page is waiting for you.',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _hasFilters
                                            ? 'Change the search or the folder and tag filters.'
                                            : 'Create a note or import a PDF.',
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          else if (!_grid)
                            SliverPadding(
                              padding: EdgeInsets.fromLTRB(
                                phone ? 12 : 20,
                                0,
                                phone ? 12 : 20,
                                24,
                              ),
                              sliver: SliverList.builder(
                                itemCount: visible.length,
                                itemBuilder: (context, index) =>
                                    _noteRow(visible[index], compact: phone),
                              ),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                              sliver: SliverLayoutBuilder(
                                builder: (context, constraints) =>
                                    SliverGrid.builder(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount:
                                                MediaQuery.textScalerOf(
                                                          context,
                                                        ).scale(16) >
                                                        24 ||
                                                    constraints
                                                            .crossAxisExtent <
                                                        300
                                                ? 1
                                                : constraints.crossAxisExtent <
                                                      840
                                                ? 2
                                                : 3,
                                            mainAxisExtent:
                                                (phone ? 246 : 310) +
                                                (MediaQuery.textScalerOf(
                                                              context,
                                                            ).scale(16) /
                                                            16 -
                                                        1) *
                                                    100,
                                            mainAxisSpacing: 16,
                                            crossAxisSpacing: 12,
                                          ),
                                      itemCount: visible.length,
                                      itemBuilder: (context, index) =>
                                          _noteCard(
                                            visible[index],
                                            compact: phone,
                                          ),
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (preview != null)
                  WorkspaceSidebar(
                    child: SizedBox(
                      width: 262,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          ListTile(
                            title: const Text('Preview'),
                            trailing: IconButton(
                              tooltip: 'Close file preview',
                              icon: const Icon(Icons.close),
                              onPressed: () =>
                                  setState(() => _previewId = null),
                            ),
                          ),
                          NotebookPreview(
                            key: ValueKey(preview.id),
                            note: preview,
                            cache: _previews,
                            height: 280,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            preview.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _noteTap(preview),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Open file'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _selectionActions(List<Notebook> visible) {
    final ids = visible.where((note) => !_isOpen(note)).map((note) => note.id);
    final allSelected = ids.every(_selectedNotes.contains);
    return [
      IconButton(
        tooltip: allSelected && ids.isNotEmpty
            ? 'Deselect visible notes'
            : 'Select all visible notes',
        onPressed: _busy || ids.isEmpty
            ? null
            : () => setState(() {
                if (allSelected) {
                  _selectedNotes.removeAll(ids);
                } else {
                  _selectedNotes.addAll(ids);
                }
              }),
        icon: Icon(
          allSelected && ids.isNotEmpty ? Icons.deselect : Icons.select_all,
        ),
      ),
      IconButton(
        tooltip: 'Move selected notes',
        onPressed: _busy || _selectedNotes.isEmpty ? null : _moveSelected,
        icon: const Icon(Icons.drive_file_move_outline),
      ),
      IconButton(
        tooltip: 'Move selected notes to trash',
        onPressed: _busy || _selectedNotes.isEmpty ? null : _deleteSelected,
        icon: const Icon(Icons.delete_outline),
      ),
    ];
  }

  Widget _libraryHeading(BuildContext context, int count) {
    final theme = Theme.of(context);
    final folder = _folderFilter == ''
        ? 'Unfiled'
        : widget.repository.catalog.folderName(_folderFilter) ??
              (widget.onWorkspaceSection == null ? 'My notes' : 'All files');
    return Wrap(
      spacing: 20,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              folder,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$count ${count == 1 ? 'note' : 'notes'}'
              ' · Most recently modified first',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (widget.onWorkspaceSection == null)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.add),
                label: const Text('New note'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import file'),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _liveCanvas() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            LiveHostPage(repository: widget.repository, sync: _sync),
      ),
    );
    if (mounted) await _refresh();
  }

  Widget _libraryActions() => PopupMenuButton<VoidCallback>(
    tooltip: 'Library actions',
    onSelected: (action) => action(),
    itemBuilder: (_) => [
      if (Platform.isAndroid)
        PopupMenuItem(
          value: _liveCanvas,
          enabled: !_busy,
          child: const Text('Live Canvas'),
        ),
      PopupMenuItem(
        value: _searchPdfs,
        enabled: !_busy && _notes.any((n) => n.isPdf),
        child: const Text('Search PDFs'),
      ),
      PopupMenuItem(
        value: _graphView,
        enabled: !_busy,
        child: const Text('Graph view'),
      ),
      PopupMenuItem(
        value: _study,
        enabled: !_busy,
        child: const Text('Study today'),
      ),
      PopupMenuItem(
        value: _templates,
        enabled: !_busy,
        child: const Text('Notebook templates'),
      ),
      const PopupMenuDivider(),
      if (_recoverableCaptures.isNotEmpty)
        PopupMenuItem(
          value: _recoverCapture,
          enabled: !_busy,
          child: const Text('Recover captured media'),
        ),
      PopupMenuItem(
        value: _recovery,
        enabled: !_busy,
        child: const Text('Trash'),
      ),
      PopupMenuItem(
        value: _refresh,
        enabled: !_busy,
        child: const Text('Reload notes'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _syncSettings,
        enabled: !_busy && !_hasOpenDocuments,
        child: Text(
          _hasOpenDocuments
              ? 'Sync settings (close open tabs)'
              : 'Sync settings',
        ),
      ),
      if (widget.onSettings != null)
        PopupMenuItem(
          value: widget.onSettings,
          enabled: !_busy,
          child: const Text('Settings'),
        ),
    ],
  );

  Widget _navigation() => LibraryNavigation(
    notes: _notes,
    folders: widget.repository.catalog.folders,
    folder: _folderFilter,
    tag: _tagFilter,
    enabled: !_busy,
    onFolder: (value) {
      setState(() => _folderFilter = value);
      _scaffold.currentState?.closeDrawer();
    },
    onTag: (value) {
      setState(() => _tagFilter = value);
      _scaffold.currentState?.closeDrawer();
    },
    onManage: () {
      _scaffold.currentState?.closeDrawer();
      _folders();
    },
  );

  bool get _hasFilters =>
      _query.isNotEmpty ||
      _folderFilter != null ||
      _tagFilter != null ||
      _kind != 'all';

  Widget _noteActions(Notebook note) => PopupMenuButton<String>(
    tooltip: _isOpen(note)
        ? 'Open note: actions available after closing the tab'
        : 'Note actions',
    enabled: !_busy && !_isOpen(note),
    onSelected: (value) => switch (value) {
      'accept-conflict' => _resolveSettingConflict(note, accept: true),
      'archive-conflict' => _resolveSettingConflict(note, accept: false),
      'export' => _exportFile(note),
      'rename' => _rename(note),
      'organize' => _organize(note),
      'history' => _recovery(note: note),
      'preview' => setState(() => _previewId = note.id),
      _ => _delete(note),
    },
    itemBuilder: (_) => [
      if (note.isSettingsConflict && !note.isArchivedSettingsConflict) ...[
        const PopupMenuItem(
          value: 'accept-conflict',
          child: Text('Apply alternative setting'),
        ),
        const PopupMenuItem(
          value: 'archive-conflict',
          child: Text('Keep current setting and archive'),
        ),
      ],
      if (_canPreview)
        const PopupMenuItem(value: 'preview', child: Text('Preview')),
      const PopupMenuItem(value: 'export', child: Text('Save file to device')),
      const PopupMenuItem(value: 'rename', child: Text('Rename')),
      const PopupMenuItem(value: 'organize', child: Text('Folders and tags')),
      const PopupMenuItem(value: 'history', child: Text('Version history')),
      const PopupMenuItem(value: 'delete', child: Text('Delete')),
    ],
  );

  Widget _noteControl(Notebook note) {
    if (!_selecting) return _noteActions(note);
    return Checkbox(
      semanticLabel: _isOpen(note)
          ? 'Close the open note to select it'
          : 'Select ${note.title}',
      value: _selectedNotes.contains(note.id),
      onChanged: _busy || _isOpen(note) ? null : (_) => _toggleSelection(note),
    );
  }

  VoidCallback? _noteTap(Notebook note) => _busy
      ? null
      : _selecting
      ? (_isOpen(note) ? null : () => _toggleSelection(note))
      : () => _perform(() => _open(note));

  Widget _noteRow(Notebook note, {required bool compact}) {
    final date = note.modified.toLocal();
    final organization = [
      if (note.folderId != null)
        widget.repository.catalog.folderName(note.folderId) ?? 'Unfiled',
      ...note.tags.map((tag) => '#$tag'),
    ].join(' · ');
    final type = note.isMedia
        ? note.mediaFormat!.kind
        : note.isTodoList
        ? 'To-do list'
        : note.isMarkdown
        ? 'Markdown'
        : note.paper == 'pdf'
        ? 'PDF'
        : note.paper == 'lined'
        ? 'Ruled'
        : note.paper == 'grid'
        ? 'Grid'
        : 'Blank';
    return Card(
      key: ValueKey('library-row-${note.id}'),
      color: _selectedNotes.contains(note.id) ? NoterTheme.active : null,
      shape: const RoundedRectangleBorder(),
      child: InkWell(
        onTap: _noteTap(note),
        onLongPress: _busy || _isOpen(note)
            ? null
            : () => _toggleSelection(note),
        hoverColor: NoterTheme.workspace,
        focusColor: NoterTheme.active,
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 76 : 64),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: NoterTheme.border)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 40,
                decoration: BoxDecoration(
                  color: NoterTheme.workspace,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  note.isMedia
                      ? mediaIcon(note.mediaFormat!)
                      : note.isTodoList
                      ? Icons.checklist
                      : note.isMarkdown
                      ? Icons.description_outlined
                      : Icons.picture_as_pdf_outlined,
                  size: 20,
                  color: NoterTheme.muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DocumentTypeBadge(type),
                        if (compact)
                          Text(
                            MaterialLocalizations.of(
                              context,
                            ).formatShortDate(date),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    if (organization.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          organization,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              if (!compact)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    MaterialLocalizations.of(context).formatShortDate(date),
                    semanticsLabel:
                        'Modified on ${MaterialLocalizations.of(context).formatShortDate(date)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              _noteControl(note),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noteCard(Notebook note, {required bool compact}) {
    final date = note.modified.toLocal();
    return Card(
      color: _selectedNotes.contains(note.id) ? NoterTheme.active : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _noteTap(note),
        onLongPress: _busy || _isOpen(note)
            ? null
            : () => _toggleSelection(note),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                NotebookPreview(
                  key: ValueKey(note.id),
                  note: note,
                  cache: _previews,
                  height: compact ? 116 : 176,
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: _selecting
                      ? Material(
                          color: NoterTheme.background,
                          borderRadius: BorderRadius.circular(6),
                          child: _noteControl(note),
                        )
                      : _noteControl(note),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (note.folderId != null || note.tags.isNotEmpty)
                      Text(
                        [
                          if (note.folderId != null)
                            widget.repository.catalog.folderName(
                                  note.folderId,
                                ) ??
                                'Unfiled',
                          ...note.tags.map((t) => '#$t'),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: NoterTheme.muted,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      MaterialLocalizations.of(context).formatShortDate(date),
                      semanticsLabel:
                          'Modified on ${MaterialLocalizations.of(context).formatShortDate(date)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewNoteDialog extends StatefulWidget {
  const _NewNoteDialog({required this.templates});
  final TemplateRepository templates;
  @override
  State<_NewNoteDialog> createState() => _NewNoteDialogState();
}

class _NewNoteDialogState extends State<_NewNoteDialog> {
  final _title = TextEditingController(text: 'New note');
  String _paper = 'blank';
  final _lineColor = TextEditingController(text: 'DCE4EC');
  int? get _parsedLineColor =>
      RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(_lineColor.text.trim())
      ? int.parse(_lineColor.text.trim().replaceFirst('#', ''), radix: 16)
      : null;
  int? get _chosenLineColor =>
      _template == null && (_paper == 'lined' || _paper == 'grid')
      ? _parsedLineColor
      : 0xDCE4EC;
  NoteTemplate? _template;
  @override
  void dispose() {
    _title.dispose();
    _lineColor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('New note'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 16),
          if (_template == null)
            DropdownButtonFormField<String>(
              initialValue: _paper,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Note type / paper'),
              items: const [
                DropdownMenuItem(
                  value: 'markdown',
                  child: Text('Text note (Markdown)'),
                ),
                DropdownMenuItem(value: 'todo', child: Text('To-do list')),
                DropdownMenuItem(value: 'blank', child: Text('Blank')),
                DropdownMenuItem(value: 'lined', child: Text('Ruled')),
                DropdownMenuItem(value: 'grid', child: Text('Grid')),
              ],
              onChanged: (value) => setState(() => _paper = value!),
            ),
          if (_template == null && (_paper == 'lined' || _paper == 'grid'))
            TextField(
              controller: _lineColor,
              decoration: InputDecoration(
                labelText: 'Line color (hex)',
                errorText: _parsedLineColor == null
                    ? 'Enter six hexadecimal digits'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          if (_template != null)
            Text('${_template!.name} · ${_template!.pageCount} Pages'),
          TextButton.icon(
            onPressed: () async {
              final entry = await pickTemplate(context, widget.templates);
              if (mounted && entry != null) setState(() => _template = entry);
            },
            icon: const Icon(Icons.dashboard_customize_outlined),
            label: const Text('Choose template'),
          ),
          TextButton.icon(
            onPressed: () =>
                Navigator.pop(context, ('', 'media', null, 0xDCE4EC)),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Add media'),
          ),
          if (_template != null)
            TextButton(
              onPressed: () => setState(() => _template = null),
              child: const Text('Use standard paper'),
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
        onPressed: _chosenLineColor == null
            ? null
            : () => Navigator.pop(context, (
                _title.text.trim().isEmpty ? 'New note' : _title.text.trim(),
                _paper,
                _template,
                _chosenLineColor!,
              )),
        child: const Text('Create'),
      ),
    ],
  );
}

class _TitleDialog extends StatefulWidget {
  const _TitleDialog({required this.initial});
  final String initial;
  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  late final _text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Rename note'),
    content: TextField(
      controller: _text,
      autofocus: true,
      maxLength: 120,
      decoration: const InputDecoration(labelText: 'Title'),
      onChanged: (_) => setState(() {}),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _text.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}
