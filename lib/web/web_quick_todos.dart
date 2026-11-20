import 'dart:convert';

import '../data/markdown_document.dart';
import '../data/notebook.dart';
import '../data/quick_todos.dart';
import '../data/todo_items.dart';
import '../sync/sync_revision.dart';
import 'browser_library.dart';
import 'web_library.dart';

class WebQuickTodos {
  WebQuickTodos(this.library);

  final BrowserLibrary library;
  static const _kind = 'quick-todo';

  Future<List<QuickTodo>> read() async {
    final extras = library.extras;
    final tasks = <String, QuickTodo>{};
    for (final id in await extras.syncIds()) {
      final snapshot = await extras.snapshotForSync(id);
      if (snapshot == null) continue;
      final (note, payload) = LocalNotebookRepository.decode(snapshot.archive);
      if (!note.isMarkdown || note.tags.length != 1) continue;
      final metadata = jsonDecode(note.tags.single);
      if (metadata is! Map || metadata['kind'] != _kind) continue;
      final taskId = metadata['key'] as String;
      final todo = QuickTodo.fromJson(
        taskId,
        jsonDecode(MarkdownDocument.decode(payload).source),
      );
      final previous = tasks[taskId];
      if (previous == null || todo.supersedes(previous)) tasks[taskId] = todo;
    }
    return tasks.values.toList()
      ..sort((a, b) => a.created.compareTo(b.created));
  }

  Future<void> write(QuickTodo todo, {QuickTodo? previous}) async {
    final extras = library.extras;
    final key = libraryExtraId(_kind, todo.id);
    final snapshot = await extras.snapshotForSync(key);
    if (previous != null) {
      final current = (await read())
          .where((entry) => entry.id == todo.id)
          .firstOrNull;
      if (current?.revision != previous.revision) {
        throw StateError('The to-do changed in another tab.');
      }
    } else if (snapshot != null) {
      return;
    }
    final metadata = Notebook(
      id: key,
      title: 'Quick to-do',
      created: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      modified: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      paper: 'markdown',
      tags: [
        jsonEncode({'kind': _kind, 'key': todo.id}),
      ],
    );
    await extras.applySync(
      key,
      snapshot?.raw,
      LocalNotebookRepository.encode(
        metadata,
        MarkdownDocument(jsonEncode(todo.toJson())).encode(),
      ),
    );
  }

  Future<void> migrate() async {
    for (final note in await library.readAll()) {
      if (note.kind == WebNoteKind.inbox) {
        for (final item in todoListItems(note.source)) {
          final identity = libraryExtraId(
            'browser-inbox',
            '${note.modified.toUtc()}:${item.offset}',
          ).substring(6);
          await write(
            QuickTodo(
              id: 'web-$identity',
              text: item.text,
              done: item.done,
              created: note.modified,
              modified: note.modified,
            ),
          );
        }
      } else if (note.kind == WebNoteKind.quickTask) {
        final task = QuickTodo.fromJson(
          note.id.substring(6),
          jsonDecode(note.source),
        );
        await write(task);
      } else {
        continue;
      }
      await library.delete(note);
    }
  }

  Future<List<WebNote>> backup() async => [
    for (final todo in await read())
      WebNote(
        'quick-${todo.id}',
        WebNoteKind.quickTask,
        todo.text,
        jsonEncode(todo.toJson()),
        todo.modified,
      ),
  ];
}
