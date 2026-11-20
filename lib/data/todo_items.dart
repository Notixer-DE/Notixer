import 'markdown_document.dart';
import 'document_task.dart';

final _punctuation = RegExp(r'[\\`*_{}\[\]()<>#+\-.!|~]');
final _escapedPunctuation = RegExp(r'\\([\\`*_{}\[\]()<>#+\-.!|~])');

String todoItemText(String source) =>
    source.replaceAllMapped(_escapedPunctuation, (match) => match[1]!);

String _encodeText(String value) => value
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    .trim()
    .replaceAllMapped(_punctuation, (match) => '\\${match[0]}');

class TodoListItem {
  const TodoListItem(
    this.line,
    this.offset,
    this._start,
    this._end,
    this.text,
    this.done,
  );

  final int line, offset, _start, _end;
  final String text;
  final bool done;

  String rename(String source, String value) {
    final previous = source.substring(_start, _end);
    final metadata = previous.substring(visibleTaskText(previous).length);
    return source.replaceRange(_start, _end, ' ${_encodeText(value)}$metadata');
  }

  String check(String source, bool done) =>
      updateDocumentTask(source, offset, done: done);
}

List<TodoListItem> todoListItems(String source) {
  final items = <TodoListItem>[];
  var line = 1, nextBreak = source.indexOf('\n');
  for (final offset in markdownTaskOffsets(source)) {
    while (nextBreak >= 0 && nextBreak < offset) {
      line++;
      nextBreak = source.indexOf('\n', nextBreak + 1);
    }
    var end = nextBreak < 0 ? source.length : nextBreak;
    if (end > offset && source[end - 1] == '\r') end--;
    final start = offset + 2;
    items.add(
      TodoListItem(
        line,
        offset,
        start,
        end,
        todoItemText(visibleTaskText(source.substring(start, end)).trim()),
        source[offset] != ' ',
      ),
    );
  }
  return items;
}

String appendTodoItem(String source, String text) {
  final value = _encodeText(text);
  if (value.isEmpty) return source;
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final item = '- [ ] $value$newline';
  final separator = source.isEmpty || source.endsWith('\n') ? '' : newline;
  return '$source$separator$item';
}
