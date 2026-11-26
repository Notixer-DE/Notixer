import 'dart:async';

import 'package:flutter/material.dart';

import '../data/knowledge.dart';
import '../data/notebook.dart';
import '../data/quick_todos.dart';
import 'study_page.dart';
import 'plan_todo_dialog.dart';
import 'todo_timer.dart';

class WorkspaceToday extends StatefulWidget {
  const WorkspaceToday({
    super.key,
    required this.repository,
    required this.current,
    required this.revision,
    required this.recentIds,
    required this.onOpen,
    required this.onTasks,
    required this.onStudy,
    required this.onJournal,
    required this.onChangeTask,
  });

  final LocalNotebookRepository repository;
  final bool current;
  final int revision;
  final List<String> recentIds;
  final ValueChanged<Notebook> onOpen;
  final VoidCallback onTasks;
  final void Function({required bool addEntry}) onJournal;
  final Future<void> Function() onStudy, onChangeTask;

  @override
  State<WorkspaceToday> createState() => _WorkspaceTodayState();
}

class _WorkspaceTodayState extends State<WorkspaceToday> {
  late final _store = KnowledgeStore(widget.repository);
  late Future<(List<QuickTodo>, List<Notebook>)> _data;
  late Future<(List<StudyTask>, List<String>, int)> _study;
  final _pending = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(WorkspaceToday oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.current &&
        (!oldWidget.current || widget.revision != oldWidget.revision)) {
      _reload();
    }
  }

  Future<(List<QuickTodo>, List<Notebook>)> _load() async {
    await widget.repository.catalog.load();
    await widget.repository.catalog.readingPositions.load();
    final today = journalDate(DateTime.now());
    final tasks =
        (await _store.quickTodos.read()).values
            .where(
              (todo) =>
                  !todo.done &&
                  todo.due != null &&
                  todo.due!.compareTo(today) <= 0,
            )
            .toList()
          ..sort((a, b) => a.due!.compareTo(b.due!));
    return (tasks, await widget.repository.list());
  }

  void _reload() {
    _data = _load();
    _study = loadStudyQueue(
      widget.repository,
      DateTime.now(),
      cancelled: () => !mounted,
    );
  }

  void _taskChanged() {
    if (!mounted) return;
    setState(() {
      _data = _load();
    });
    unawaited(widget.onChangeTask());
  }

  Future<void> _change(QuickTodo todo, bool? done) async {
    if (done == null || !_pending.add(todo.id)) return;
    try {
      await _store.changeTaskStatus(todo, done);
      _taskChanged();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update the task: $error')),
        );
        setState(() {
          _data = _load();
        });
      }
    } finally {
      _pending.remove(todo.id);
    }
  }

  Future<void> _plan(QuickTodo todo) async {
    if (!_pending.add(todo.id)) return;
    try {
      final task = KnowledgeTask.fromQuickTodo(todo);
      final plan = await showDialog<TodoPlan>(
        context: context,
        builder: (_) => PlanTodoDialog(
          task: task,
          folders: widget.repository.catalog.folders,
        ),
      );
      if (!mounted || plan == null) return;
      await _store.planQuickTodo(
        task,
        projectId: plan.projectId,
        newProject: plan.newProject,
        due: plan.due,
        text: plan.text,
      );
      _taskChanged();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update the task: $error')),
        );
      }
    } finally {
      _pending.remove(todo.id);
    }
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Semantics(header: true, child: Text(title)),
        ),
        ...children,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final (tasks, notes) = snapshot.data ?? (<QuickTodo>[], <Notebook>[]);
        final byId = {for (final note in notes) note.id: note};
        final recent = [
          for (final id in widget.recentIds)
            if (byId[id] case final note?
                when note.isPdf || (note.isMarkdown && !note.isTodoList))
              note,
        ];
        final hasJournal = notes.any(
          (note) => journalEntryDate(note) == journalDate(DateTime.now()),
        );
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              key: const PageStorageKey('workspace-today'),
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Today',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  MaterialLocalizations.of(
                    context,
                  ).formatFullDate(DateTime.now()),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (snapshot.connectionState != ConnectionState.done)
                  const LinearProgressIndicator(),
                if (snapshot.hasError)
                  ListTile(
                    title: const Text('Could not load Today'),
                    trailing: TextButton(
                      onPressed: () => setState(_reload),
                      child: const Text('Retry'),
                    ),
                  ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 12.0;
                    final wide =
                        constraints.maxWidth >= 820 &&
                        MediaQuery.textScalerOf(context).scale(16) <= 24;
                    final leading = wide
                        ? (constraints.maxWidth - gap) * .54
                        : constraints.maxWidth;
                    final trailing = wide
                        ? constraints.maxWidth - gap - leading
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: gap,
                      children: [
                        SizedBox(
                          width: leading,
                          child: Column(
                            children: [
                              _section('Due tasks', Icons.checklist, [
                                if (tasks.isEmpty &&
                                    !snapshot.hasError &&
                                    snapshot.hasData)
                                  const ListTile(
                                    title: Text('Nothing due today.'),
                                  ),
                                for (final todo in tasks.take(4))
                                  ListTile(
                                    key: ValueKey(todo.id),
                                    leading: Checkbox(
                                      value: todo.done,
                                      semanticLabel: todo.text,
                                      onChanged: (done) => _change(todo, done),
                                    ),
                                    title: Text(todo.text),
                                    onTap: () => _plan(todo),
                                    subtitle: Text(
                                      [
                                        if (todo.due!.compareTo(
                                              journalDate(DateTime.now()),
                                            ) <
                                            0)
                                          'Overdue'
                                        else
                                          'Today',
                                        ?widget.repository.catalog.folderName(
                                          todo.project,
                                        ),
                                      ].join(' · '),
                                    ),
                                    trailing: TodoTimer(
                                      todo: todo,
                                      directStart: true,
                                      onChanged:
                                          ({timer, workTime, countdown}) async {
                                            final updated = await _store
                                                .changeQuickTodoTimer(
                                                  todo.id,
                                                  timer: timer,
                                                  workTime: workTime,
                                                  countdown: countdown,
                                                );
                                            _taskChanged();
                                            return updated;
                                          },
                                    ),
                                  ),
                                ListTile(
                                  title: const Text('All tasks due today'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: widget.onTasks,
                                ),
                              ]),
                              _section('Study', Icons.school_outlined, [
                                FutureBuilder(
                                  future: _study,
                                  builder: (context, snapshot) {
                                    final queue = snapshot.data;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ListTile(
                                          title: Text(
                                            queue == null
                                                ? 'Checking reviews…'
                                                : '${queue.$1.length} due reviews',
                                          ),
                                          subtitle:
                                              queue != null &&
                                                  queue.$2.isNotEmpty
                                              ? const Text(
                                                  'Some notes could not be checked.',
                                                )
                                              : null,
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: TextButton.icon(
                                            onPressed:
                                                queue?.$1.isNotEmpty == true
                                                ? widget.onStudy
                                                : null,
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text('Start studying'),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ]),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: trailing,
                          child: Column(
                            children: [
                              _section(
                                'Continue reading',
                                Icons.menu_book_outlined,
                                [
                                  if (recent.isEmpty)
                                    const ListTile(
                                      title: Text(
                                        'Open a PDF or text note to start.',
                                      ),
                                    ),
                                  for (final note in recent.take(3))
                                    ListTile(
                                      title: Text(note.title),
                                      subtitle: Text(
                                        note.isPdf
                                            ? 'Page ${widget.repository.catalog.readingPositions.pageFor(note.id, 100000) + 1}'
                                            : 'Resume at your reading position',
                                      ),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => widget.onOpen(note),
                                    ),
                                ],
                              ),
                              _section(
                                'Journal',
                                Icons.calendar_today_outlined,
                                [
                                  if (hasJournal)
                                    ListTile(
                                      title: const Text('Open today’s journal'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () =>
                                          widget.onJournal(addEntry: false),
                                    ),
                                  ListTile(
                                    title: Text(
                                      hasJournal
                                          ? 'Add another entry'
                                          : 'Add an entry for today',
                                    ),
                                    trailing: const Icon(Icons.add),
                                    onTap: () =>
                                        widget.onJournal(addEntry: true),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
