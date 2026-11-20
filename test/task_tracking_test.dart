import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_task.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/quick_todos.dart';
import 'package:noter/data/todo_items.dart';

void main() {
  final start = DateTime.utc(2026, 11, 20, 8);

  test('timer totals survive serialization, pause and additional sessions', () {
    DateTime minutes(int elapsed) => start.add(Duration(minutes: elapsed));
    final initial = QuickTodo(
      id: 'task',
      text: 'Check',
      created: start,
      modified: start,
    );
    var todo = initial.update(
      start,
      project: 'project',
      due: null,
      timer: TodoTimerAction.start,
    );
    todo = todo.update(
      minutes(5),
      project: todo.project,
      due: null,
      timer: TodoTimerAction.pause,
    );
    expect(todo.timerPaused, isTrue);
    expect(todo.workTimeAt(minutes(20)).inMinutes, 5);
    todo = QuickTodo.fromJson(
      todo.id,
      todo.toJson(),
    ).withProject('other-project');
    todo = todo.update(
      minutes(20),
      project: todo.project,
      due: null,
      timer: TodoTimerAction.start,
    );
    todo = todo.update(
      minutes(22),
      project: todo.project,
      due: null,
      timer: TodoTimerAction.stop,
    );
    expect(todo.workTimeAt(minutes(60)).inMinutes, 7);
    todo = todo.update(
      minutes(30),
      project: todo.project,
      due: null,
      done: true,
    );
    expect(todo.completionTime, minutes(30));
    todo = todo.update(
      minutes(40),
      project: todo.project,
      due: null,
      done: false,
    );
    expect(todo.completionTime, isNull);
    todo = todo.update(
      minutes(50),
      project: todo.project,
      due: null,
      done: true,
    );
    expect(todo.completionTime, minutes(50));
    expect(todo.workTimeAt(minutes(60)).inMinutes, 7);
  });

  test('document task metadata is portable across renames and list edits', () {
    const raw = '- [ ] First\r\n- [ ] Second\r\n';
    final first = todoListItems(raw).first;
    var source = updateDocumentTask(
      raw,
      first.offset,
      timer: TodoTimerAction.start,
      now: start,
    );
    source = todoListItems(source).first.rename(source, 'Renamed task');
    source = updateDocumentTask(
      source,
      first.offset,
      done: true,
      now: start.add(const Duration(minutes: 3)),
    );
    final items = todoListItems(source);
    expect(items.map((item) => item.text), ['Renamed task', 'Second']);
    final task = documentTask(
      source,
      first.offset,
      items.first.text,
      fallback: DateTime.utc(2027),
    );
    expect(task.completionTime, start.add(const Duration(minutes: 3)));
    expect(task.workTimeAt(DateTime.utc(2027)).inMinutes, 3);
    expect(source.split('\r\n').length, 3);
  });

  test(
    'completed view combines quick tasks and document tasks by last completion',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() => directory.delete(recursive: true));
      final repository = LocalNotebookRepository(directory);
      final store = KnowledgeStore(repository);
      const raw = '- [ ] Document task\n';
      final source = updateDocumentTask(
        raw,
        todoListItems(raw).single.offset,
        done: true,
        now: start,
      );
      await repository.create(
        'Checklist',
        MarkdownDocument(source).encode(),
        paper: 'markdown',
      );
      final quick = await store.addQuickTodo('Quick task');
      await store.changeTaskStatus(quick, true);
      final view = KnowledgeView('', openTasks: true);
      final first = await KnowledgeStore(
        repository,
      ).scan(view, completedTasks: true);
      expect(first.hits.map((hit) => hit.snippet), [
        'Quick task',
        'Document task',
      ]);
      await store.changeTask(
        first.tasks.singleWhere((task) => task.quickTodo == null),
      );
      final second = await store.scan(view, completedTasks: true);
      expect(second.hits.map((hit) => hit.snippet), ['Quick task']);
      final open = await store.scan(view);
      expect(open.hits.map((hit) => hit.snippet), ['Document task']);
    },
  );
}
