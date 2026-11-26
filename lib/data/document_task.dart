import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import 'markdown_document.dart';
import 'quick_todos.dart';

const _taskMetadataPattern = r' <!-- notixer-task ([a-zA-Z0-9+/=]+) -->';
final _taskMetadata = RegExp(_taskMetadataPattern + r'$');
final _taskLinkIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,100}$');

bool validTaskLinkId(String value) => _taskLinkIdPattern.hasMatch(value);

/// Consume the task comment as Markdown syntax so code examples stay literal.
class TaskMetadataSyntax extends md.InlineSyntax {
  TaskMetadataSyntax() : super(_taskMetadataPattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) => true;
}

String visibleTaskText(String line) => line.replaceFirst(_taskMetadata, '');

int _lineEnd(String source, int offset) {
  final newline = source.indexOf('\n', offset);
  final end = newline < 0 ? source.length : newline;
  return end > offset && source[end - 1] == '\r' ? end - 1 : end;
}

Map<String, Object?>? _readTaskMetadata(String line) {
  final match = _taskMetadata.firstMatch(line);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(utf8.decode(base64Decode(match[1]!)));
    if (decoded is! Map) return null;
    return {
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  } catch (_) {
    return null;
  }
}

String? documentTaskLinkId(String source, int offset) {
  if (offset + 2 > source.length) return null;
  final metadata = _readTaskMetadata(
    source.substring(offset + 2, _lineEnd(source, offset)),
  );
  final linkId = metadata?['linkId'];
  return linkId is String && validTaskLinkId(linkId) ? linkId : null;
}

String _encodeTaskComment(Map<String, Object?> metadata) => metadata.isEmpty
    ? ''
    : ' <!-- notixer-task ${base64Encode(utf8.encode(jsonEncode(metadata)))} -->';

String _linkOnlyComment(String linkId) {
  if (!validTaskLinkId(linkId)) {
    throw const FormatException('Invalid task link ID.');
  }
  return _encodeTaskComment({'linkId': linkId});
}

typedef LinkedDocumentTask = ({
  int offset,
  int line,
  String text,
  bool done,
  String linkId,
});

List<LinkedDocumentTask> linkedDocumentTasks(String source) {
  if (!source.contains('<!-- notixer-task ')) return const [];
  final tasks = <LinkedDocumentTask>[];
  var line = 1;
  var nextBreak = source.indexOf('\n');
  for (final offset in markdownTaskOffsets(source)) {
    while (nextBreak >= 0 && nextBreak < offset) {
      line++;
      nextBreak = source.indexOf('\n', nextBreak + 1);
    }
    final linkId = documentTaskLinkId(source, offset);
    if (linkId == null) continue;
    final end = nextBreak < 0 ? source.length : nextBreak;
    final cleanEnd = end > offset && source[end - 1] == '\r' ? end - 1 : end;
    tasks.add((
      offset: offset,
      line: line,
      text: visibleTaskText(source.substring(offset + 2, cleanEnd)).trim(),
      done: source[offset] != ' ',
      linkId: linkId,
    ));
  }
  return tasks;
}

