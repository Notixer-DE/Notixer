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
    FutureOr<QuickTodo?> Function({
      TodoTimerAction? timer,
      Duration? workTime,
      Duration? countdown,
    });

enum _TimerMenu { focus, pause, stop, edit, reset }

enum _FocusMode {
  stopwatch('Stopwatch'),
  countdown('Countdown');

  const _FocusMode(this.label);
  final String label;
}

String _elapsedLabel(Duration duration) {
  final hours = duration.inHours;
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return hours == 0 ? '$minutes:$seconds' : '$hours:$minutes:$seconds';
}

class TodoTimer extends StatefulWidget {
  const TodoTimer({
    super.key,
    required this.todo,
    required this.onChanged,
    this.directStart = false,
    this.onTimerClosed,
  });

  final QuickTodo todo;
  final ChangeTodoTimer? onChanged;
  final bool directStart;
  final VoidCallback? onTimerClosed;

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
        if (mounted &&
            identical(_focusedTodo, focused) &&
            !widget.todo.modified.isBefore(focused.value.modified)) {
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
    final update = widget.onChanged;
    if (update == null) return;
    try {
      await update(timer: timer, workTime: workTime);
      if (mounted) widget.onTimerClosed?.call();
    } catch (error) {
      if (mounted) _showTimerError(context, error);
    }
  }

  Future<void> _focus() async {
    final update = widget.onChanged;
    if (_focusedTodo != null || update == null) return;
    final todo = ValueNotifier(widget.todo);
    _focusedTodo = todo;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FocusTimer(todo: todo, onChanged: update),
    );
    try {
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _focusedTodo = null;
      todo.dispose();
      if (mounted) widget.onTimerClosed?.call();
    }
  }

  Future<void> _select(_TimerMenu value) async {
    switch (value) {
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
    final quick = widget.directStart && !todo.done;
    final menu = PopupMenuButton<_TimerMenu>(
      tooltip: quick ? 'Time options' : 'Task timer',
      enabled: widget.onChanged != null,
      onSelected: _select,
      itemBuilder: (_) => [
        if (!todo.done) ...[
          if (!quick)
            const PopupMenuItem(
              value: _TimerMenu.focus,
              child: Text('Open focus timer'),
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
      icon: quick ? const Icon(Icons.more_time, size: 18) : null,
      child: quick
          ? null
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    running ? Icons.timelapse : Icons.timer_outlined,
                    size: 18,
                  ),
                  if (running ||
                      todo.timerPaused ||
                      duration != Duration.zero) ...[
                    const SizedBox(width: 4),
                    Text(_elapsedLabel(duration)),
                  ],
                ],
              ),
            ),
    );
    if (!quick) return menu;
    final status = running
        ? 'Running'
        : todo.timerPaused
        ? 'Paused'
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null || duration != Duration.zero)
          Tooltip(
            message: [status, _elapsedLabel(duration)].nonNulls.join(' · '),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 60),
              child: Text(
                _elapsedLabel(duration),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        IconButton(
          tooltip: 'Open focus timer',
          onPressed: widget.onChanged == null ? null : _focus,
          icon: Icon(running ? Icons.open_in_full : Icons.play_circle_outline),
        ),
        menu,
      ],
    );
  }
}

class _FocusTimer extends StatefulWidget {
  const _FocusTimer({required this.todo, required this.onChanged});

  final ValueNotifier<QuickTodo> todo;
  final ChangeTodoTimer onChanged;

  @override
  State<_FocusTimer> createState() => _FocusTimerState();
}

