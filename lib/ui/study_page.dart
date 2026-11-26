import 'dart:async';
import 'package:flutter/material.dart';
import '../data/learning.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/notebook.dart';
import '../data/tapes.dart';
import 'editor.dart';
import 'document_tab.dart';

class StudyTask {
  const StudyTask(this.note, this.target, this.schedule);
  final Notebook note;
  final TapeTarget target;
  final ReviewSchedule? schedule;
}

Future<(List<StudyTask>, List<String>, int)> loadStudyQueue(
  NotebookRepository repository,
  DateTime clock, {
  bool Function()? cancelled,
}) async {
  final tasks = <StudyTask>[], errors = <String>[];
  var total = 0;
  final now = clock.toUtc();
  try {
    final notes = await repository.list();
    for (final note in notes) {
      if (!note.isPdf) continue;
      if (cancelled?.call() == true) break;
      try {
        // One PDF at a time; parsing and target scanning run off the UI thread.
        final targets = await scanTapes(await repository.load(note.id));
        total += targets.length;
        for (final target in targets) {
          final schedule = note.learning.schedule(target.id);
          if (schedule == null || schedule.isDue(now)) {
            tasks.add(StudyTask(note, target, schedule));
          }
        }
      } catch (e) {
        errors.add('“${note.title}” could not be checked: $e');
      }
    }
    tasks.sort((a, b) {
      final due =
          (a.schedule?.due ??
                  DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
              .compareTo(
                b.schedule?.due ??
                    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              );
      if (due != 0) return due;
      final note = a.note.id.compareTo(b.note.id);
      if (note != 0) return note;
      final page = a.target.page.compareTo(b.target.page);
      return page != 0 ? page : a.target.id.compareTo(b.target.id);
    });
  } catch (e) {
    errors.add('Could not load tasks: $e');
  }
  return (tasks, errors, total);
}

class StudyPage extends StatefulWidget {
  const StudyPage({
    super.key,
    required this.repository,
    this.clock,
    this.shortcuts,
    this.startImmediately = false,
    this.workspaceSessions,
  });
  final NotebookRepository repository;
  final DateTime Function()? clock;
  final KeyboardShortcuts? shortcuts;
  final bool startImmediately;
  final WorkspacePdfSessions? workspaceSessions;
  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  final _tasks = <StudyTask>[];
  final _errors = <String>[];
  bool _loading = false, _opening = false;
  int _total = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(
      _load().then((_) async {
        if (mounted && widget.startImmediately && _tasks.isNotEmpty) {
          await _open(_tasks.first);
        }
      }),
    );
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && !_opening && ModalRoute.of(context)?.isCurrent == true) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    final (tasks, errors, total) = await loadStudyQueue(
      widget.repository,
      (widget.clock ?? DateTime.now)(),
      cancelled: () => !mounted,
    );
    if (!mounted) return;
    setState(() {
      _tasks
        ..clear()
        ..addAll(tasks);
      _errors
        ..clear()
        ..addAll(errors);
      _total = total;
      _loading = false;
    });
  }

  Future<void> _open(StudyTask task) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      StudyTask? next = task;
      var reviewed = 0;
      while (mounted && next != null) {
        final current = next;
        var rated = false;
        final note = (await widget.repository.list())
            .where((n) => n.id == current.note.id)
            .firstOrNull;
        if (note == null) {
          throw StateError('The note was removed.');
        }
        final bytes = await widget.repository.load(note.id);
        final target = (await scanTapes(
          bytes,
        )).where((t) => t.id == current.target.id).firstOrNull;
        if (target == null) {
          throw StateError('The study cover was removed.');
        }
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => EditorPage(
              note: note,
              bytes: bytes,
              repository: widget.repository,
              shortcuts: widget.shortcuts,
              workspaceSessions: widget.workspaceSessions,
              initialPage: target.page,
              initialTapeId: target.id,
              reviewProgress: 'Review ${reviewed + 1} · ${_tasks.length} due',
              onReviewRated: () => rated = true,
            ),
          ),
        );
        if (!mounted || !rated) break;
        reviewed++;
        await _load();
        next = _tasks.firstOrNull;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the review: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        await _load();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Study today'),
      actions: [
        IconButton(
          tooltip: 'Reload reviews',
          onPressed: _loading || _opening ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_loading || _opening) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${_tasks.length} ${_tasks.length == 1 ? 'review' : 'reviews'} due · $_total ${_total == 1 ? 'cover' : 'covers'}\n'
              'New covers are due immediately. Reveal and rate the answer in the original document.',
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount:
                  _errors.length +
                  _tasks.length +
                  (!_loading && _tasks.isEmpty ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < _errors.length) {
                  return ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(_errors[index]),
                  );
                }
                final taskIndex = index - _errors.length;
                if (taskIndex >= _tasks.length) {
                  return ListTile(
                    title: Text(
                      _errors.isEmpty
                          ? 'All done for now.'
                          : 'No reviews due in readable notes.',
                    ),
                    subtitle: const Text(
                      'Draw study covers in the editor to add reviews.',
                    ),
                  );
                }
                final task = _tasks[taskIndex];
                return ListTile(
                  key: ValueKey('${task.note.id}:${task.target.id}'),
                  leading: const Icon(Icons.school_outlined),
                  title: Text(
                    '${task.note.title} · Page ${task.target.page + 1}',
                  ),
                  subtitle: Text(
                    'Cover ${task.target.index + 1} · '
                    '${task.schedule == null
                        ? "New"
                        : task.schedule!.concurrent
                        ? "Concurrent ratings · due"
                        : "${task.schedule!.count} ${task.schedule!.count == 1 ? 'rating' : 'ratings'} · due"}',
                  ),
                  onTap: _loading || _opening ? null : () => _open(task),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