QuickTodo documentTask(
  String source,
  int offset,
  String text, {
  required DateTime fallback,
}) {
  final line = source.substring(offset + 2, _lineEnd(source, offset));
  final metadata = _readTaskMetadata(line);
  final done = source[offset] != ' ';
  final plain = text.trim().isEmpty ? '(Empty task)' : text;
  final modified = fallback.toUtc().toIso8601String();
  if (metadata != null) {
    try {
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

String deleteDocumentTaskLine(String source, int offset) {
  final start = source.lastIndexOf('\n', offset - 1) + 1;
  final newline = source.indexOf('\n', offset);
  return source.replaceRange(
    start,
    newline < 0 ? source.length : newline + 1,
    '',
  );
}

String setDocumentTaskLinkId(String source, int offset, String linkId) {
  if (!validTaskLinkId(linkId)) {
    throw const FormatException('Invalid task link ID.');
  }
  final end = _lineEnd(source, offset);
  final raw = source.substring(offset + 2, end);
  final visible = visibleTaskText(raw);
  final existing = _readTaskMetadata(raw);
  final metadata = <String, Object?>{...?existing, 'linkId': linkId};
  return source.replaceRange(
    offset + 2,
    end,
    '$visible${_encodeTaskComment(metadata)}',
  );
}

String planDocumentTask(
  String source,
  int offset, {
  String? project,
  String? due,
}) {
  final end = _lineEnd(source, offset);
  final raw = source.substring(offset + 2, end);
  final metadata = <String, Object?>{...?_readTaskMetadata(raw)}
    ..remove('project')
    ..remove('due');
  if (project != null) metadata['project'] = project;
  if (due != null) metadata['due'] = due;
  return source.replaceRange(
    offset + 2,
    end,
    '${visibleTaskText(raw)}${_encodeTaskComment(metadata)}',
  );
}

String updateDocumentTask(
  String source,
  int offset, {
  bool? done,
  TodoTimerAction? timer,
  Duration? workTime,
  Duration? countdown,
  String? linkId,
  DateTime? previousModified,
  DateTime? now,
}) {
  if (linkId != null && !validTaskLinkId(linkId)) {
    throw const FormatException('Invalid task link ID.');
  }
  final effectiveLinkId = linkId ?? documentTaskLinkId(source, offset);
  final instant = now ?? DateTime.now();
  final end = _lineEnd(source, offset);
  final line = visibleTaskText(source.substring(offset, end));
  final original = documentTask(
    source,
    offset,
    line.substring(2),
    fallback: previousModified ?? instant,
  );
  final updated = original.update(
    instant,
    project: original.project,
    due: original.due,
    done: done,
    timer: timer,
    workTime: workTime,
    countdown: countdown,
  );
  final metadata = updated.toJson()
    ..removeWhere(
      (key, value) =>
          value == null ||
          !{
            'project',
            'due',
            'completedAt',
            'timerStartedAt',
            'timerPaused',
            'workMilliseconds',
            'countdownMilliseconds',
            'countdownEndAtWorkMilliseconds',
          }.contains(key),
    );
  if (effectiveLinkId != null) {
    metadata['linkId'] = effectiveLinkId;
  }
  final suffix = _encodeTaskComment(metadata);
  return source.replaceRange(
    offset,
    end,
    '${updated.done ? 'x' : ' '}${line.substring(1)}$suffix',
  );
}

String syncDocumentTasksByLinkId(
  String source,
  String linkId, {
  required bool done,
  DateTime? previousModified,
  DateTime? now,
}) {
  if (!validTaskLinkId(linkId)) {
    throw const FormatException('Invalid task link ID.');
  }
  if (!source.contains('<!-- notixer-task ')) return source;
  final targets = [
    for (final offset in markdownTaskOffsets(source))
      if (documentTaskLinkId(source, offset) == linkId &&
          (source[offset] != ' ') != done)
        offset,
  ];
  if (targets.isEmpty) return source;
  var updated = source;
  for (final offset in targets.reversed) {
    updated = updateDocumentTask(
      updated,
      offset,
      done: done,
      previousModified: previousModified,
      now: now,
    );
  }
  return updated;
}

({String source, String clipboard, String linkId}) copyLinkedDocumentTask(
  String source,
  int offset, {
  required String Function() generateId,
}) {
  final linkId = documentTaskLinkId(source, offset) ?? generateId();
  if (!validTaskLinkId(linkId)) {
    throw const FormatException('Invalid task link ID.');
  }
  final end = _lineEnd(source, offset);
  final done = source[offset] != ' ';
  final text = visibleTaskText(source.substring(offset + 2, end)).trim();
  final updated = documentTaskLinkId(source, offset) == linkId
      ? source
      : setDocumentTaskLinkId(source, offset, linkId);
  final clipboard = text.isEmpty
      ? '- [${done ? 'x' : ' '}]${_linkOnlyComment(linkId)}'
      : '- [${done ? 'x' : ' '}] $text${_linkOnlyComment(linkId)}';
  return (source: updated, clipboard: clipboard, linkId: linkId);
}

({
  String source,
  String clipboard,
  int selectionStart,
  int selectionEnd,
  bool linked,
})
copyLinkedMarkdownSelection(
  String source,
  int start,
  int end, {
  required String Function() generateId,
}) {
  final normalizedStart = start.clamp(0, source.length);
  final normalizedEnd = end.clamp(0, source.length);
  if (normalizedStart >= normalizedEnd) {
    return (
      source: source,
      clipboard: '',
      selectionStart: normalizedStart,
      selectionEnd: normalizedEnd,
      linked: false,
    );
  }
  final matched = <({int offset, int lineStart, int lineEnd, String linkId})>[];
  for (final offset in markdownTaskOffsets(source)) {
    if (normalizedStart <= offset - 1 && normalizedEnd >= offset + 2) {
      final linkId = documentTaskLinkId(source, offset) ?? generateId();
      if (!validTaskLinkId(linkId)) {
        throw const FormatException('Invalid task link ID.');
      }
      final lineStart = source.lastIndexOf('\n', offset) + 1;
      final lineEnd = _lineEnd(source, offset);
      matched.add((
        offset: offset,
        lineStart: lineStart,
        lineEnd: lineEnd,
        linkId: linkId,
      ));
    }
  }
  if (matched.isEmpty) {
    return (
      source: source,
      clipboard: source.substring(normalizedStart, normalizedEnd),
      selectionStart: normalizedStart,
      selectionEnd: normalizedEnd,
      linked: false,
    );
  }

  final byLineStart = {for (final entry in matched) entry.lineStart: entry};
  final clipboard = StringBuffer();
  var cursor = normalizedStart;
  while (cursor < normalizedEnd) {
    final newline = source.indexOf('\n', cursor);
    final rawBreak = newline < 0 || newline >= normalizedEnd
        ? normalizedEnd
        : newline;
    final hasCr =
        rawBreak > cursor &&
        source[rawBreak - 1] == '\r' &&
        (rawBreak == newline || rawBreak == normalizedEnd);
    final contentEnd = hasCr ? rawBreak - 1 : rawBreak;
    final lineBreak = newline >= 0 && newline < normalizedEnd
        ? (hasCr ? '\r\n' : '\n')
        : (hasCr ? '\r' : '');
    final lineStart = cursor == 0
        ? 0
        : source.lastIndexOf('\n', cursor - 1) + 1;
    final entry = byLineStart[lineStart];
    var segment = source.substring(cursor, contentEnd);
    if (entry != null) {
      final rawLine = source.substring(entry.offset + 2, entry.lineEnd);
      final existingComment = _taskMetadata.firstMatch(rawLine);
      if (existingComment != null) {
        final commentStart = entry.offset + 2 + existingComment.start;
        if (contentEnd > commentStart) {
          final keep = (commentStart - cursor).clamp(0, segment.length);
          segment = segment.substring(0, keep);
        }
      }
      clipboard.write(segment);
      clipboard.write(_linkOnlyComment(entry.linkId));
    } else {
      clipboard.write(segment);
    }
    clipboard.write(lineBreak);
    if (newline < 0 || newline >= normalizedEnd) break;
    cursor = newline + 1;
  }

  var updated = source;
  var mappedStart = normalizedStart;
  var mappedEnd = normalizedEnd;
  for (final entry in matched.reversed) {
    if (documentTaskLinkId(updated, entry.offset) == entry.linkId) continue;
    final rawLine = updated.substring(entry.offset + 2, entry.lineEnd);
    final existingComment = _taskMetadata.firstMatch(rawLine);
    final replaceStart = existingComment == null
        ? entry.lineEnd
        : entry.offset + 2 + existingComment.start;
    final beforeLen = updated.length;
    updated = setDocumentTaskLinkId(updated, entry.offset, entry.linkId);
    final delta = updated.length - beforeLen;
    if (delta != 0) {
      if (mappedStart > entry.lineEnd) {
        mappedStart += delta;
      }
      if (mappedEnd > entry.lineEnd ||
          (existingComment != null &&
              mappedEnd > replaceStart &&
              mappedEnd <= entry.lineEnd)) {
        mappedEnd += delta;
      }
    }
  }

  return (
    source: updated,
    clipboard: clipboard.toString(),
    selectionStart: mappedStart.clamp(0, updated.length),
    selectionEnd: mappedEnd.clamp(0, updated.length),
    linked: true,
  );
}
