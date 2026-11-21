import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../data/document_task.dart';
import '../data/file_gateway.dart';
import '../data/knowledge.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/library_backup.dart';
import '../data/notebook.dart';
import '../data/quick_todos.dart';
import '../data/markdown_document.dart';
import 'journal_calendar.dart';
import 'journal_template_dialog.dart';
import 'markdown_editor.dart';
import 'noter_theme.dart';
import 'plan_todo_dialog.dart';
import 'quick_todo_dialog.dart';
import 'workspace_chrome.dart';
import 'todo_timer.dart';
import 'task_row_actions.dart';
import 'inbox_capture_dialog.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    required this.repository,
    this.initialSection = 'Search',
    this.sharedText,
    this.onChangeTask,
    this.autofocusSearch = false,
    this.shortcuts,
    this.onImportFile,
    this.onQuickTodo,
    this.onTaskPlanned,
    this.onQuickTodosChanged,
    this.onJournalChanged,
    this.embedded = false,
    this.active = true,
    this.onOpenDestination,
    this.taskView,
    this.request = 0,
    this.revision = 0,
    this.savedView,
    this.onUseSavedView,
    this.onNotebookTemplates,
    this.onRecoverMedia,
    this.onOpenViews,
    this.onOpenGraph,
    this.addJournalEntry = false,
    this.showToday = false,
    this.onManageTemplates,
  });
  final LocalNotebookRepository repository;
  final String initialSection;
  final String? sharedText;
  final Future<KnowledgeTask?> Function(KnowledgeTask)? onChangeTask;
  final bool autofocusSearch;
  final KeyboardShortcuts? shortcuts;
  final Future<void> Function(VoidCallback onImported)? onImportFile;
  final Future<bool> Function()? onQuickTodo;
  final Future<void> Function(Notebook)? onTaskPlanned;
  final Future<void> Function()? onQuickTodosChanged;
  final Future<void> Function(Notebook?)? onJournalChanged;
  final bool embedded, active, addJournalEntry, showToday;
  final Future<void> Function(KnowledgeDestination)? onOpenDestination;
  final String? taskView;
  final int request, revision;
  final KnowledgeView? savedView;
  final ValueChanged<KnowledgeView>? onUseSavedView;
  final VoidCallback? onNotebookTemplates, onRecoverMedia;
  final VoidCallback? onOpenViews, onOpenGraph, onManageTemplates;
  @override
  State<KnowledgePage> createState() => KnowledgePageState();
}

enum _TaskView {
  today('Today'),
  unsorted('Unsorted'),
  projects('Projects'),
  all('All tasks'),
  completed('Completed');

  const _TaskView(this.label);
  final String label;
}

