import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noter/web/web_library.dart';

void main() {
  final modified = DateTime.utc(2026, 11, 20);
  final notes = [
    WebNote(
      'note-text',
      WebNoteKind.markdown,
      'Reference',
      '# Markdown',
      modified,
    ),
    WebNote(
      'note-list',
      WebNoteKind.todo,
      'Project',
      '- [ ] Next action',
      modified,
    ),
    WebNote(
      WebNote.inboxId,
      WebNoteKind.inbox,
      'Unsorted to-dos',
      '- [x] Pick up mail',
      modified,
    ),
    WebNote(
      'journal-2026-11-20',
      WebNoteKind.journal,
      '2026-11-20',
      'A log entry',
      modified,
    ),
    WebNote(
      WebNote.templateId,
      WebNoteKind.template,
      'Journal template',
      '# {{date}}',
      modified,
    ),
  ];

  test('web backup round-trips the library, inbox and journal settings', () {
    final restored = decodeWebBackup(encodeWebBackup(notes));
    expect(
      restored.map((note) => note.toJson()),
      notes.map((note) => note.toJson()),
    );
    expect(
      restored.singleWhere((note) => note.kind == WebNoteKind.journal).day,
      '2026-11-20',
    );
  });

  test('web backup rejects invalid or duplicate entries', () {
    expect(
      () => decodeWebBackup(encodeWebBackup([notes.first, notes.first])),
      throwsFormatException,
    );
    final invalid = notes[3].toJson()..['id'] = 'journal-2026-02-30';
    final backup = jsonEncode({
      'format': 'notixer-web-library',
      'version': 1,
      'notes': [notes.first.toJson(), invalid],
    });
    expect(() => decodeWebBackup(backup), throwsFormatException);
  });
}
