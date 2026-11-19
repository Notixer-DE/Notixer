import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;

class QuickTodo {
  const QuickTodo({
    required this.id,
    required this.text,
    required this.created,
    required this.modified,
    this.done = false,
    this.project,
    this.due,
  });

  final String id, text;
  final DateTime created, modified;
  final bool done;
  // The collection stores a local folder ID. Sync serializes the folder name.
  final String? project, due;

  QuickTodo withProject(String? project) => QuickTodo(
    id: id,
    text: text,
    created: created,
    modified: modified,
    done: done,
    project: project,
    due: due,
  );

  Map<String, Object?> toJson() => {
    'text': text,
    'created': created.toUtc().toIso8601String(),
    'modified': modified.toUtc().toIso8601String(),
    'done': done,
    'project': project,
    'due': due,
  };

  factory QuickTodo.fromJson(String id, Object? value) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(id) || value is! Map) {
      throw const FormatException('Invalid quick to-do.');
    }
    final text = value['text'];
    final created = DateTime.tryParse(value['created']?.toString() ?? '');
    final modified = DateTime.tryParse(value['modified']?.toString() ?? '');
    final done = value['done'];
    final project = value['project'];
    final due = value['due'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.contains(RegExp(r'[\r\n]')) ||
        utf8.encode(text).length > 64 * 1024 ||
        created == null ||
        modified == null ||
        done is! bool ||
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
      project: project as String?,
      due: due as String?,
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

  Future<Map<String, QuickTodo>> read() async => decode(await snapshot());

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

  Future<void> change(void Function(Map<String, QuickTodo>) update) =>
      _serialize(() async {
        final before = await snapshot();
        final tasks = decode(before);
        update(tasks);
        await _write(tasks, before);
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
