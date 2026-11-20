import 'dart:convert';

import '../data/journal_template.dart';
import '../data/markdown_document.dart';
import '../data/quick_todos.dart';

enum WebNoteKind {
  markdown,
  todo,
  journal,
  inbox,
  template,
  pdf,
  media,
  quickTask,
}

class WebNote {
  const WebNote(
    this.id,
    this.kind,
    this.title,
    this.source,
    this.modified, {
    this.created,
    this.nativeArchive,
    this.documentPath,
    this.journalDay,
    this.folder,
    this.tags = const [],
  });

  static const inboxId = 'task-inbox';
  static const templateId = 'journal-template';
  final String id, title, source;
  final WebNoteKind kind;
  final DateTime modified;
  final DateTime? created;

  final String? nativeArchive, documentPath, journalDay, folder;
  final List<String> tags;
  bool get syncDocument =>
      kind != WebNoteKind.template &&
      kind != WebNoteKind.inbox &&
      kind != WebNoteKind.quickTask;

  String? get day => kind == WebNoteKind.journal
      ? journalDay ?? (id.startsWith('journal-') ? id.substring(8) : null)
      : null;

  WebNote edit(String title, String source) => WebNote(
    id,
    kind,
    title.trim(),
    source,
    DateTime.now(),
    created: created ?? modified,
    nativeArchive: nativeArchive,
    documentPath: documentPath,
    journalDay: journalDay,
    folder: folder,
    tags: tags,
  );

  WebNote organize(String? folder, List<String> tags) => WebNote(
    id,
    kind,
    title,
    source,
    DateTime.now(),
    created: created ?? modified,
    nativeArchive: nativeArchive,
    documentPath: documentPath,
    journalDay: journalDay,
    folder: folder,
    tags: tags,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'source': source,
    'modified': modified.toUtc().toIso8601String(),
    'created': ?created?.toUtc().toIso8601String(),
    'nativeArchive': ?nativeArchive,
    'documentPath': ?documentPath,
    'journalDay': ?journalDay,
    'folder': ?folder,
    if (tags.isNotEmpty) 'tags': tags,
  };

  String encode() => jsonEncode(toJson());

  factory WebNote.fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['title'] is! String ||
        value['source'] is! String ||
        value['modified'] is! String ||
        (value['created'] != null && value['created'] is! String) ||
        (value['nativeArchive'] != null && value['nativeArchive'] is! String) ||
        (value['documentPath'] != null && value['documentPath'] is! String) ||
        (value['journalDay'] != null && value['journalDay'] is! String) ||
        (value['folder'] != null && value['folder'] is! String) ||
        (value['tags'] != null &&
            (value['tags'] is! List ||
                (value['tags'] as List).any((tag) => tag is! String)))) {
      throw const FormatException('Invalid note in the browser library.');
    }
    final id = value['id'] as String;
    final title = value['title'] as String;
    final source = value['source'] as String;
    final modified = DateTime.tryParse(value['modified'] as String);
    final created = DateTime.tryParse(value['created'] as String? ?? '');
    final kind = WebNoteKind.values
        .where((k) => k.name == value['kind'])
        .firstOrNull;
    if (kind == null ||
        modified == null ||
        (value['created'] != null && created == null) ||
        title.trim().isEmpty ||
        title.length > 65536 ||
        utf8.encode(source).length > MarkdownDocument.maxTextBytes) {
      throw const FormatException('Invalid note in the browser library.');
    }
    final validId = switch (kind) {
      WebNoteKind.inbox => id == inboxId,
      WebNoteKind.quickTask => RegExp(
        r'^quick-[a-zA-Z0-9_-]{1,160}$',
      ).hasMatch(id),
      WebNoteKind.template => id == templateId,
      WebNoteKind.journal =>
        _validDayId(id) ||
            (value['journalDay'] is String &&
                _validDayId("journal-${value['journalDay']}") &&
                _validDocumentId(id)),
      _ => _validDocumentId(id),
    };
    if (!validId) throw const FormatException('Invalid note identity.');
    if (kind == WebNoteKind.quickTask) {
      QuickTodo.fromJson(id.substring(6), jsonDecode(source));
    }
    if ((kind == WebNoteKind.pdf || kind == WebNoteKind.media) &&
        value['nativeArchive'] == null) {
      throw const FormatException('The note data is missing.');
    }
    return WebNote(
      id,
      kind,
      title,
      source,
      modified,
      created: created,
      nativeArchive: value['nativeArchive'] as String?,
      documentPath: value['documentPath'] as String?,
      journalDay: value['journalDay'] as String?,
      folder: value['folder'] as String?,
      tags: List.unmodifiable((value['tags'] as List? ?? []).cast<String>()),
    );
  }

  static bool _validDocumentId(String id) =>
      id != inboxId &&
      id != templateId &&
      !id.startsWith('extra_') &&
      RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id);

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
