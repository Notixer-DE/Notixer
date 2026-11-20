import 'dart:convert';

import '../data/journal_template.dart';
import '../data/markdown_document.dart';

enum WebNoteKind { markdown, todo, journal, inbox, template }

class WebNote {
  const WebNote(this.id, this.kind, this.title, this.source, this.modified);

  static const inboxId = 'task-inbox';
  static const templateId = 'journal-template';
  final String id, title, source;
  final WebNoteKind kind;
  final DateTime modified;

  String? get day => kind == WebNoteKind.journal ? id.substring(8) : null;

  WebNote edit(String title, String source) =>
      WebNote(id, kind, title.trim(), source, DateTime.now());

  Map<String, Object> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'source': source,
    'modified': modified.toUtc().toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  factory WebNote.fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['title'] is! String ||
        value['source'] is! String ||
        value['modified'] is! String) {
      throw const FormatException('Invalid note in the browser library.');
    }
    final id = value['id'] as String;
    final title = value['title'] as String;
    final source = value['source'] as String;
    final modified = DateTime.tryParse(value['modified'] as String);
    final kind = WebNoteKind.values
        .where((k) => k.name == value['kind'])
        .firstOrNull;
    if (kind == null ||
        modified == null ||
        title.trim().isEmpty ||
        title.length > 120 ||
        utf8.encode(source).length > MarkdownDocument.maxTextBytes) {
      throw const FormatException('Invalid note in the browser library.');
    }
    final validId = switch (kind) {
      WebNoteKind.inbox => id == inboxId,
      WebNoteKind.template => id == templateId,
      WebNoteKind.journal => _validDayId(id),
      _ => RegExp(r'^note-[a-z0-9-]{1,80}$').hasMatch(id),
    };
    if (!validId) throw const FormatException('Invalid note identity.');
    return WebNote(id, kind, title, source, modified);
  }

  static bool _validDayId(String id) {
    if (!RegExp(r'^journal-\d{4}-\d{2}-\d{2}$').hasMatch(id)) return false;
    final day = id.substring(8);
    final date = DateTime.tryParse(day);
    return date != null && journalDate(date) == day;
  }
}

const webBackupMaxBytes = 64 * 1024 * 1024;

String encodeWebBackup(Iterable<WebNote> notes) {
  final data = jsonEncode({
    'format': 'notixer-web-library',
    'version': 1,
    'notes': notes.map((note) => note.toJson()).toList(),
  });
  if (utf8.encode(data).length > webBackupMaxBytes) {
    throw const FormatException(
      'The backup exceeds 64 MB. Export notes individually.',
    );
  }
  return data;
}

List<WebNote> decodeWebBackup(String source) {
  final data = jsonDecode(source);
  if (data is! Map ||
      data['format'] != 'notixer-web-library' ||
      data['version'] != 1 ||
      data['notes'] is! List) {
    throw const FormatException(
      'Choose a Notixer Web backup or a Markdown file.',
    );
  }
  final ids = <String>{};
  return [
    for (final value in data['notes'] as List) _readUniqueNote(value, ids),
  ];
}

WebNote _readUniqueNote(Object? value, Set<String> ids) {
  final note = WebNote.fromJson(value);
  if (!ids.add(note.id)) {
    throw const FormatException('Duplicate note in backup.');
  }
  return note;
}

abstract interface class WebLibrary {
  Future<List<WebNote>> readAll();
  Future<void> write(WebNote note, {required WebNote? previous});
  Future<void> delete(WebNote previous);
  Future<int> importMissing(List<WebNote> notes);
}
