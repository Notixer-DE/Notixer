import 'dart:async';
import 'package:flutter/material.dart';
import '../data/learning.dart';
import '../data/notebook.dart';
import '../data/tapes.dart';
import 'editor.dart';

class StudyTask {
  const StudyTask(this.note, this.target, this.schedule);
  final Notebook note;
  final TapeTarget target;
  final ReviewSchedule? schedule;
}

class StudyPage extends StatefulWidget {
  const StudyPage({super.key, required this.repository, this.clock});
  final NotebookRepository repository;
  final DateTime Function()? clock;
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
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && !_opening && ModalRoute.of(context)?.isCurrent == true) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    final tasks = <StudyTask>[], errors = <String>[];
    var total = 0;
    final now = (widget.clock ?? DateTime.now)().toUtc();
    try {
      final notes = await widget.repository.list();
      for (final note in notes) {
        if (note.isMarkdown) continue;
        if (!mounted) return;
        try {
          // One PDF at a time; parsing and target scanning run off the UI thread.
          final targets = await scanTapes(
            await widget.repository.load(note.id),
          );
          total += targets.length;
          for (final target in targets) {
            final schedule = note.learning.schedule(target.id);
            if (schedule == null || schedule.isDue(now)) {
              tasks.add(StudyTask(note, target, schedule));
            }
          }
        } catch (e) {
          errors.add('„${note.title}“ konnte nicht geprüft werden: $e');
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
      errors.add('Aufgaben konnten nicht geladen werden: $e');
    } finally {
      if (mounted) {
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
    }
  }

  Future<void> _open(StudyTask task) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final note = (await widget.repository.list())
          .where((n) => n.id == task.note.id)
          .firstOrNull;
      if (note == null) {
        throw StateError('Die Notiz wurde entfernt.');
      }
      final bytes = await widget.repository.load(note.id);
      final target = (await scanTapes(
        bytes,
      )).where((t) => t.id == task.target.id).firstOrNull;
      if (target == null) {
        throw StateError('Die Abdeckung wurde entfernt.');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditorPage(
            note: note,
            bytes: bytes,
            repository: widget.repository,
            initialPage: target.page,
            initialTapeId: target.id,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lernaufgabe konnte nicht geöffnet werden: $e'),
          ),
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
      title: const Text('Heute lernen'),
      actions: [
        IconButton(
          tooltip: 'Aufgaben neu laden',
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
              '${_tasks.length} jetzt fällige Aufgaben · $_total Abdeckungen\n'
              'Neue Abdeckungen sind sofort fällig. Nach dem Aufdecken bewerten; '
              'gelernt wird direkt im Originaldokument.',
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
                          ? 'Für jetzt ist alles erledigt.'
                          : 'Keine fälligen Aufgaben in den lesbaren Notizen.',
                    ),
                    subtitle: const Text(
                      'Neue Aufgaben entstehen durch Lern-Abdeckungen im Editor.',
                    ),
                  );
                }
                final task = _tasks[taskIndex];
                return ListTile(
                  key: ValueKey('${task.note.id}:${task.target.id}'),
                  leading: const Icon(Icons.school_outlined),
                  title: Text(
                    '${task.note.title} · Seite ${task.target.page + 1}',
                  ),
                  subtitle: Text(
                    'Abdeckung ${task.target.index + 1} · '
                    '${task.schedule == null
                        ? "Neu"
                        : task.schedule!.concurrent
                        ? "Parallele Bewertungen · fällig"
                        : "${task.schedule!.count} Bewertungen · fällig"}',
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
