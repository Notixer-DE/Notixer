import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;

import '../data/knowledge.dart' show journalEntryDate;
import '../data/markdown_document.dart';
import '../data/notebook.dart';
import 'web_library.dart';

WebNote webNoteFromArchive(Uint8List archive) {
  final (note, payload, _) = LocalNotebookRepository.decodeWithInk(archive);
  validateNotebookContent(note, payload);
  final day = journalEntryDate(note);
  final kind = switch (note) {
    _ when day != null => WebNoteKind.journal,
    _ when note.isTodoList => WebNoteKind.todo,
    _ when note.isMarkdown => WebNoteKind.markdown,
    _ when note.isMedia => WebNoteKind.media,
    _ => WebNoteKind.pdf,
  };
  final result = WebNote(
    note.id,
    kind,
    note.title,
    note.isMarkdown ? MarkdownDocument.decode(payload).source : '',
    note.modified,
    created: note.created,
    documentPath: note.documentPath,
    nativeArchive: base64Encode(archive),
    journalDay: day,
    folder: note.folderName,
    tags: note.tags,
  );
  return WebNote.fromJson(result.toJson());
}

Uint8List archiveForWebNote(WebNote entry) {
  final serialized = entry.nativeArchive;
  if (serialized != null) {
    final archive = base64Decode(serialized);
    final (note, payload, ink) = LocalNotebookRepository.decodeWithInk(archive);
    final document = note.isMarkdown ? MarkdownDocument.decode(payload) : null;
    if (entry.id != note.id) {
      throw const FormatException('A note archive has the wrong identity.');
    }
    if (note.title == entry.title &&
        note.modified == entry.modified &&
        note.folderName == entry.folder &&
        listEquals(note.tags, entry.tags) &&
        (document == null || document.source == entry.source)) {
      return archive;
    }
    return LocalNotebookRepository.encode(
      note.copy(
        title: entry.title,
        modified: entry.modified,
        folderName: entry.folder,
        clearFolder: entry.folder == null,
        tags: entry.tags,
      ),
      document == null || document.source == entry.source
          ? payload
          : document.copy(source: entry.source).encode(),
      ink: ink,
    );
  }
  if (!entry.syncDocument ||
      entry.kind == WebNoteKind.pdf ||
      entry.kind == WebNoteKind.media) {
    throw const FormatException('The note data is missing.');
  }
  return LocalNotebookRepository.encode(
    metadataForWebNote(entry),
    MarkdownDocument(entry.source).encode(),
  );
}

Notebook metadataForWebNote(WebNote entry) => Notebook(
  id: entry.id,
  title: entry.title,
  paper: switch (entry.kind) {
    WebNoteKind.pdf || WebNoteKind.media => 'pdf',
    _ => 'markdown',
  },
  created: entry.created ?? entry.modified,
  modified: entry.modified,
  folderName: entry.folder,
  tags: [
    ...entry.tags,
    if (entry.kind == WebNoteKind.journal && !entry.tags.contains('Journal'))
      'Journal',
  ],
  linkPath:
      entry.documentPath ??
      switch (entry.kind) {
        WebNoteKind.todo => '${Notebook.todoListDirectory}/${entry.id}.md',
        WebNoteKind.journal => 'journals/${entry.day}.md',
        _ => null,
      },
);

MarkdownDocument markdownForWebNote(WebNote note) {
  final archive = note.nativeArchive;
  if (archive == null) return MarkdownDocument(note.source);
  final (_, payload) = LocalNotebookRepository.decode(base64Decode(archive));
  return MarkdownDocument.decode(payload).copy(source: note.source);
}

WebNote webNoteFromFile(
  String id,
  String title,
  String paper,
  Uint8List payload,
) {
  final now = DateTime.now();
  final note = Notebook(
    id: id,
    title: title,
    paper: paper,
    created: now,
    modified: now,
  );
  validateNotebookContent(note, payload);
  return webNoteFromArchive(LocalNotebookRepository.encode(note, payload));
}
