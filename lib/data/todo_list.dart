import 'markdown_document.dart';
import 'notebook.dart';

export 'todo_items.dart';

Future<Notebook> createTodoList(NotebookRepository repository, String title) {
  final id = LocalNotebookRepository.newId();
  final now = DateTime.now();
  return repository.save(
    Notebook(
      id: id,
      title: title.trim().isEmpty ? 'New to-do list' : title.trim(),
      created: now,
      modified: now,
      paper: 'markdown',
      linkPath: '${Notebook.todoListDirectory}/$id.md',
    ),
    MarkdownDocument('').encode(),
  );
}
