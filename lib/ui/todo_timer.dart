import 'dart:async';

import 'package:flutter/material.dart';

import '../data/quick_todos.dart';

String completedTaskLabel(BuildContext context, DateTime completed) {
  final local = completed.toLocal();
  final format = MaterialLocalizations.of(context);
  final time = format.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return 'Completed · ${format.formatMediumDate(local)} · $time';
}

class TodoTimer extends StatefulWidget {
  const TodoTimer({super.key, required this.todo, required this.onChanged});

  final QuickTodo todo;
  final ValueChanged<TodoTimerAction>? onChanged;

  @override
  State<TodoTimer> createState() => _TodoTimerState();
}

class _TodoTimerState extends State<TodoTimer> {
  Timer? _ticker;

  void _watch() {
    _ticker?.cancel();
    if (widget.todo.timerStartedAt != null) {
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(TodoTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.todo.timerStartedAt != oldWidget.todo.timerStartedAt) _watch();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final running = todo.timerStartedAt != null;
    final duration = todo.workTimeAt(DateTime.now());
    final hours = duration.inHours;
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final elapsed = hours == 0
        ? '$minutes:$seconds'
        : '$hours:$minutes:$seconds';
    if (todo.done) {
      return duration == Duration.zero
          ? const SizedBox.shrink()
          : Text(elapsed);
    }
    return PopupMenuButton<TodoTimerAction>(
      tooltip: 'Task timer',
      enabled: widget.onChanged != null,
      onSelected: widget.onChanged,
      itemBuilder: (_) => [
        if (!running)
          PopupMenuItem(
            value: TodoTimerAction.start,
            child: Text(todo.timerPaused ? 'Resume timer' : 'Start timer'),
          ),
        if (running)
          const PopupMenuItem(
            value: TodoTimerAction.pause,
            child: Text('Pause timer'),
          ),
        if (running || todo.timerPaused)
          const PopupMenuItem(
            value: TodoTimerAction.stop,
            child: Text('Stop timer'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(running ? Icons.timelapse : Icons.timer_outlined, size: 18),
            if (running || todo.timerPaused || duration != Duration.zero) ...[
              const SizedBox(width: 4),
              Text(elapsed),
            ],
          ],
        ),
      ),
    );
  }
}
