import 'document_task.dart';
import 'markdown_document.dart';
import 'notebook.dart';
import 'todo_items.dart';

class LinkedTaskOccurrence {
  const LinkedTaskOccurrence({
    required this.note,
    required this.line,
    required this.offset,
    required this.text,
    required this.done,
    required this.linkId,
  });

  final Notebook note;
  final int line, offset;
  final String text, linkId;
  final bool done;

  String get anchor => 'line=$line';
}

class LinkedTaskGroup {
  const LinkedTaskGroup({
    required this.linkId,
    required this.text,
    required this.done,
    required this.others,
  });

  final String linkId, text;
  final bool done;
  final List<LinkedTaskOccurrence> others;
}

Future<List<LinkedTaskGroup>> findLinkedTaskGroups(
  NotebookRepository repository,
  Notebook currentNote,
  String currentSource, {
  Map<String, String> openSources = const {},
}) async {
  final localTasks = linkedDocumentTasks(currentSource);
  if (localTasks.isEmpty) return const [];
  final localById = <String, LinkedDocumentTask>{};
  for (final task in localTasks) {
    localById.putIfAbsent(task.linkId, () => task);
  }
  final matchesByLinkId = <String, List<LinkedTaskOccurrence>>{};
  for (final note in await repository.list()) {
    if (!note.isMarkdown || note.id == currentNote.id) continue;
    String source;
    try {
      source =
          openSources[note.id] ??
          (await decodeMarkdownAsync(await repository.load(note.id))).source;
    } catch (_) {
      continue;
    }
    if (!source.contains('<!-- notixer-task ')) continue;
    for (final task in linkedDocumentTasks(source)) {
      if (!localById.containsKey(task.linkId)) continue;
      matchesByLinkId
          .putIfAbsent(task.linkId, () => [])
          .add(
            LinkedTaskOccurrence(
              note: note,
              line: task.line,
              offset: task.offset,
              text: note.isTodoList ? todoItemText(task.text) : task.text,
              done: task.done,
              linkId: task.linkId,
            ),
          );
    }
  }
  final groups = <LinkedTaskGroup>[];
  for (final entry in localById.entries) {
    final others = matchesByLinkId[entry.key];
    if (others == null || others.isEmpty) continue;
    others.sort((a, b) {
      final byTitle = a.note.title.toLowerCase().compareTo(
        b.note.title.toLowerCase(),
      );
      return byTitle != 0 ? byTitle : a.line.compareTo(b.line);
    });
    final local = entry.value;
    groups.add(
      LinkedTaskGroup(
        linkId: entry.key,
        text: currentNote.isTodoList ? todoItemText(local.text) : local.text,
        done: local.done,
        others: List.unmodifiable(others),
      ),
    );
  }
  return groups;
}

Future<List<Notebook>> syncLinkedTaskStatus(
  LocalNotebookRepository repository,
  String linkId, {
  required bool done,
  String? excludeNoteId,
  Future<bool> Function(String noteId, String linkId, bool done)?
  updateOpenNote,
  DateTime? now,
}) async {
  if (!validTaskLinkId(linkId)) return const [];
  final updatedNotes = <Notebook>[];
  for (final note in await repository.list()) {
    if (!note.isMarkdown || note.id == excludeNoteId) continue;
    if (updateOpenNote != null && await updateOpenNote(note.id, linkId, done)) {
      continue;
    }
    final snapshot = await repository.snapshotForSync(note.id);
    if (snapshot == null) continue;
    final (current, bytes) = await LocalNotebookRepository.decodeValidated(
      snapshot.archive,
    );
    final document = await decodeMarkdownAsync(bytes);
    if (!document.source.contains('<!-- notixer-task ')) continue;
    final updatedSource = syncDocumentTasksByLinkId(
      document.source,
      linkId,
      done: done,
      previousModified: current.modified,
      now: now,
    );
    if (updatedSource == document.source) continue;
    final updatedNote = current.copy(modified: now ?? DateTime.now());
    final archive = await LocalNotebookRepository.encodeAsync(
      updatedNote,
      document.copy(source: updatedSource).encode(),
    );
    await repository.applySync(current.id, snapshot.raw, archive);
    updatedNotes.add(updatedNote);
  }
  return updatedNotes;
}
