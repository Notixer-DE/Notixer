import 'dart:convert';

import 'quick_todos.dart';

final _taskMetadata = RegExp(r' <!-- notixer-task ([a-zA-Z0-9+/=]+) -->$');

String visibleTaskText(String line) => line.replaceFirst(_taskMetadata, '');

int _lineEnd(String source, int offset) {
  final newline = source.indexOf('\n', offset);
  final end = newline < 0 ? source.length : newline;
  return end > offset && source[end - 1] == '\r' ? end - 1 : end;
}

QuickTodo documentTask(
  String source,
  int offset,
  String text, {
  required DateTime fallback,
}) {
  final line = source.substring(offset + 2, _lineEnd(source, offset));
  final match = _taskMetadata.firstMatch(line);
  final done = source[offset] != ' ';
  final plain = text.trim().isEmpty ? '(Empty task)' : text;
  final modified = fallback.toUtc().toIso8601String();
  if (match != null) {
    try {
      final metadata = jsonDecode(utf8.decode(base64Decode(match[1]!))) as Map;
      return QuickTodo.fromJson('document-task', {
        ...metadata,
        'text': plain,
        'created': modified,
        'modified': modified,
        'done': done,
        // Checked state remains editable directly in Markdown source.
        if (!done) 'completedAt': null,
        if (done) ...{'timerStartedAt': null, 'timerPaused': false},
      });
    } catch (_) {
      // A hand-edited comment should never hide the checklist item.
    }
  }
  return QuickTodo(
    id: 'document-task',
    text: plain,
    created: fallback,
    modified: fallback,
    done: done,
  );
}

String updateDocumentTask(
  String source,
  int offset, {
  bool? done,
  TodoTimerAction? timer,
  DateTime? now,
}) {
  final instant = now ?? DateTime.now();
  final end = _lineEnd(source, offset);
  final line = visibleTaskText(source.substring(offset, end));
  final original = documentTask(
    source,
    offset,
    line.substring(2),
    fallback: instant,
  );
  final updated = original.update(
    instant,
    project: null,
    due: null,
    done: done,
    timer: timer,
  );
  final metadata = updated.toJson()
    ..removeWhere(
      (key, _) => !{
        'completedAt',
        'timerStartedAt',
        'timerPaused',
        'workMilliseconds',
      }.contains(key),
    );
  final suffix = metadata.isEmpty
      ? ''
      : ' <!-- notixer-task ${base64Encode(utf8.encode(jsonEncode(metadata)))} -->';
  return source.replaceRange(
    offset,
    end,
    '${updated.done ? 'x' : ' '}${line.substring(1)}$suffix',
  );
}
