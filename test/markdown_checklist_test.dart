import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/ui/markdown_preview.dart';

void main() {
  final cases = <String, (String, List<String>, List<bool>)>{
    'loose list': (
      '- [ ] Erste\n\n- [X] Zweite\n\n- [x] Dritte',
      ['[ ] Erste', '[X] Zweite', '[x] Dritte'],
      [false, true, true],
    ),
    'nested and quoted': (
      '- [ ] Eltern\n  - [X] Kind\n\n> - [ ] Zitat\n\n- [x] Ende',
      ['[ ] Eltern', '[X] Kind', '[ ] Zitat', '[x] Ende'],
      [false, true, false, true],
    ),
    'CRLF, tabs and alternate bullets': (
      '*   [X]\tStern\r\n\r\n+ [ ] Plus\r\n\r\n1. [x] Nummer\r\n',
      ['[X]\tStern', '[ ] Plus', '[x] Nummer'],
      [true, false, true],
    ),
    'empty tasks': (
      '- [ ]\n\n- [X]\r\n\r\n- [x] Fertig',
      ['[ ]', '[X]', '[x] Fertig'],
      [false, true, true],
    ),
    'task with fenced code': (
      '- [ ] ```dart\n  - [ ] Kein Task im Code\n  ```\n\n- [x] Echt',
      ['[ ] ```', '[x] Echt'],
      [false, true],
    ),
    'task with block label': (
      '- [ ] ## Überschrift\n\n- [X] > Zitat\n\n- [ ] Weiter',
      ['[ ] ##', '[X] >', '[ ] Weiter'],
      [false, true, false],
    ),
    'literal examples are not tasks': (
      '```\n- [ ]\n- [x] Code\n```\n\n'
          '    - [ ] Eingerückter Code\n\n'
          r'- \[ ] Escaped'
          '\n\n- [ ] Echt',
      ['[ ] Echt'],
      [false],
    ),
  };
  for (final entry in cases.entries) {
    testWidgets(
      'checklist renders and toggles exact source positions: ${entry.key}',
      (tester) async {
        final (original, markers, values) = entry.value;
        var source = original;
        final expected = [
          for (final marker in markers) original.indexOf(marker) + 1,
        ];
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        late StateSetter rebuild;
        int? changed;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return CustomScrollView(
                    controller: scroll,
                    slivers: [
                      MarkdownPreview(
                        document: MarkdownDocument(source),
                        scrollController: scroll,
                        onFollow: (_) {},
                        onToggle: (offset, checked) {
                          changed = offset;
                          rebuild(
                            () => source = source.replaceRange(
                              offset,
                              offset + 1,
                              checked ? 'x' : ' ',
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        final boxes = find.byType(Checkbox);
        expect(boxes, findsNWidgets(values.length));
        expect(tester.widgetList<Checkbox>(boxes).map((c) => c.value), values);
        for (var i = 0; i < values.length; i++) {
          tester.widget<Checkbox>(boxes.at(i)).onChanged!(!values[i]);
          await tester.pumpAndSettle();
          expect(changed, expected[i]);
          expect(source[expected[i]], values[i] ? ' ' : 'x');
        }
        // Toggling may change only the checkbox characters, never CRLF, code,
        // escaping, indentation or the user's Markdown syntax.
        var expectedSource = original;
        for (var i = 0; i < expected.length; i++) {
          expectedSource = expectedSource.replaceRange(
            expected[i],
            expected[i] + 1,
            values[i] ? ' ' : 'x',
          );
        }
        expect(source, expectedSource);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
