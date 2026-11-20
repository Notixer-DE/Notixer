import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

typedef ChangeTodoTimer =
    FutureOr<void> Function({TodoTimerAction? timer, Duration? workTime});

enum _TimerMenu { start, focus, pause, stop, edit, reset }

String _elapsedLabel(Duration duration) {
  final hours = duration.inHours;
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return hours == 0 ? '$minutes:$seconds' : '$hours:$minutes:$seconds';
}

class TodoTimer extends StatefulWidget {
  const TodoTimer({super.key, required this.todo, required this.onChanged});

  final QuickTodo todo;
  final ChangeTodoTimer? onChanged;

  @override
  State<TodoTimer> createState() => _TodoTimerState();
}

class _TodoTimerState extends State<TodoTimer> {
  Timer? _ticker;
  ValueNotifier<QuickTodo>? _focusedTodo;

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
    final focused = _focusedTodo;
    if (focused != null && focused.value.revision != widget.todo.revision) {
      // The focus dialog is on a separate route. Notify it after this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_focusedTodo, focused)) {
          focused.value = widget.todo;
        }
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _apply({TodoTimerAction? timer, Duration? workTime}) async {
    if (mounted) await widget.onChanged?.call(timer: timer, workTime: workTime);
  }

  Future<void> _focus({bool start = false}) async {
    if (_focusedTodo != null) return;
    final todo = ValueNotifier(widget.todo);
    _focusedTodo = todo;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FocusTimer(todo: todo, onChanged: _apply, start: start),
    );
    try {
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _focusedTodo = null;
      todo.dispose();
    }
  }

  Future<void> _select(_TimerMenu value) async {
    switch (value) {
      case _TimerMenu.start:
        await _focus(start: true);
      case _TimerMenu.focus:
        await _focus();
      case _TimerMenu.pause:
        await _apply(timer: TodoTimerAction.pause);
      case _TimerMenu.stop:
        await _apply(timer: TodoTimerAction.stop);
      case _TimerMenu.edit:
        final duration = await _askDuration(
          context,
          'Set tracked time',
          widget.todo.workTimeAt(DateTime.now()),
        );
        if (duration != null) await _apply(workTime: duration);
      case _TimerMenu.reset:
        await _apply(timer: TodoTimerAction.reset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final running = todo.timerStartedAt != null;
    final duration = todo.workTimeAt(DateTime.now());
    return PopupMenuButton<_TimerMenu>(
      tooltip: 'Task timer',
      enabled: widget.onChanged != null,
      onSelected: _select,
      itemBuilder: (_) => [
        if (!todo.done) ...[
          if (running)
            const PopupMenuItem(
              value: _TimerMenu.focus,
              child: Text('Open focus timer'),
            )
          else
            PopupMenuItem(
              value: _TimerMenu.start,
              child: Text(todo.timerPaused ? 'Resume timer' : 'Start timer'),
            ),
          if (running)
            const PopupMenuItem(
              value: _TimerMenu.pause,
              child: Text('Pause timer'),
            ),
          if (running || todo.timerPaused)
            const PopupMenuItem(
              value: _TimerMenu.stop,
              child: Text('Stop timer'),
            ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(
          value: _TimerMenu.edit,
          child: Text('Set tracked time'),
        ),
        PopupMenuItem(
          value: _TimerMenu.reset,
          enabled: running || todo.timerPaused || duration != Duration.zero,
          child: const Text('Reset timer'),
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
              Text(_elapsedLabel(duration)),
            ],
          ],
        ),
      ),
    );
  }
}

class _FocusTimer extends StatefulWidget {
  const _FocusTimer({
    required this.todo,
    required this.onChanged,
    required this.start,
  });
  final ValueNotifier<QuickTodo> todo;
  final ChangeTodoTimer onChanged;
  final bool start;

  @override
  State<_FocusTimer> createState() => _FocusTimerState();
}

class _FocusTimerState extends State<_FocusTimer> {
  Timer? _ticker;
  Duration? _target;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.todo.value.timerStartedAt != null) setState(() {});
    });
    if (widget.start) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_apply(TodoTimerAction.start));
      });
    }
  }

  Future<void> _apply(TodoTimerAction? action, {Duration? workTime}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onChanged(timer: action, workTime: workTime);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setTarget() async {
    final duration = await _askDuration(
      context,
      'Set target time',
      _target ?? const Duration(minutes: 25),
    );
    if (duration != null && mounted) {
      setState(() => _target = duration == Duration.zero ? null : duration);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Focus timer'),
      actions: [
        PopupMenuButton<_TimerMenu>(
          tooltip: 'Time options',
          enabled: !_busy,
          onSelected: (value) async {
            if (value == _TimerMenu.reset) {
              await _apply(TodoTimerAction.reset);
            } else {
              final duration = await _askDuration(
                context,
                'Set tracked time',
                widget.todo.value.workTimeAt(DateTime.now()),
              );
              if (duration != null && mounted) {
                await _apply(null, workTime: duration);
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _TimerMenu.edit,
              child: Text('Set tracked time'),
            ),
            PopupMenuItem(value: _TimerMenu.reset, child: Text('Reset timer')),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: widget.todo,
        builder: (context, todo, _) {
          final running = todo.timerStartedAt != null;
          final elapsed = todo.workTimeAt(DateTime.now());
          final target = _target;
          final remaining = target == null ? null : target - elapsed;
          final text = Theme.of(context).textTheme;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      todo.text,
                      textAlign: TextAlign.center,
                      style: text.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    Text(_elapsedLabel(elapsed), style: text.displayMedium),
                    Text(running ? 'Time tracked · Running' : 'Time tracked'),
                    if (remaining != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        remaining <= Duration.zero
                            ? 'Target reached'
                            : '${_elapsedLabel(remaining)} remaining',
                        style: text.titleMedium,
                      ),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!todo.done)
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _apply(
                                    running
                                        ? TodoTimerAction.pause
                                        : TodoTimerAction.start,
                                  ),
                            icon: Icon(
                              running ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(
                              running
                                  ? 'Pause'
                                  : todo.timerPaused
                                  ? 'Resume'
                                  : 'Start',
                            ),
                          ),
                        if (running || todo.timerPaused)
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _apply(TodoTimerAction.stop),
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                          ),
                        TextButton(
                          onPressed: _setTarget,
                          child: Text(
                            target == null
                                ? 'Set target time'
                                : 'Change target time',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

Future<Duration?> _askDuration(
  BuildContext context,
  String title,
  Duration initial,
) async {
  final form = GlobalKey<FormState>();
  final fields = [
    ('Hours', initial.inHours, null as int?),
    ('Minutes', initial.inMinutes % 60, 59),
    ('Seconds', initial.inSeconds % 60, 59),
  ];
  final values = fields.map((field) => field.$2).toList();
  return showDialog<Duration>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < fields.length; i++)
                TextFormField(
                  initialValue: '${values[i]}',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: fields[i].$1),
                  validator: (value) {
                    final number = int.tryParse(value ?? '');
                    final max = fields[i].$3 ?? 999999;
                    return number == null || number > max
                        ? 'Enter 0 to $max'
                        : null;
                  },
                  onSaved: (value) => values[i] = int.parse(value!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            form.currentState!.save();
            Navigator.pop(
              context,
              Duration(
                hours: values[0],
                minutes: values[1],
                seconds: values[2],
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
