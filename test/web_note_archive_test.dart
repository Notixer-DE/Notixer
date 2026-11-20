import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/web/web_library.dart';
import 'package:noter/web/web_note_archive.dart';

void main() {
  final created = DateTime.utc(2026, 3, 5);
  final modified = DateTime.utc(2026, 3, 7);
  final assets = {
    'assets/page.png': Uint8List.fromList([1, 2, 3]),
  };

  test(
    'browser Markdown edits preserve the native archive metadata and assets',
    () {
      final original = Notebook(
        id: 'test-archive',
        title: 'Native note',
        paper: 'markdown',
        created: created,
        modified: modified,
        linkPath: 'linked/notebook.md',
        folderName: 'Research',
        tags: ['native'],
      );
      final archive = LocalNotebookRepository.encode(
        original,
        MarkdownDocument('# Original', assets).encode(),
      );
      final browser = webNoteFromArchive(archive);
      expect(browser.documentPath, 'linked/notebook.md');
      expect(markdownForWebNote(browser).assets, assets);
      expect(archiveForWebNote(browser), orderedEquals(archive));

      final edited = browser.edit('Edited on Web', '# Updated').organize(
        'Archive',
        ['web'],
      );
      final (note, bytes) = LocalNotebookRepository.decode(
        archiveForWebNote(edited),
      );
      expect(note.title, 'Edited on Web');
      expect(note.created, created);
      expect(note.documentPath, original.documentPath);
      expect(note.folderName, 'Archive');
      expect(note.tags, ['web']);
      final document = MarkdownDocument.decode(bytes);
      expect(document.source, '# Updated');
      expect(document.assets, assets);
    },
  );

  test('browser journal and to-do lists use native identities', () {
    final day = WebNote(
      'journal-2026-03-05',
      WebNoteKind.journal,
      'Daily notes',
      '# Journal',
      created,
    ).edit('Daily notes', '# Updated journal');
    final todo = WebNote(
      'note-tasks',
      WebNoteKind.todo,
      'Tasks',
      '- [ ] Do it',
      created,
    );
    final restoredDay = webNoteFromArchive(archiveForWebNote(day));
    final restoredTodo = webNoteFromArchive(archiveForWebNote(todo));
    expect(restoredDay.day, '2026-03-05');
    expect(restoredDay.documentPath, 'journals/2026-03-05.md');
    expect(restoredDay.created, created);
    expect(restoredTodo.kind, WebNoteKind.todo);
    expect(restoredTodo.source, '- [ ] Do it');
  });
}
