import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/ui/markdown_preview.dart';

void main() {
  for (final scale in [1.0, 1.6]) {
    testWidgets('checkbox centres on first line at text scale $scale', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SizedBox(
                width: 260,
                child: CustomScrollView(
                  controller: scroll,
                  slivers: [
                    MarkdownPreview(
                      document: MarkdownDocument(
                        '- [ ] First line with enough words to wrap onto several lines',
                      ),
                      scrollController: scroll,
                      onFollow: (_) {},
                      onToggle: (_, _) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.byType(SelectableText).first;
      final text = tester.widget<SelectableText>(label);
      final metrics = TextPainter(
        text: TextSpan(
          style: DefaultTextStyle.of(tester.element(label)).style,
          children: [text.textSpan!],
        ),
        strutStyle: text.strutStyle,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(scale),
      )..layout(maxWidth: tester.getSize(label).width);
      final line = metrics.computeLineMetrics().first;
      final firstCentre = tester.getTopLeft(label).dy + line.height / 2;
      expect(
        tester.getCenter(find.byType(Checkbox)).dy,
        closeTo(firstCentre, .5),
      );
      expect(
        tester.getSize(find.byType(Checkbox)).height,
        greaterThanOrEqualTo(44),
      );
      metrics.dispose();
    });
  }

  final cases = <String, (String, List<String>, List<bool>)>{
    'loose list': (
      '- [ ] First\n\n- [X] Second\n\n- [x] Third',
      ['[ ] First', '[X] Second', '[x] Third'],
      [false, true, true],
    ),
    'nested and quoted': (
      '- [ ] Parent\n  - [X] Child\n\n> - [ ] Quote\n\n- [x] End',
      ['[ ] Parent', '[X] Child', '[ ] Quote', '[x] End'],
      [false, true, false, true],
    ),
    'same-line list nesting': (
      '- - [ ] Nested bullet\n\n1. - [X] Nested number\n\n'
          '> - 1. [ ] Nested quote\n\n- + [x]\n\n- [ ] After',
      [
        '[ ] Nested bullet',
        '[X] Nested number',
        '[ ] Nested quote',
        '[x]',
        '[ ] After',
      ],
      [false, true, false, true, false],
    ),
    'CRLF, tabs and alternate bullets': (
      '*   [X]\tStar\r\n\r\n+ [ ] Plus\r\n\r\n1. [x] Number\r\n',
      ['[X]\tStar', '[ ] Plus', '[x] Number'],
      [true, false, true],
    ),
    'empty tasks': (
      '- [ ]\n\n- [X]\r\n\r\n- [x] Done',
      ['[ ]', '[X]', '[x] Done'],
      [false, true, true],
    ),
    'task with fenced code': (
      '- [ ] ```dart\n  - [ ] Not a task in code\n  ```\n\n- [x] Real',
      ['[ ] ```', '[x] Real'],
      [false, true],
    ),
    'task with block label': (
      '- [ ] ## Heading\n\n- [X] > Quote\n\n- [ ] Weiter',
      ['[ ] ##', '[X] >', '[ ] Weiter'],
      [false, true, false],
    ),
    'literal examples are not tasks': (
      '```\n- [ ]\n- [x] Code\n```\n\n'
          '    - [ ] Indented code\n\n'
          r'- \[ ] Escaped'
          '\n\n- [ ] Real',
      ['[ ] Real'],
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
