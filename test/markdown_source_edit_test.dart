import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/ui/markdown_source_edit.dart';

void main() {
  test('Tab at the start of an empty document inserts spaces', () {
    final result = indentMarkdown(
      const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
    );
    expect(result.text, '    ');
    expect(result.selection.extentOffset, 4);
  });

  test('backward selection preserves direction and excludes the next line', () {
    const original = TextEditingValue(
      text: 'one\r\ntwo\r\nthree',
      selection: TextSelection(baseOffset: 10, extentOffset: 1),
    );
    final result = indentMarkdown(original);
    expect(result.text, '    one\r\n    two\r\nthree');
    expect(result.selection.baseOffset, 18);
    expect(result.selection.extentOffset, 5);
    expect(indentMarkdown(result, outdent: true), original);
  });

  test(
    'outdent removes a tab or up to four leading spaces without deleting text',
    () {
      final result = indentMarkdown(
        const TextEditingValue(
          text: '\talpha\n  beta\ngamma',
          selection: TextSelection(baseOffset: 0, extentOffset: 19),
        ),
        outdent: true,
      );
      expect(result.text, 'alpha\nbeta\ngamma');
      expect(
        result.selection,
        const TextSelection(baseOffset: 0, extentOffset: 16),
      );
    },
  );

  test('outdent at a caret removes only its current line indentation', () {
    final result = indentMarkdown(
      const TextEditingValue(
        text: '    one\n    two',
        selection: TextSelection.collapsed(offset: 10),
      ),
      outdent: true,
    );
    expect(result.text, '    one\ntwo');
    expect(result.selection.extentOffset, 8);
  });
}
