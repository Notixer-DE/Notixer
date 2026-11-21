import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;

enum TodoTimerAction { start, pause, stop, reset }

class QuickTodo {
  static const _maxWorkMilliseconds = 9007199254740991;
  static const _maxCountdownMilliseconds = 3599999999000;

  const QuickTodo({
    required this.id,
    required this.text,
    required this.created,
    required this.modified,
    this.done = false,
    this.deleted = false,
    this.project,
    this.due,
    this.completedAt,
    this.timerStartedAt,
    this.workMilliseconds = 0,
    this.timerPaused = false,
    this.countdownMilliseconds,
    this.countdownEndAtWorkMilliseconds,
  });

  final String id, text;
  final DateTime created, modified;
  final bool done, deleted;
  // The collection stores a local folder ID. Sync serializes the folder name.
  final String? project, due;

  final DateTime? completedAt, timerStartedAt;
  final int workMilliseconds;
  final int? countdownMilliseconds, countdownEndAtWorkMilliseconds;
  final bool timerPaused;

  DateTime? get completionTime => done ? completedAt ?? modified : null;

  Duration workTimeAt(DateTime now) {
    final started = timerStartedAt;
    final elapsed = started == null
        ? 0
        : now.difference(started).inMilliseconds;
    return Duration(
      milliseconds: workMilliseconds + (elapsed < 0 ? 0 : elapsed),
    );
  }

  Duration? countdownRemainingAt(DateTime now) {
    final end = countdownEndAtWorkMilliseconds;
    if (end == null) return null;
    final remaining = end - workTimeAt(now).inMilliseconds;
    if (remaining <= 0) return Duration.zero;
    return Duration(milliseconds: remaining);
  }

  QuickTodo withProject(String? project) => QuickTodo(
    id: id,
    text: text,
    created: created,
    modified: modified,
    done: done,
    deleted: deleted,
    project: project,
    due: due,
    completedAt: completedAt,
    timerStartedAt: timerStartedAt,
    workMilliseconds: workMilliseconds,
    timerPaused: timerPaused,
    countdownMilliseconds: countdownMilliseconds,
    countdownEndAtWorkMilliseconds: countdownEndAtWorkMilliseconds,
  );

  QuickTodo delete(DateTime now) => QuickTodo(
    id: id,
    text: 'Deleted to-do',
    created: created,
    modified: _nextModified(now),
    deleted: true,
  );

  DateTime _nextModified(DateTime now) => now.isAfter(modified)
      ? now
      : modified.add(const Duration(microseconds: 1));

  QuickTodo update(
    DateTime now, {
    String? text,
    required String? project,
    required String? due,
    bool? done,
    TodoTimerAction? timer,
    Duration? workTime,
    Duration? countdown,
  }) {
    final checked = done ?? this.done;
    if (workTime != null &&
        (workTime.isNegative ||
            workTime.inMilliseconds > _maxWorkMilliseconds)) {
      throw const FormatException('Enter a valid work time.');
    }
    final reset = timer == TodoTimerAction.reset;
    final stop = checked || timer == TodoTimerAction.stop || reset;
    final settle = stop || timer == TodoTimerAction.pause;
    var target = countdownMilliseconds;
    var end = countdownEndAtWorkMilliseconds;
    final elapsed = workTimeAt(now).inMilliseconds;
    if (reset) {
      target = null;
      end = null;
    } else if (timer == TodoTimerAction.start &&
        countdown != null &&
        timerStartedAt == null &&
        !checked) {
      final duration = countdown.inMilliseconds;
      if (duration < 0 || duration > _maxCountdownMilliseconds) {
        throw const FormatException('Enter a valid countdown duration.');
      }
      target = duration == 0 ? null : duration;
      end = target == null ? null : elapsed + duration;
    } else if (workTime != null && end != null) {
      end += workTime.inMilliseconds - elapsed;
    }
    return QuickTodo(
      id: id,
      text: text ?? this.text,
      created: created,
      modified: _nextModified(now),
      done: checked,
      project: project,
      due: due,
      completedAt: checked ? completionTime ?? now : null,
      timerStartedAt: settle
          ? null
          : ((timer == TodoTimerAction.start && timerStartedAt == null) ||
                    (workTime != null && timerStartedAt != null)
                ? now
                : timerStartedAt),
      workMilliseconds: reset
          ? 0
          : workTime?.inMilliseconds ?? (settle ? elapsed : workMilliseconds),
      countdownMilliseconds: target,
      countdownEndAtWorkMilliseconds: end,
      timerPaused:
          !stop &&
          (timer == TodoTimerAction.pause || (timer == null && timerPaused)),
    );
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'created': created.toUtc().toIso8601String(),
    'modified': modified.toUtc().toIso8601String(),
    'done': done,
    if (deleted) 'deleted': true,
    'project': project,
    'due': due,
    if (completedAt != null)
      'completedAt': completedAt!.toUtc().toIso8601String(),
    if (timerStartedAt != null)
      'timerStartedAt': timerStartedAt!.toUtc().toIso8601String(),
    if (workMilliseconds != 0) 'workMilliseconds': workMilliseconds,
    if (timerPaused) 'timerPaused': true,
    'countdownMilliseconds': ?countdownMilliseconds,
    'countdownEndAtWorkMilliseconds': ?countdownEndAtWorkMilliseconds,
  };