class _FocusTimerState extends State<_FocusTimer> {
  Timer? _ticker;
  late _FocusMode _mode = widget.todo.value.countdownMilliseconds == null
      ? _FocusMode.stopwatch
      : _FocusMode.countdown;
  late Duration _countdownLength = Duration(
    milliseconds:
        widget.todo.value.countdownMilliseconds ??
        const Duration(minutes: 25).inMilliseconds,
  );
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.todo.value.timerStartedAt != null) setState(() {});
    });
  }

  Future<void> _apply(
    TodoTimerAction? action, {
    Duration? workTime,
    Duration? countdown,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.onChanged(
        timer: action,
        workTime: workTime,
        countdown: countdown,
      );
      if (mounted && updated != null) widget.todo.value = updated;
    } catch (error) {
      if (mounted) _showTimerError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCountdown() async {
    final duration = await _askDuration(
      context,
      'Set countdown',
      _countdownLength,
      positive: true,
    );
    if (duration != null && mounted) {
      setState(() => _countdownLength = duration);
    }
  }

  Widget _countdownDisplay(
    TextTheme text,
    Duration remaining,
    Duration target,
  ) {
    final finished = remaining == Duration.zero;
    final seconds = (remaining.inMilliseconds + 999) ~/ 1000;
    return SizedBox.square(
      dimension: 154,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: (1 - remaining.inMilliseconds / target.inMilliseconds).clamp(
              0.0,
              1.0,
            ),
            strokeWidth: 8,
            semanticsLabel: 'Countdown progress',
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Semantics(
                liveRegion: finished,
                child: Text(
                  finished
                      ? 'Time is up'
                      : '${_elapsedLabel(Duration(seconds: seconds))} remaining',
                  textAlign: TextAlign.center,
                  style: text.titleMedium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.todo,
    builder: (context, todo, _) {
      final now = DateTime.now();
      final running = todo.timerStartedAt != null;
      final active = running || todo.timerPaused;
      final elapsed = todo.workTimeAt(now);
      final text = Theme.of(context).textTheme;
      final countdown = active
          ? todo.countdownMilliseconds != null
          : _mode == _FocusMode.countdown;
      final target = active && todo.countdownMilliseconds != null
          ? Duration(milliseconds: todo.countdownMilliseconds!)
          : _countdownLength;
      final remaining = active
          ? todo.countdownRemainingAt(now) ?? target
          : target;
      return Scaffold(
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
                PopupMenuItem(
                  value: _TimerMenu.reset,
                  child: Text('Reset timer'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
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
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        for (final mode in _FocusMode.values)
                          ChoiceChip(
                            label: Text(mode.label),
                            selected:
                                (mode == _FocusMode.countdown) == countdown,
                            onSelected: _busy || active || todo.done
                                ? null
                                : (_) => setState(() => _mode = mode),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (countdown) ...[
                      _countdownDisplay(text, remaining, target),
                      if (running && remaining == Duration.zero)
                        const Text('Work time is still being tracked.'),
                    ],
                    Text(
                      _elapsedLabel(elapsed),
                      style: countdown
                          ? text.headlineMedium
                          : text.displayMedium,
                    ),
                    Text(switch ((running, todo.timerPaused)) {
                      (true, _) => 'Time tracked · Running',
                      (_, true) => 'Time tracked · Paused',
                      _ => 'Time tracked',
                    }),
                    const SizedBox(height: 16),
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
                                    countdown: active
                                        ? null
                                        : (countdown ? target : Duration.zero),
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
                        if (active)
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _apply(TodoTimerAction.stop),
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                          ),
                        if (countdown && !active && !todo.done)
                          TextButton(
                            onPressed: _busy ? null : _setCountdown,
                            child: const Text('Set countdown'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _showTimerError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Could not update the task timer: $error')),
  );
}

Future<Duration?> _askDuration(
  BuildContext context,
  String title,
  Duration initial, {
  bool positive = false,
}) async {
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
                    if (number == null || number > max) {
                      return 'Enter 0 to $max';
                    }
                    if (positive &&
                        i == 2 &&
                        values.every((value) => value == 0)) {
                      return 'Enter a duration above zero';
                    }
                    return null;
                  },
                  onChanged: (value) => values[i] = int.tryParse(value) ?? 0,
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
