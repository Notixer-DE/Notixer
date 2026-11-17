import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../data/notebook.dart';
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
import 'markdown_editor.dart';
import 'template_library.dart';
import 'workspace_chrome.dart';
import 'sync_button.dart';
import 'document_tab.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.repository,
    this.syncController,
    this.onOpenNotebook,
    this.workspaceController,
    this.isNotebookOpen,
    this.hasOpenDocuments,
  });
  final LocalNotebookRepository repository;
  final SyncController? syncController;
  final Future<void> Function(Notebook)? onOpenNotebook;
  final LibraryWorkspaceController? workspaceController;
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
  final _scaffold = GlobalKey<ScaffoldState>();
  final _searchFocus = FocusNode();
  String? _error;
  bool _loading = true, _actionBusy = false;
  bool get _busy => _actionBusy || _sync.busy;
  bool get _hasOpenDocuments => widget.hasOpenDocuments?.call() ?? false;
  bool _isOpen(Notebook note) => widget.isNotebookOpen?.call(note.id) ?? false;
  @override
  void initState() {
    super.initState();
    widget.workspaceController?.refresh = _refresh;
    _sync.addListener(_syncChanged);
    _initializeSync();
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

  Future<void> _syncSettings() async {
    if (_hasOpenDocuments) return;
    await _perform(() async {
      await _sync.load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SyncPage(controller: _sync)),
      );
      await _refresh();
    }, autoSync: false);
  }

  @override
  void dispose() {
    widget.workspaceController?.refresh = null;
    _sync.removeListener(_syncChanged);
    if (widget.syncController == null) _sync.dispose();
    _previews.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await widget.repository.catalog.load();
      final notes = await widget.repository.list();
      if (mounted) {
        setState(() {
          _notes = notes;
          if (_tagFilter != null &&
              !notes.any((n) => n.tags.contains(_tagFilter))) {
            _tagFilter = null;
          }
          _loading = false;
          _error = widget.repository.readErrors.isEmpty
              ? widget.repository.catalog.loadWarning
              : 'Some note files could not be read: ${widget.repository.readErrors.join(', ')}';
        });
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
      final before = await _noteStates();
      if (!mounted) return;
      await action();
      if (autoSync && mounted) await _autoSync(before);
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

  Future<void> _open(Notebook note) async {
    if (widget.onOpenNotebook != null) {
      await widget.onOpenNotebook!(note);
      return;
    }
    final bytes = await widget.repository.load(note.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => note.isMarkdown
            ? MarkdownEditorPage(
                note: note,
                bytes: bytes,
                repository: widget.repository,
              )
            : EditorPage(
                note: note,
                bytes: bytes,
                repository: widget.repository,
              ),
      ),
    );
    await _refresh();
  }

  Future<void> _searchPdfs() => _perform(() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfSearchPage(
          notes: _notes.where((n) => !n.isMarkdown).toList(),
          repository: widget.repository,
        ),
      ),
    );
    await _refresh();
  });

  Future<void> _study() => _perform(() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudyPage(repository: widget.repository),
      ),
    );
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
    await _perform(() async {
      final template = choice.$3 == null
          ? null
          : await widget.repository.templates.instantiateEditable(
              choice.$3!.id,
            );
      var note =
          choice.$3 == null && ['markdown', 'checklist'].contains(choice.$2)
          ? await MarkdownLibrary(
              widget.repository,
            ).create(choice.$1, checklist: choice.$2 == 'checklist')
          : await widget.repository.create(
              choice.$1,
              template?.bytes ??
                  await createPaper(choice.$2, lineColor: choice.$4),
              paper: choice.$3 == null ? choice.$2 : 'pdf',
              lineColor: choice.$4,
            );
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

  Future<void> _import() => _perform(() async {
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
      await _open(imported.first);
      return;
    }
    final note = extension == '.md'
        ? await MarkdownLibrary(widget.repository).importText(file.name, bytes)
        : extension == '.noter'
        ? await widget.repository.importArchive(bytes)
        : await widget.repository.create(
            p.basenameWithoutExtension(file.name),
            bytes,
          );
    await _refresh();
    await _open(note);
  });
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

  Future<void> _delete(Notebook note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete note?'),
        content: Text(
          _sync.enabled
              ? '„${note.title}“will be moved to the local trash. The deletion will be synced to other devices on the next server sync.'
              : '„${note.title}“will be moved to the trash and can later be restored as a new copy.',
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
    );
    if (confirmed == true) {
      await _perform(() async {
        await widget.repository.delete(note.id);
        await _refresh();
      });
    }
  }

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
              _folderFilter == null ||
              (_folderFilter == ''
                  ? widget.repository.catalog.folderName(n.folderId) == null
                  : n.folderId == _folderFilter),
        )
        .where((n) => _tagFilter == null || n.tags.contains(_tagFilter))
        .where(
          (n) =>
              _kind == 'all' ||
              (_kind == 'markdown' && n.isMarkdown) ||
              (_kind == 'pdf' && n.paper == 'pdf') ||
              (_kind == 'notes' && !n.isMarkdown && n.paper != 'pdf'),
        )
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = NoterTheme.desktopControls(context);
        final phone = constraints.maxWidth < 600;
        return Scaffold(
          key: _scaffold,
          drawer: wide ? null : Drawer(child: SafeArea(child: _navigation())),
          appBar: AppBar(
            leadingWidth: DocumentTabsChrome.leadingWidth(context),
            leading: DocumentTabsChrome.action(context) == null
                ? null
                : DocumentNavigation(
                    child: wide
                        ? const SizedBox()
                        : IconButton(
                            tooltip: 'Open navigation menu',
                            icon: const Icon(Icons.menu),
                            onPressed: () =>
                                _scaffold.currentState?.openDrawer(),
                          ),
                  ),
            toolbarHeight: NoterTheme.headerHeight(context),
            title: const Row(
              children: [
                Icon(Icons.draw_outlined, color: NoterTheme.accent, size: 20),
                SizedBox(width: 8),
                Flexible(
                  child: Text('Notixer', overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            actions: [
              SyncButton(
                controller: _sync,
                disabled: _busy || _hasOpenDocuments,
                onSynchronized: _refresh,
                onOpenDetails: _syncSettings,
              ),
              if (!phone) ...[
                IconButton(
                  tooltip: _grid ? 'List view' : 'Grid view',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(
                    _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                  ),
                ),
                IconButton(
                  tooltip: 'Trash',
                  onPressed: _busy ? null : () => _recovery(),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: 'Search PDFs',
                  onPressed: _busy || !_notes.any((n) => !n.isMarkdown)
                      ? null
                      : _searchPdfs,
                  icon: const Icon(Icons.find_in_page_outlined),
                ),
                IconButton(
                  tooltip: _hasOpenDocuments
                      ? 'Close open tabs before syncing'
                      : 'Sync settings',
                  onPressed: _busy || _hasOpenDocuments ? null : _syncSettings,
                  icon: const Icon(Icons.cloud_sync_outlined),
                ),
                IconButton(
                  tooltip: 'Manage folders',
                  onPressed: _busy ? null : _folders,
                  icon: const Icon(Icons.folder_outlined),
                ),
                IconButton(
                  tooltip: 'Reload notes',
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 12),
              ] else
                PopupMenuButton<String>(
                  tooltip: 'Library actions',
                  onSelected: (value) {
                    if (value == 'import') _import();
                    if (value == 'pdf') _searchPdfs();
                    if (value == 'trash') _recovery();
                    if (value == 'refresh') _refresh();
                    if (value == 'templates') _templates();
                    if (value == 'view') setState(() => _grid = !_grid);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'view',
                      child: Text(_grid ? 'List view' : 'Grid view'),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      enabled: !_busy,
                      child: const Text('Import file'),
                    ),
                    PopupMenuItem(
                      value: 'pdf',
                      enabled: !_busy && _notes.isNotEmpty,
                      child: const Text('Search PDFs'),
                    ),
                    PopupMenuItem(
                      value: 'trash',
                      enabled: !_busy,
                      child: const Text('Trash'),
                    ),
                    PopupMenuItem(
                      value: 'templates',
                      enabled: !_busy,
                      child: const Text('Templates'),
                    ),
                    PopupMenuItem(
                      value: 'refresh',
                      enabled: !_busy,
                      child: const Text('Reload notes'),
                    ),
                  ],
                ),
            ],
          ),
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) SizedBox(width: 220, child: _navigation()),
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
                                  Wrap(
                                    spacing: 16,
                                    runSpacing: 12,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        _folderFilter == null
                                            ? 'My notes'
                                            : _folderFilter == ''
                                            ? 'Unfiled'
                                            : widget.repository.catalog
                                                      .folderName(
                                                        _folderFilter,
                                                      ) ??
                                                  'My notes',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      if (!phone) ...[
                                        OutlinedButton.icon(
                                          onPressed: _busy ? null : _import,
                                          icon: const Icon(
                                            Icons.file_open_outlined,
                                          ),
                                          label: const Text('Import file'),
                                        ),
                                        FilledButton.icon(
                                          onPressed: _busy ? null : _create,
                                          icon: const Icon(Icons.add),
                                          label: const Text('New note'),
                                        ),
                                      ],
                                      OutlinedButton.icon(
                                        onPressed: _busy ? null : _study,
                                        icon: const Icon(Icons.school_outlined),
                                        label: const Text('Study today'),
                                      ),
                                      if (!phone)
                                        OutlinedButton.icon(
                                          onPressed: _busy ? null : _templates,
                                          icon: const Icon(
                                            Icons.dashboard_customize_outlined,
                                          ),
                                          label: const Text('Templates'),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${visible.length} ${visible.length == 1 ? 'note' : 'notes'}'
                                    ' · Most recently modified first',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    focusNode: _searchFocus,
                                    decoration: const InputDecoration(
                                      hintText: 'Search notes',
                                      prefixIcon: Icon(Icons.search),
                                    ),
                                    onChanged: (value) =>
                                        setState(() => _query = value),
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final (id, label) in [
                                        ('all', 'All'),
                                        ('markdown', 'Text'),
                                        ('notes', 'Notebooks'),
                                        ('pdf', 'PDFs'),
                                      ])
                                        ChoiceChip(
                                          label: Text(label),
                                          selected: _kind == id,
                                          onSelected: (_) =>
                                              setState(() => _kind = id),
                                        ),
                                      if (_folderFilter != null ||
                                          _tagFilter != null ||
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
              ],
            ),
          ),
          floatingActionButton: phone
              ? FloatingActionButton(
                  tooltip: 'New note',
                  onPressed: _busy ? null : _create,
                  child: const Icon(Icons.add),
                )
              : null,
          bottomNavigationBar: phone
              ? NavigationBar(
                  selectedIndex: 0,
                  onDestinationSelected: (index) {
                    if (index == 0) {
                      setState(() {
                        _folderFilter = null;
                        _tagFilter = null;
                      });
                    }
                    if (index == 1) _scaffold.currentState?.openDrawer();
                    if (index == 2) _searchFocus.requestFocus();
                    if (index == 3 && !_busy) _syncSettings();
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.grid_view_outlined),
                      label: 'Notes',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.folder_outlined),
                      label: 'Folder',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: 'Search',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.cloud_sync_outlined),
                      label: 'Sync',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

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
    onManage: _folders,
    onTrash: () {
      _scaffold.currentState?.closeDrawer();
      _recovery();
    },
    onSync: () {
      _scaffold.currentState?.closeDrawer();
      _syncSettings();
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
    onSelected: (value) => value == 'rename'
        ? _rename(note)
        : value == 'organize'
        ? _organize(note)
        : value == 'history'
        ? _recovery(note: note)
        : _delete(note),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'rename', child: Text('Rename')),
      PopupMenuItem(value: 'organize', child: Text('Folders and tags')),
      PopupMenuItem(value: 'history', child: Text('Version history')),
      PopupMenuItem(value: 'delete', child: Text('Delete')),
    ],
  );

  Widget _noteRow(Notebook note, {required bool compact}) {
    final date = note.modified.toLocal();
    final organization = [
      if (note.folderId != null)
        widget.repository.catalog.folderName(note.folderId) ?? 'Unfiled',
      ...note.tags.map((tag) => '#$tag'),
    ].join(' · ');
    final type = note.isMarkdown
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
      shape: const RoundedRectangleBorder(),
      child: InkWell(
        onTap: _busy ? null : () => _perform(() => _open(note)),
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
                  note.isMarkdown
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
              _noteActions(note),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noteCard(Notebook note, {required bool compact}) {
    final date = note.modified.toLocal();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : () => _perform(() => _open(note)),
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
                Positioned(top: 4, right: 4, child: _noteActions(note)),
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
                DropdownMenuItem(value: 'checklist', child: Text('Checklist')),
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