  factory QuickTodo.fromJson(String id, Object? value) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(id) || value is! Map) {
      throw const FormatException('Invalid quick to-do.');
    }
    final text = value['text'];
    final created = DateTime.tryParse(value['created']?.toString() ?? '');
    final modified = DateTime.tryParse(value['modified']?.toString() ?? '');
    final done = value['done'];
    final deleted = value['deleted'] ?? false;
    final project = value['project'];
    final due = value['due'];
    final completed = DateTime.tryParse(value['completedAt']?.toString() ?? '');
    final started = DateTime.tryParse(
      value['timerStartedAt']?.toString() ?? '',
    );
    final work = value['workMilliseconds'] ?? 0;
    final paused = value['timerPaused'] ?? false;
    final countdown = value['countdownMilliseconds'];
    final countdownEnd = value['countdownEndAtWorkMilliseconds'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.contains(RegExp(r'[\r\n]')) ||
        utf8.encode(text).length > 64 * 1024 ||
        created == null ||
        modified == null ||
        done is! bool ||
        deleted is! bool ||
        (value['completedAt'] != null && (completed == null || !done)) ||
        (value['timerStartedAt'] != null && (started == null || done)) ||
        work is! int ||
        work < 0 ||
        work > _maxWorkMilliseconds ||
        paused is! bool ||
        (paused && (started != null || done)) ||
        ((countdown == null) != (countdownEnd == null)) ||
        (countdown != null &&
            (countdown is! int ||
                countdown < 1 ||
                countdown > _maxCountdownMilliseconds)) ||
        (countdownEnd != null &&
            (countdownEnd is! int ||
                countdownEnd.abs() >
                    _maxWorkMilliseconds + _maxCountdownMilliseconds)) ||
        (project != null &&
            (project is! String ||
                project.trim().isEmpty ||
                project.length > 1024)) ||
        (due != null && (due is! String || !_validDue(due)))) {
      throw const FormatException('Invalid quick to-do.');
    }
    return QuickTodo(
      id: id,
      text: text,
      created: created,
      modified: modified,
      done: done,
      deleted: deleted,
      project: project as String?,
      due: due as String?,
      completedAt: completed,
      timerStartedAt: started,
      workMilliseconds: work,
      timerPaused: paused,
      countdownMilliseconds: countdown as int?,
      countdownEndAtWorkMilliseconds: countdownEnd as int?,
    );
  }

  static bool _validDue(String due) {
    final date = DateTime.tryParse(due);
    return date != null &&
        date.year > 0 &&
        date.toIso8601String().split('T').first == due;
  }

  // Break ties without relying on device order, including simultaneous migration.
  String get revision => jsonEncode(toJson());

  bool supersedes(QuickTodo other) {
    // A stale device must not bring back a task with the same ID.
    if (deleted != other.deleted) return deleted;
    final order = modified.compareTo(other.modified);
    if (order != 0) return order > 0;
    if (done != other.done) return done;
    return revision.compareTo(other.revision) > 0;
  }
}

class QuickTodoStore {
  QuickTodoStore(Directory directory)
    : file = File(p.join(directory.absolute.path, fileName));

  static const fileName = '.quick-todos.json';
  static const _maxBytes = 32 * 1024 * 1024;
  static final _queues = <String, Future<void>>{};
  final File file;

  static Map<String, QuickTodo> decode(Uint8List? bytes) {
    if (bytes == null) return {};
    if (bytes.length > _maxBytes) {
      throw const FormatException('The quick to-do collection is too large.');
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['version'] != 1 || json['tasks'] is! Map) {
      throw const FormatException('Invalid quick to-do collection.');
    }
    return {
      for (final entry in (json['tasks'] as Map<String, dynamic>).entries)
        entry.key: QuickTodo.fromJson(entry.key, entry.value),
    };
  }

  Future<Uint8List?> snapshot() async =>
      await file.exists() ? file.readAsBytes() : null;

  Future<Map<String, QuickTodo>> read() async =>
      decode(await snapshot())..removeWhere((_, todo) => todo.deleted);

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = (_queues[file.path] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[file.path] = tail;
    tail.whenComplete(() {
      if (identical(_queues[file.path], tail)) _queues.remove(file.path);
    });
    return result;
  }

  Future<T> change<T>(T Function(Map<String, QuickTodo>) update) =>
      _serialize(() async {
        final before = await snapshot();
        final tasks = decode(before);
        final result = update(tasks);
        await _write(tasks, before);
        return result;
      });

  Future<void> applySync(
    Uint8List? expected,
    Map<String, QuickTodo> tasks,
  ) => _serialize(() async {
    final before = await snapshot();
    if (!listEquals(before, expected)) {
      throw const FormatException(
        'Quick to-dos changed during sync. Sync again to preserve both edits.',
      );
    }
    await _write(tasks, before);
  });

  Future<void> _write(Map<String, QuickTodo> tasks, Uint8List? before) async {
    if (tasks.isEmpty && before == null) return;
    final keys = tasks.keys.toList()..sort();
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'tasks': {for (final key in keys) key: tasks[key]!.toJson()},
      }),
    );
    if (listEquals(bytes, before)) return;
    decode(bytes);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}
