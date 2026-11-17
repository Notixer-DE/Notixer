import 'package:flutter/services.dart';

/// Four spaces also form an indented Markdown code block outside a list.
TextEditingValue indentMarkdown(
  TextEditingValue value, {
  bool outdent = false,
}) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid) return value;
  if (selection.isCollapsed && !outdent) {
    return TextEditingValue(
      text: text.replaceRange(selection.start, selection.end, '    '),
      selection: TextSelection.collapsed(offset: selection.start + 4),
    );
  }
  final start = selection.start == 0
      ? 0
      : text.lastIndexOf('\n', selection.start - 1) + 1;
  final end =
      !selection.isCollapsed &&
          selection.end > start &&
          text[selection.end - 1] == '\n'
      ? selection.end - 1
      : selection.end;
  final edits = <(int, int, String)>[];
  for (var line = start; line <= end;) {
    var remove = 0;
    if (outdent) {
      if (line < text.length && text[line] == '\t') {
        remove = 1;
      } else {
        while (remove < 4 &&
            line + remove < text.length &&
            text[line + remove] == ' ') {
          remove++;
        }
      }
    }
    edits.add((line, remove, outdent ? '' : '    '));
    final next = text.indexOf('\n', line);
    if (next < 0) break;
    line = next + 1;
  }
  int offset(int original) {
    var result = original;
    for (final (position, remove, insert) in edits) {
      if (original >= position) {
        result += insert.length - (original - position).clamp(0, remove);
      }
    }
    return result;
  }

  var updated = text;
  for (final (position, remove, insert) in edits.reversed) {
    updated = updated.replaceRange(position, position + remove, insert);
  }
  return TextEditingValue(
    text: updated,
    selection: TextSelection(
      baseOffset: offset(selection.baseOffset),
      extentOffset: offset(selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    ),
  );
}