class KnowledgePageState extends State<KnowledgePage> {
  late final _store = KnowledgeStore(widget.repository);
  late final _backup = LibraryBackup(widget.repository);
  late String _section = widget.initialSection == unsortedTodos
      ? 'Tasks'
      : widget.initialSection;
  late _TaskView _taskView =
      _requestedTaskView ??
      (widget.initialSection == unsortedTodos
          ? _TaskView.unsorted
          : _TaskView.all);
  _TaskView? get _requestedTaskView => _TaskView.values
      .where((view) => view.name == widget.taskView)
      .firstOrNull;
  Future<MarkdownDocument>? _journalPreview;
  (String, DateTime)? _journalPreviewKey;
  String _projectFilter = '';
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  final _hubFocus = FocusNode();
  String _tag = '', _folder = '', _kind = 'all';
  bool? _filtersExpanded;
  bool _completedOnly = false;
  bool _completedAllTasksOnly = false;
  bool _onlyTasks = false,
      _busy = false,
      _searching = false,
      _cancelRequested = false;
  int _generation = 0, _completed = 0, _total = 0;
  String? _error, _backupStatus;
  KnowledgeScan? _scan;
  bool _scannedQuickTodosOnly = false;
  List<Notebook> _notes = [];
  List<File> _backups = [];
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  late DateTime _journalMonth = DateTime(_date.year, _date.month);
  bool get _taskSection => _section == 'Tasks';
  bool get _showCompletedTasks =>
      _taskView == _TaskView.completed ||
      (_taskView == _TaskView.all && _completedAllTasksOnly);
  bool get _fixedTag => _section == 'Inbox';
  bool get _autoSearch => _taskSection || _section == 'Inbox';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final savedView = widget.savedView;
      if (savedView != null) _applySavedView(savedView);
      await _load();
      if (!mounted) return;
      if (widget.sharedText != null) {
        await _capture(widget.sharedText!);
      }
      if (!mounted || !widget.active) return;
      if (widget.embedded && widget.autofocusSearch && savedView == null) {
        _searchFocus.requestFocus();
      }
      if (_autoSearch || savedView != null) await _search();
      if (mounted && widget.addJournalEntry) await _appendJournal();
    });
  }

  @override
  void didUpdateWidget(KnowledgePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final requested = oldWidget.request != widget.request;
    final revised = oldWidget.revision != widget.revision;
    final savedView = widget.savedView;
    final applyView = savedView != null && savedView != oldWidget.savedView;
    if (!widget.active ||
        (oldWidget.active && !requested && !revised && !applyView)) {
      return;
    }
    if (requested) {
      final view = _requestedTaskView;
      if (view != null) _taskView = view;
      if (widget.showToday) {
        _date = DateUtils.dateOnly(DateTime.now());
        _journalMonth = DateTime(_date.year, _date.month);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.active) return;
      if (applyView) _applySavedView(savedView);
      if (_section == 'Search' &&
          requested &&
          !applyView &&
          widget.autofocusSearch) {
        _searchFocus.requestFocus();
      }
      if (_section != 'Search' || _scan == null || revised || applyView) {
        await _reload();
      }
      if (mounted && applyView && _scan == null) await _search();
      if (mounted && widget.active && requested && widget.addJournalEntry) {
        await _appendJournal();
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _searchFocus.dispose();
    _hubFocus.dispose();
    super.dispose();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _work(() async {
    await _store.reload();
    await widget.repository.catalog.load();
    final notes = await widget.repository.list();
    final backups = await _backup.list();
    String? backupStatus;
    final statusFile = File('${_backup.directory.path}/status.json');
    if (await statusFile.exists()) {
      try {
        final status =
            jsonDecode(await statusFile.readAsString()) as Map<String, dynamic>;
        backupStatus = status['error'] == null
            ? 'Last automatic backup: ${status['lastSuccess']}'
            : 'Automatic backup failed: ${status['error']}';
      } catch (_) {
        backupStatus = 'Could not read automatic backup status.';
      }
    }
    if (mounted) {
      setState(() {
        _notes = notes;
        _backups = backups;
        _backupStatus = backupStatus;
      });
    }
  });

  Future<void> _reload() async {
    final refreshResults = _scan != null || _autoSearch;
    await _load();
    if (mounted && _error == null && refreshResults) {
      await _search(keepResults: true);
    }
  }

  KnowledgeView get _view => KnowledgeView(
    '',
    query: _query.text.trim(),
    tag: _fixedTag ? _section : _tag,
    folder: _folder,
    kind: _kind,
    openTasks: _taskSection
        ? !_showCompletedTasks
        : _section == 'Search' && _onlyTasks,
    completedTasks: _taskSection
        ? _showCompletedTasks
        : _section == 'Search' && _completedOnly,
  );
  void submitSearch() => unawaited(_search());

  Future<void> _search({bool keepResults = false}) async {
    if (_busy) return;
    final generation = ++_generation;
    final onlyQuickTodos =
        _taskSection &&
        _taskView != _TaskView.all &&
        _taskView != _TaskView.completed;
    setState(() {
      _busy = true;
      _error = null;
      if (!keepResults) _scan = null;
      _searching = true;
      _cancelRequested = false;
      _completed = 0;
      _total = 0;
    });
    try {
      final result = await _store.scan(
        _view,
        onlyQuickTodos: onlyQuickTodos,
        includeCompletedTasks:
            widget.embedded && _section == 'Search' && !_view.tasksOnly,
        cancelled: () =>
            !mounted || generation != _generation || _cancelRequested,
        onProgress: (done, total) {
          if (mounted && generation == _generation) {
            setState(() {
              _completed = done;
              _total = total;
            });
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() {
          _scan = result;
          _scannedQuickTodosOnly = onlyQuickTodos;
          if (_cancelRequested) {
            _error = 'Search cancelled; partial results are shown.';
          }
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _searching = false;
        });
      }
    }
  }

  void _open(Notebook note, [String anchor = '']) {
    final destination = (note: note, anchor: anchor);
    if (widget.onOpenDestination case final open?) {
      unawaited(open(destination));
    } else {
      Navigator.pop(context, destination);
    }
  }

  Future<String?> _name(
    String title, {
    String initial = '',
    String? helper,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          controller: controller,
          decoration: InputDecoration(labelText: 'Name', helperText: helper),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return value;
  }

  Future<void> _capture([String initial = '']) async {
    final value = await showInboxCaptureDialog(context, initial: initial);
    if (value != null && mounted) {
      await _work(() async {
        final note = await _store.capture(value.$1, value.$2);
        if (mounted) _open(note, 'edit:end');
      });
    }
  }

  Future<void> _template([MarkdownTemplate? template]) async {
    final name = TextEditingController(text: template?.name),
        source = TextEditingController(text: template?.source);
    final value = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          template == null
              ? 'Create Markdown template'
              : 'Edit Markdown template',
        ),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Template name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: source,
                minLines: 8,
                maxLines: 18,
                decoration: const InputDecoration(
                  labelText: 'Markdown',
                  helperText: '{{date}} · {{weekday}} · {{year}} · {{title}}',
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
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(context, (name.text.trim(), source.text));
              }
            },
            child: const Text('Save template'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    source.dispose();
    if (value != null && mounted) {
      await _work(() async {
        final updated = MarkdownTemplate(
          template?.id ?? LocalNotebookRepository.newId(),
          value.$1,
          value.$2,
        );
        _store.templates = [
          ..._store.templates.where((t) => t.id != updated.id),
          updated,
        ];
        await _store.save();
      });
    }
  }

  Future<void> _saveView() async {
    final name = await _name('Save search view');
    if (name == null || name.isEmpty || !mounted) return;
    final view = _view;
    await _work(() async {
      _store.views = [
        ..._store.views.where((v) => v.name != name),
        KnowledgeView(
          name,
          query: view.query,
          tag: view.tag,
          folder: view.folder,
          kind: view.kind,
          openTasks: view.openTasks,
          completedTasks: view.completedTasks,
        ),
      ];
      await _store.save();
    });
  }

  Future<void> _changeTask(KnowledgeTask task) async {
    if (_busy) return;
    await _work(() async {
      if (task.quickTodo != null) {
        await _store.changeTask(task);
        if (mounted) await widget.onQuickTodosChanged?.call();
        return;
      }
      if (!await FileGateway.prepareClose()) {
        throw const FormatException(
          'Save open documents before changing a task.',
        );
      }
      await (widget.onChangeTask ?? _store.changeTask)(task);
    });
    if (mounted && _error == null) await _search(keepResults: true);
  }

  Future<void> _syncTimerEdit() async {
    try {
      await widget.onQuickTodosChanged?.call();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not sync task changes: $error');
      }
    }
  }

  ChangeTodoTimer _timerUpdate(KnowledgeTask task) {
    final location = '${task.note.id}:${task.anchor}';
    var current = task;
    return ({timer, workTime, countdown}) async {
      QuickTodo? updated;
      if (current.quickTodo case final quickTodo?) {
        updated = await _store.changeQuickTodoTimer(
          quickTodo.id,
          timer: timer,
          workTime: workTime,
          countdown: countdown,
        );
        current = current.afterQuickTodoTimerEdit(updated);
        if (mounted) unawaited(_syncTimerEdit());
      } else {
        final documentTask = await (widget.onChangeTask ?? _store.changeTask)(
          current.withTimer(
            timer: timer,
            workTime: workTime,
            countdown: countdown,
          ),
        );
        if (documentTask == null) {
          throw StateError('Could not save the task timer.');
        }
        current = documentTask;
        updated = current.todo;
      }
      if (mounted) setState(() => _scan?.tasksByLocation[location] = current);
      return updated;
    };
  }

  Future<void> _quickTodo() async {
    final added =
        await (widget.onQuickTodo?.call() ??
            showQuickTodoDialog(context, widget.repository));
    if (!mounted || !added) return;
    if (widget.onQuickTodo == null) await widget.onQuickTodosChanged?.call();
    if (!mounted) return;
    if (widget.embedded) {
      await _reload();
    } else {
      _selectSection(unsortedTodos);
    }
  }

  Future<void> _planTodo(KnowledgeTask task) async {
    final plan = await showDialog<TodoPlan>(
      context: context,
      builder: (_) => PlanTodoDialog(
        task: task,
        folders: widget.repository.catalog.folders,
      ),
    );
    if (!mounted || plan == null) return;
    await _work(() async {
      if (task.quickTodo == null && !await FileGateway.prepareClose()) {
        throw const FormatException(
          'Save open documents before changing a task.',
        );
      }
      final note = await _store.planQuickTodo(
        task,
        projectId: plan.projectId,
        newProject: plan.newProject,
        due: plan.due,
        text: plan.text,
      );
      if (!mounted) return;
      if (note == null) {
        await widget.onQuickTodosChanged?.call();
      } else {
        await FileGateway.refreshOpenDocuments?.call();
        if (mounted) await widget.onTaskPlanned?.call(note);
      }
    });
    if (mounted && _error == null) await _search();
  }

  List<KnowledgeHit> _taskHits(KnowledgeScan scan, String today) {
    if (!_taskSection ||
        _taskView == _TaskView.all ||
        _taskView == _TaskView.completed) {
      return scan.hits;
    }
    final catalog = widget.repository.catalog;
    final selected = catalog.folderName(_projectFilter) == null
        ? ''
        : _projectFilter;
    final hits = scan.hits.where((hit) {
      final task = scan.tasksByLocation['${hit.note.id}:${hit.anchor}'];
      if (task?.canPlan != true) return false;
      final project = catalog.folderName(hit.note.folderId);
      return switch (_taskView) {
        _TaskView.unsorted => project == null,
        _TaskView.projects =>
          project != null &&
              (selected.isEmpty || hit.note.folderId == selected),
        _TaskView.today => switch (task!.due) {
          final String due => due.compareTo(today) <= 0,
          null => false,
        },
        _TaskView.all || _TaskView.completed => true,
      };
    }).toList();
    if (_taskView == _TaskView.today) {
      hits.sort((a, b) {
        final date = scan.tasksByLocation['${a.note.id}:${a.anchor}']!.due!
            .compareTo(scan.tasksByLocation['${b.note.id}:${b.anchor}']!.due!);
        return date == 0 ? b.note.modified.compareTo(a.note.modified) : date;
      });
    }
    return hits;
  }

  Widget _taskViews() => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final view in _TaskView.values)
        ChoiceChip(
          key: ValueKey('task-view-${view.name}'),
          label: Text(view.label),
          selected: view == _taskView,
          onSelected: _busy
              ? null
              : (_) {
                  if (view == _taskView) return;
                  final wasCompleted = _showCompletedTasks;
                  setState(() => _taskView = view);
                  if (wasCompleted != _showCompletedTasks ||
                      ((view == _TaskView.all || view == _TaskView.completed) &&
                          _scannedQuickTodosOnly)) {
                    unawaited(_search());
                  }
                },
        ),
    ],
  );

  String? _taskDetails(KnowledgeHit hit, KnowledgeTask? task, String today) {
    final source =
        '${hit.note.title}${hit.anchor.startsWith('line=')
            ? ' · Line ${hit.anchor.substring(5)}'
            : hit.anchor.startsWith('page=')
            ? ' · Page ${hit.anchor.substring(5)}'
            : ''}';
    if (task?.canPlan != true) {
      final completed = task?.todo?.completionTime;
      return completed == null
          ? source
          : '$source · ${completedTaskLabel(context, completed)}';
    }
    final project = widget.repository.catalog.folderName(hit.note.folderId);
    final due = task!.due;
    final details = [
      if (hit.note.title != hit.snippet) hit.note.title,
      ?project,
      if (task.todo?.completionTime case final completed?)
        completedTaskLabel(context, completed),
      if (due != null)
        '${due.compareTo(today) < 0 ? 'Overdue' : 'Due'} · '
            '${MaterialLocalizations.of(context).formatMediumDate(DateTime.parse(due))}',
    ];
    return details.isEmpty ? null : details.join(' · ');
  }

  Widget _results() {
    final scan = _scan;
    final today = journalDate(DateTime.now());
    final hits = scan == null ? const <KnowledgeHit>[] : _taskHits(scan, today);
    final taskIndices = <(String, String), int>{
      if (_view.tasksOnly)
        for (var i = 0; i < hits.length; i++)
          (hits[i].note.id, hits[i].anchor): i,
    };
    final filtersVisible =
        _filtersExpanded ?? NoterTheme.desktopControls(context);
    final activeFilters = [
      _kind != 'all',
      !_fixedTag && _tag.isNotEmpty,
      _folder.isNotEmpty,
      _section == 'Search' && (_onlyTasks || _completedOnly),
      _taskSection && _taskView == _TaskView.all && _completedAllTasksOnly,
    ].where((value) => value).length;
    return CustomScrollView(
      key: PageStorageKey('knowledge-results-$_section'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    if (_taskSection) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _taskViews(),
                      ),
                      const SizedBox(height: 8),
                      if (_taskView == _TaskView.projects)
                        DropdownButton<String>(
                          isExpanded: true,
                          value:
                              widget.repository.catalog.folderName(
                                    _projectFilter,
                                  ) ==
                                  null
                              ? ''
                              : _projectFilter,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('All projects'),
                            ),
                            for (final folder
                                in widget.repository.catalog.folders)
                              DropdownMenuItem(
                                value: folder.id,
                                child: Text(
                                  folder.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) =>
                                    setState(() => _projectFilter = value!),
                        ),
                    ],
                    TextField(
                      controller: _query,
                      focusNode: _searchFocus,
                      autofocus: widget.autofocusSearch && _section == 'Search',
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        labelText: switch (_section) {
                          'Tasks' => 'Find an open task or file',
                          'Inbox' => 'Search the inbox',
                          _ =>
                            widget.embedded
                                ? 'Search titles, text and tasks'
                                : 'Search Markdown and PDFs',
                        },
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: filtersVisible
                                  ? 'Hide search filters'
                                  : 'Show search filters',
                              isSelected: filtersVisible,
                              onPressed: _busy
                                  ? null
                                  : () => setState(
                                      () => _filtersExpanded = !filtersVisible,
                                    ),
                              icon: Badge(
                                isLabelVisible: activeFilters > 0,
                                label: Text('$activeFilters'),
                                child: const Icon(Icons.filter_alt_outlined),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Search',
                              onPressed: _busy ? null : _search,
                              icon: const Icon(Icons.search),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (filtersVisible) const SizedBox(height: 8),
                    if (filtersVisible)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<String>(
                            value: _kind,
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('All files'),
                              ),
                              DropdownMenuItem(
                                value: 'markdown',
                                child: Text('Markdown'),
                              ),
                              DropdownMenuItem(
                                value: 'pdf',
                                child: Text('PDFs'),
                              ),
                              DropdownMenuItem(
                                value: 'media',
                                child: Text('Media'),
                              ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _kind = v!),
                          ),
                          if (!_fixedTag)
                            DropdownButton<String>(
                              value: _tag,
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('All tags'),
                                ),
                                for (final tag in {
                                  ..._notes
                                      .expand((n) => n.tags)
                                      .where((tag) => tag.isNotEmpty),
                                  if (_tag.isNotEmpty) _tag,
                                }.toList()..sort())
                                  DropdownMenuItem(
                                    value: tag,
                                    child: SizedBox(
                                      width: 100,
                                      child: Text(
                                        tag,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _tag = v!),
                            ),
                          DropdownButton<String>(
                            value: _folder,
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('All folders'),
                              ),
                              for (final folder
                                  in widget.repository.catalog.folders)
                                DropdownMenuItem(
                                  value: folder.id,
                                  child: SizedBox(
                                    width: 110,
                                    child: Text(
                                      folder.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              if (_folder.isNotEmpty &&
                                  widget.repository.catalog.folderName(
                                        _folder,
                                      ) ==
                                      null)
                                DropdownMenuItem(
                                  value: _folder,
                                  child: const SizedBox(
                                    width: 110,
                                    child: Text(
                                      'Unavailable folder',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _folder = v!),
                          ),
                          if (_section == 'Search' ||
                              (_taskSection && _taskView == _TaskView.all))
                            DropdownButton<String>(
                              value: _taskSection
                                  ? (_completedAllTasksOnly
                                        ? 'completed'
                                        : 'open')
                                  : _completedOnly
                                  ? 'completed'
                                  : _onlyTasks
                                  ? 'open'
                                  : '',
                              items: [
                                if (!_taskSection)
                                  const DropdownMenuItem(
                                    value: '',
                                    child: Text('Any result'),
                                  ),
                                const DropdownMenuItem(
                                  value: 'open',
                                  child: Text('Open tasks only'),
                                ),
                                const DropdownMenuItem(
                                  value: 'completed',
                                  child: Text('Completed tasks only'),
                                ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (value) {
                                      setState(() {
                                        if (_taskSection) {
                                          _completedAllTasksOnly =
                                              value == 'completed';
                                        } else {
                                          _onlyTasks = value == 'open';
                                          _completedOnly = value == 'completed';
                                        }
                                      });
                                      if (_taskSection) unawaited(_search());
                                    },
                            ),

                          if (!_taskSection || _taskView == _TaskView.all)
                            OutlinedButton(
                              onPressed: _busy ? null : _saveView,
                              child: const Text('Save view'),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              if (widget.embedded &&
                  _section == 'Search' &&
                  scan == null &&
                  !_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'PDF content is searchable when the file contains a text layer.',
                  ),
                ),
              if (_searching) Text('Scanning $_completed / $_total files…'),
              if (scan != null && scan.warnings.isNotEmpty)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Search warnings'),
                      content: SizedBox(
                        width: 400,
                        height: 260,
                        child: ListView(
                          children: [
                            for (final warning in scan.warnings)
                              ListTile(title: Text(warning)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: Text('${scan.warnings.length} indexing warnings'),
                ),
            ],
          ),
        ),
        if (scan == null || hits.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                scan == null
                    ? (_section == 'Tasks'
                          ? 'Search to collect open checkboxes from every Markdown file.'
                          : 'Enter text, or leave it empty to list all matching files.')
                    : _taskSection && _view.query.isEmpty
                    ? switch (_taskView) {
                        _TaskView.unsorted => 'No open unsorted to-dos.',
                        _TaskView.today =>
                          'No open to-dos due today or overdue.',
                        _TaskView.projects => 'No open project to-dos.',
                        _TaskView.all when _completedAllTasksOnly =>
                          'No completed tasks.',
                        _TaskView.all => 'No matches.',
                        _TaskView.completed => 'No completed tasks.',
                      }
                    : 'No matches.',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: hits.length,
            findChildIndexCallback: (key) => key is ValueKey<(String, String)>
                ? taskIndices[key.value]
                : null,
            itemBuilder: (context, index) {
              final hit = hits[index];
              final task = scan.tasksByLocation['${hit.note.id}:${hit.anchor}'];
              final taskResult =
                  task != null && (_view.tasksOnly || widget.embedded);
              final details = _taskDetails(
                hit,
                taskResult ? task : null,
                today,
              );
              final row = ListTile(
                leading: _view.tasksOnly && task != null
                    ? Checkbox(
                        value: task.done,
                        onChanged: _busy ? null : (_) => _changeTask(task),
                      )
                    : Icon(
                        taskResult
                            ? Icons.checklist
                            : hit.note.isMedia
                            ? Icons.perm_media_outlined
                            : hit.note.isMarkdown
                            ? Icons.description_outlined
                            : Icons.picture_as_pdf_outlined,
                      ),
                title: Text(
                  hit.snippet.trim().isEmpty ? '(Empty task)' : hit.snippet,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: !widget.embedded || _taskSection
                    ? (details == null
                          ? null
                          : Text(
                              details,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ))
                    : Text(
                        [
                          if (taskResult)
                            'Task'
                          else if (hit.note.isTodoList)
                            'To-do list'
                          else if (hit.note.isMarkdown)
                            'Markdown'
                          else if (hit.note.isPdf)
                            'PDF'
                          else
                            'Media',
                          if (details != null && details.isNotEmpty) details,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: _view.tasksOnly && task != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (task.todo case final todo?)
                            TodoTimer(
                              todo: todo,
                              directStart: widget.embedded,
                              onChanged: _busy ? null : _timerUpdate(task),
                              onTimerClosed: task.quickTodo == null
                                  ? () => _search(keepResults: true)
                                  : null,
                            ),
                          if (widget.embedded)
                            PopupMenuButton<String>(
                              tooltip: 'Task actions',
                              enabled: !_busy,
                              onSelected: (action) => switch (action) {
                                'source' => _open(hit.note, hit.anchor),
                                'plan' => unawaited(_planTodo(task)),
                                _ => unawaited(_changeTask(task.forDeletion())),
                              },
                              itemBuilder: (_) => [
                                if (task.quickTodo == null)
                                  const PopupMenuItem(
                                    value: 'source',
                                    child: Text('Open source'),
                                  ),
                                if (task.canPlan && !task.done)
                                  const PopupMenuItem(
                                    value: 'plan',
                                    child: Text('Plan to-do'),
                                  ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete to-do'),
                                ),
                              ],
                            )
                          else if (task.canPlan && !task.done)
                            IconButton(
                              tooltip: 'Plan to-do',
                              onPressed: _busy ? null : () => _planTodo(task),
                              icon: const Icon(Icons.edit_calendar_outlined),
                            ),
                        ],
                      )
                    : null,
                onTap: _busy
                    ? null
                    : task?.quickTodo != null
                    ? task!.quickTodo!.done
                          ? null
                          : () => _planTodo(task)
                    : () => _open(hit.note, hit.anchor),
              );
              return task == null || !_view.tasksOnly
                  ? row
                  : TaskRowActions(
                      key: ValueKey((hit.note.id, hit.anchor)),
                      onDelete: _busy
                          ? null
                          : () => _changeTask(task.forDeletion()),
                      child: row,
                    );
            },
          ),
      ],
    );
  }

  Future<void> _showJournalNote(Notebook note, {String anchor = ''}) async {
    if (widget.onOpenDestination case final open?) {
      await open((note: note, anchor: anchor));
      return;
    }
    await _work(() async {
      if (!await FileGateway.prepareClose() || !mounted) return;
      final bytes = await widget.repository.load(note.id);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final route = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => MarkdownEditorPage(
            note: note,
            bytes: bytes,
            repository: widget.repository,
            initialAnchor: anchor,
            backLabel: 'Back to journal',
            onQuickTodosChanged: widget.onQuickTodosChanged,
            onJournalChanged: widget.onJournalChanged,
            onLibrary: () async => Navigator.pop(context, true),
          ),
        ),
      );
      if (!mounted) return;
      await FileGateway.refreshOpenDocuments?.call();
      if (route == true && mounted) await widget.onJournalChanged?.call(note);
      final notes = await widget.repository.list();
      if (mounted) setState(() => _notes = notes);
    });
  }

  Future<void> _createJournalPage() async {
    final day = _date;
    Notebook? note;
    await _work(() async {
      if (!await FileGateway.prepareClose() || !mounted || !widget.active) {
        return;
      }
      note = await _store.journal(day);
      final notes = await widget.repository.list();
      if (mounted) setState(() => _notes = notes);
    });
    if (mounted && widget.active && note != null) {
      await _showJournalNote(note!, anchor: 'edit:end');
    }
  }

  Future<void> _appendJournal() async {
    if (!await FileGateway.prepareClose() || !mounted) return;
    final day = _date;
    final note = await showDialog<Notebook>(
      context: context,
      builder: (_) => _JournalEntryDialog(
        date: day,
        onSave: (text, id, at) =>
            _store.appendJournal(day, text, entryId: id, recordedAt: at),
      ),
    );
    if (note == null || !mounted) return;
    await FileGateway.refreshOpenDocuments?.call();
    await _load();
    if (mounted) await widget.onJournalChanged?.call(note);
  }

  Future<void> _journalSettings() async {
    final selection = await showDialog<(String, String)>(
      context: context,
      builder: (_) => JournalTemplateDialog(
        templates: _store.templates,
        templateId: _store.journalTemplate,
        date: _date,
      ),
    );
    if (selection == null || !mounted) return;
    await _work(() async {
      await _store.reload();
      final (id, source) = selection;
      if (source.trim().isEmpty) {
        _store.journalTemplate = null;
      } else {
        final template = _store.templates
            .where((entry) => entry.id == id)
            .firstOrNull;
        final updated = MarkdownTemplate(
          template?.id ?? LocalNotebookRepository.newId(),
          template?.name ?? 'Custom journal',
          source,
        );
        _store.templates = [
          for (final entry in _store.templates)
            entry.id == updated.id ? updated : entry,
          if (template == null) updated,
        ];
        _store.journalTemplate = updated.id;
      }
      await _store.save();
      if (mounted) await widget.onJournalChanged?.call(null);
    });
  }

  Widget _journal() {
    final byDay = <String, Notebook>{};
    for (final note in _notes) {
      final day = journalEntryDate(note);
      if (day == null) continue;
      if (note.id == 'journal-$day' || !byDay.containsKey(day)) {
        byDay[day] = note;
      }
    }
    final selectedNote = byDay[journalDate(_date)];
    void selectDay(DateTime day) {
      setState(() {
        _date = day;
        _journalMonth = DateTime(day.year, day.month);
      });
      final note = byDay[journalDate(day)];
      if (note != null && !widget.embedded) unawaited(_showJournalNote(note));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => selectDay(DateUtils.dateOnly(DateTime.now())),
              icon: const Icon(Icons.today_outlined),
              label: const Text('Today'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _journalSettings,
              icon: const Icon(Icons.tune),
              label: const Text('Journal template'),
            ),
            if (widget.onManageTemplates case final manage?)
              TextButton(
                onPressed: manage,
                child: const Text('Manage templates'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final calendar = JournalCalendar(
              month: _journalMonth,
              selected: _date,
              entryDays: byDay.keys.toSet(),
              onMonth: _busy
                  ? null
                  : (month) => setState(() => _journalMonth = month),
              onDay: _busy ? null : selectDay,
            );
            final details = Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    MaterialLocalizations.of(context).formatFullDate(_date),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (selectedNote == null)
                    const Text('No journal entry for this day.')
                  else
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _showJournalNote(selectedNote),
                      icon: const Icon(Icons.description_outlined),
                      label: Text(selectedNote.title),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (selectedNote == null)
                        FilledButton.icon(
                          onPressed: _busy ? null : _createJournalPage,
                          icon: const Icon(Icons.note_add_outlined),
                          label: const Text('Create journal page'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _appendJournal,
                        icon: const Icon(Icons.add),
                        label: const Text('Add entry'),
                      ),
                    ],
                  ),
                ],
              ),
            );
            if (constraints.maxWidth < 680 ||
                MediaQuery.textScalerOf(context).scale(14) > 21) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [calendar, const Divider(height: 32), details],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: calendar),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      details,
                      if (widget.embedded && selectedNote != null)
                        _journalDetail(selectedNote),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _journalDetail(Notebook note) {
    final key = (note.id, note.modified);
    if (_journalPreviewKey != key) {
      _journalPreviewKey = key;
      _journalPreview = widget.repository
          .load(note.id)
          .then(decodeMarkdownAsync);
    }
    return FutureBuilder<MarkdownDocument>(
      future: _journalPreview,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('Could not load the entry.');
        final document = snapshot.data;
        if (document == null) return const LinearProgressIndicator();
        final source = document.source;
        const limit = 2400;
        final cutoff = source.length <= limit
            ? -1
            : source.lastIndexOf('\n', limit);
        final excerpt = source.length <= limit
            ? source
            : cutoff > 0
            ? '${source.substring(0, cutoff)}…'
            : '${visibleTaskText(source.split('\n').first).characters.take(limit)}…';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              inlineSyntaxes: [TaskMetadataSyntax()],
              data: excerpt,
              imageBuilder: (_, _, alt) => Text(alt ?? 'Attachment'),
            ),
          ),
        );
      },
    );
  }

  Widget _templates() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (widget.onNotebookTemplates case final manage?)
        ListTile(
          leading: const Icon(Icons.picture_as_pdf_outlined),
          title: const Text('PDF and notebook templates'),
          trailing: const Icon(Icons.chevron_right),
          onTap: manage,
        ),
      ListTile(
        title: const Text('Reusable Markdown templates'),

        trailing: IconButton(
          tooltip: 'Create Markdown template',
          onPressed: _busy ? null : () => _template(),
          icon: const Icon(Icons.add),
        ),
      ),
      for (final template in _store.templates)
        ListTile(
          title: Text(template.name),
          subtitle: Text(
            template.source,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _template(template),
          trailing: IconButton(
            tooltip: 'Delete template',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    _store.templates.removeWhere((t) => t.id == template.id);
                    if (_store.journalTemplate == template.id) {
                      _store.journalTemplate = null;
                    }
                    await _store.save();
                  }),
          ),
        ),
    ],
  );
  Widget _tags() {
    final tags = <String, (String, int)>{};
    for (final note in _notes) {
      final unique = <String, String>{
        for (final tag
            in note.tags
                .map((tag) => tag.trim())
                .where((tag) => tag.isNotEmpty))
          tag.toLowerCase(): tag,
      };
      for (final tag in unique.values) {
        final key = tag.toLowerCase();
        tags[key] = (tags[key]?.$1 ?? tag, (tags[key]?.$2 ?? 0) + 1);
      }
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Rename a tag or merge it into an existing tag. Leave the new name empty to remove that tag from all files.',
        ),
        for (final entry in tags.entries)
          ListTile(
            title: Text('#${entry.value.$1}'),
            subtitle: Text('${entry.value.$2} files'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy
                ? null
                : () async {
                    final value = await _name(
                      'Rename or merge tag',
                      initial: entry.value.$1,
                      helper: 'Empty name removes the tag.',
                    );
                    if (value == null || !mounted) return;
                    await _work(() async {
                      if (!await FileGateway.prepareClose()) {
                        throw const FormatException(
                          'Could not save open files.',
                        );
                      }
                      await _store.renameTag(entry.value.$1, value);
                      _notes = await widget.repository.list();
                      if (_tag.toLowerCase() == entry.value.$1.toLowerCase()) {
                        _tag = value;
                      }
                    });
                  },
          ),
      ],
    );
  }

  void _applySavedView(KnowledgeView view) {
    _section = 'Search';
    _query.text = view.query;
    _tag = view.tag;
    _kind = view.kind;
    _folder = view.folder;
    _onlyTasks = view.openTasks;
    _completedOnly = view.completedTasks;
  }

  Widget _views() => ListView(
    children: [
      if (_store.views.isEmpty)
        const ListTile(
          title: Text('Saved search views'),
          subtitle: Text(
            'Save combinations of text, type, folder, tag and open-task filters from Search.',
          ),
        ),
      for (final view in _store.views)
        ListTile(
          title: Text(view.name),
          subtitle: Text(
            [
              view.query,
              view.tag,
              view.kind,
              if (view.completedTasks)
                'Completed tasks'
              else if (view.openTasks)
                'Open tasks',
            ].where((v) => v.isNotEmpty).join(' · '),
          ),
          onTap: _busy
              ? null
              : () {
                  if (widget.onUseSavedView case final use?) {
                    use(view);
                  } else {
                    setState(() => _applySavedView(view));
                    _search();
                  }
                },
          trailing: IconButton(
            tooltip: 'Delete saved view',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    _store.views.remove(view);
                    await _store.save();
                  }),
          ),
        ),
    ],
  );
  Widget _backupPage() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (widget.onRecoverMedia case final recover?)
        ListTile(
          leading: const Icon(Icons.perm_media_outlined),
          title: const Text('Recover media capture'),
          onTap: recover,
        ),
      if (_backupStatus != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_backupStatus!),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          tooltip: 'About backups',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Library backups'),
              content: const SingleChildScrollView(
                child: Text(
                  'Keep the latest seven local snapshots. Export copies to separate storage to protect against device loss. Restore adds copies and preserves existing notes. Library snapshots support up to 512 MB.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
      SwitchListTile(
        title: const Text('Automatic backups'),
        subtitle: const Text(
          'While the app is running, every 15 minutes when the library changes.',
        ),
        value: _store.automaticBackups,
        onChanged: _busy
            ? null
            : (v) => _work(() async {
                _store.automaticBackups = v;
                await _store.save();
              }),
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy
                ? null
                : () => _work(() async {
                    if (!await FileGateway.prepareClose()) {
                      throw const FormatException('Could not save open files.');
                    }
                    await _backup.create();
                    _backups = await _backup.list();
                  }),
            child: const Text('Create backup'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _work(() async {
                    final file = await FileGateway().pick();
                    if (file == null) return;
                    if (await file.length() > LibraryBackup.maxBytes) {
                      throw const FormatException('Backup exceeds 512 MB.');
                    }
                    final notes = await _backup.restore(
                      await file.readAsBytes(),
                    );
                    await _store.reload();
                    _notes = await widget.repository.list();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            notes.isEmpty
                                ? 'Restored library data.'
                                : 'Restored library data and ${notes.length} file copies.',
                          ),
                        ),
                      );
                    }
                  }),
            child: const Text('Restore backup as copies'),
          ),
        ],
      ),
      for (final file in _backups)
        ListTile(
          title: Text(file.uri.pathSegments.last),
          trailing: IconButton(
            tooltip: 'Export backup',
            icon: const Icon(Icons.save_alt),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    await FileGateway().save(
                      file.uri.pathSegments.last,
                      await file.readAsBytes(),
                      'application/zip',
                    );
                  }),
          ),
        ),
    ],
  );
  void _selectSection(String section) {
    if (widget.shortcuts != null) _hubFocus.requestFocus();
    setState(() {
      _section = section == unsortedTodos ? 'Tasks' : section;
      _taskView = section == unsortedTodos ? _TaskView.unsorted : _TaskView.all;
      _projectFilter = '';
      _scan = null;
      if (_autoSearch) {
        _kind = 'all';
        _query.clear();
        _folder = '';
        _tag = '';
      }
    });
    if (_autoSearch) unawaited(_search());
  }

  KeyEventResult _handleShortcut(FocusNode node, KeyEvent event) {
    if (_busy || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    switch (widget.shortcuts?.match(event)) {
      case AppShortcut.knowledgeSearch:
        if (_section != 'Search') _selectSection('Search');
        _searchFocus.requestFocus();
      case AppShortcut.knowledgeTasks:
        _selectSection('Tasks');
      case AppShortcut.knowledgeJournal:
        _selectSection('Journal');
      case AppShortcut.knowledgeViews:
        _selectSection('Views');
      case AppShortcut.knowledgeBackups:
        _selectSection('Backups');
      case AppShortcut.knowledgeCapture:
        unawaited(_capture());
      case AppShortcut.quickTodo:
        unawaited(_quickTodo());
      case AppShortcut.knowledgeSubmit:
        if (_section != 'Search' && !_autoSearch) {
          return KeyEventResult.ignored;
        }
        unawaited(_search());
      case AppShortcut.importFile when widget.onImportFile != null:
        unawaited(
          widget.onImportFile!(() {
            if (mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).pop();
            }
          }),
        );
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _hubFocus,
    autofocus:
        !widget.embedded && widget.shortcuts != null && !widget.autofocusSearch,
    onKeyEvent: widget.embedded ? null : _handleShortcut,
    child: _buildPage(),
  );

  static const _primarySections = [
    ('Search', Icons.search),
    ('Tasks', Icons.checklist),
    ('Journal', Icons.calendar_today_outlined),
    ('Inbox', Icons.inbox_outlined),
  ];
  static const _otherSections = [
    ('Tags', Icons.sell_outlined),
    ('Views', Icons.bookmark_border),
    ('Templates', Icons.dashboard_customize_outlined),
    ('Backups', Icons.backup_outlined),
  ];

  Widget _sectionTile(String title, IconData icon, VoidCallback? onTap) =>
      ListTile(
        key: ValueKey('knowledge-section-$title'),
        title: Text(title),
        leading: Icon(icon, size: 20),
        selected: _section == title,
        selectedTileColor: NoterTheme.active,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        onTap: onTap,
      );

  Widget _sectionList(List<Widget> children, {bool shrinkWrap = false}) =>
      ListTileTheme(
        data: ListTileThemeData(
          minLeadingWidth: 18,
          horizontalTitleGap: 10,
          dense: NoterTheme.desktopControls(context),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          titleTextStyle: Theme.of(context).textTheme.bodyMedium,
        ),
        child: ListView(
          padding: const EdgeInsets.all(12),
          shrinkWrap: shrinkWrap,
          children: children,
        ),
      );

  Widget _sidebar() => SizedBox(
    width: 220,
    child: WorkspaceSidebar(
      key: const ValueKey('knowledge-sidebar'),
      child: Material(
        color: Colors.white,
        child: _sectionList([
          for (final (title, icon) in _primarySections)
            _sectionTile(
              title,
              icon,
              _busy ? null : () => _selectSection(title),
            ),
          const Divider(),
          for (final (title, icon) in _otherSections)
            _sectionTile(
              title,
              icon,
              _busy ? null : () => _selectSection(title),
            ),
        ]),
      ),
    ),
  );

  Future<void> _openSections() async {
    final section = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: _sectionList([
          for (final (title, icon) in _otherSections)
            _sectionTile(title, icon, () => Navigator.pop(context, title)),
        ], shrinkWrap: true),
      ),
    );
    if (mounted && !_busy && section != null) _selectSection(section);
  }

  Widget _bottomNavigation() {
    final index = _primarySections.indexWhere((entry) => entry.$1 == _section);
    return NavigationBar(
      selectedIndex: index == -1 ? _primarySections.length : index,
      onDestinationSelected: (index) {
        if (_busy) return;
        if (index == _primarySections.length) {
          unawaited(_openSections());
        } else {
          _selectSection(_primarySections[index].$1);
        }
      },
      destinations: [
        for (final (title, icon) in _primarySections)
          NavigationDestination(
            key: ValueKey('knowledge-section-$title'),
            enabled: !_busy,
            icon: Icon(icon),
            label: title,
          ),
        NavigationDestination(
          key: const ValueKey('knowledge-more-sections'),
          enabled: !_busy,
          icon: const Icon(Icons.more_horiz),
          label: index == -1 ? _section : 'More',
          tooltip: 'More sections',
        ),
      ],
    );
  }

  Widget _buildPage() {
    final desktop = NoterTheme.desktopControls(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(
          widget.embedded
              ? _section
              : _taskSection && _taskView == _TaskView.unsorted
              ? unsortedTodos
              : 'Knowledge hub',
        ),
        toolbarHeight: NoterTheme.headerHeight(context),
        actions: [
          if (!widget.embedded)
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
          if (_section == 'Search') ...[
            if (widget.onOpenViews case final views?)
              IconButton(
                tooltip: 'Saved views',
                onPressed: views,
                icon: const Icon(Icons.bookmarks_outlined),
              ),
            if (widget.onOpenGraph case final graph?)
              IconButton(
                tooltip: 'Graph view',
                onPressed: graph,
                icon: const Icon(Icons.hub_outlined),
              ),
          ],
          if (_section == 'Inbox' && !widget.embedded)
            IconButton(
              tooltip: 'Quick capture',
              onPressed: _busy ? null : _capture,
              icon: const Icon(Icons.note_add_outlined),
            ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: widget.embedded || desktop
          ? null
          : _bottomNavigation(),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.embedded && desktop) _sidebar(),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: _sectionBody(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBody() => Column(
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_searching)
        TextButton(
          onPressed: _cancelRequested
              ? null
              : () => setState(() => _cancelRequested = true),
          child: Text(
            _cancelRequested ? 'Finishing current file…' : 'Cancel search',
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _error!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: KeyedSubtree(
          key: ValueKey(_section),
          child: switch (_section) {
            'Journal' => _journal(),
            'Tags' => _tags(),
            'Templates' => _templates(),
            'Views' => _views(),
            'Backups' => _backupPage(),
            _ => _results(),
          },
        ),
      ),
    ],
  );
}

class _JournalEntryDialog extends StatefulWidget {
  const _JournalEntryDialog({required this.date, required this.onSave});

  final DateTime date;
  final Future<Notebook> Function(String text, String id, DateTime at) onSave;

  @override
  State<_JournalEntryDialog> createState() => _JournalEntryDialogState();
}

class _JournalEntryDialogState extends State<_JournalEntryDialog> {
  final _id = LocalNotebookRepository.newId();
  final _recordedAt = DateTime.now();
  String _text = '';
  String? _error;
  bool _saving = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final note = await widget.onSave(_text, _id, _recordedAt);
      if (mounted) Navigator.pop(context, note);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Add journal entry'),
      content: SizedBox(
        width: 420,
        child: TextField(
          autofocus: true,
          readOnly: _saving,
          minLines: 3,
          maxLines: 10,
          onChanged: (value) => setState(() => _text = value),
          decoration: InputDecoration(
            labelText: 'Journal entry',
            helperText: MaterialLocalizations.of(
              context,
            ).formatFullDate(widget.date),
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _text.trim().isEmpty ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save entry'),
        ),
      ],
    ),
  );
}
