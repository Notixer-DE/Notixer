import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/ui/markdown_preview.dart';
import 'package:noter/ui/noter_theme.dart';

import 'fixtures/long_markdown.dart';

void main() {
  testWidgets(
    'list splitting preserves numbering, nesting and reference links',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      String? followed;
      int? toggled;
      const source =
          '7. Seven\n8. Eight\n   - Child\n\n'
          '- [ ] [Task][target]\n\n'
          '[target]: https://example.org/target\n';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: scroll,
              slivers: [
                MarkdownPreview(
                  document: MarkdownDocument(source),
                  scrollController: scroll,
                  onToggle: (offset, _) => toggled = offset,
                  onFollow: (href) => followed = href,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('7.'), findsOneWidget);
      expect(find.text('8.'), findsOneWidget);
      expect(find.text('Child', findRichText: true), findsOneWidget);
      await tester.tap(find.text('Task', findRichText: true));
      await tester.pump();
      expect(followed, 'https://example.org/target');
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(toggled, source.indexOf('[ ]') + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('long Markdown keeps a bounded viewport at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final key = GlobalKey<MarkdownPreviewState>();
      final document = MarkdownDocument(longMarkdown());
      Widget page() => MaterialApp(
        theme: NoterTheme.light,
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              MarkdownPreview(
                key: key,
                document: document,
                scrollController: scroll,
                onToggle: (_, _) {},
                onFollow: (_) {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page());
      await previewReady(tester);
      expect(find.text('Long text note'), findsOneWidget);
      expect(find.text('Section 999'), findsNothing);
      final sliver = find.descendant(
        of: find.byType(MarkdownPreview),
        matching: find.byType(SliverList),
      );
      final initial = tester.widget<SliverList>(sliver).delegate;
      for (var i = 0; i < 40; i++) {
        scroll.jumpTo(scroll.offset + 400);
        await tester.pump(const Duration(milliseconds: 16));
        // Hundreds of blocks have passed; neither the start nor the whole
        // document should remain mounted (including selectable paragraphs).
        expect(find.byType(SelectableText).evaluate().length, lessThan(80));
        expect(find.byType(Checkbox).evaluate().length, lessThan(40));
        expect(tester.widget<SliverList>(sliver).delegate, same(initial));
      }
      expect(find.text('Long text note'), findsNothing);
      // An unrelated parent rebuild must reuse parsed/built Markdown blocks.
      final before = (initial as SliverChildBuilderDelegate).builder(
        key.currentContext!,
        0,
      );
      await tester.pumpWidget(page());
      final after =
          tester.widget<SliverList>(sliver).delegate
              as SliverChildBuilderDelegate;
      expect(after.builder(key.currentContext!, 0), same(before));
      // Lazy headings must still be reachable even at the end of a long note.
      final navigation = key.currentState!.scrollToHeading('section-999');
      await tester.pumpAndSettle();
      expect(await navigation, isTrue);
      expect(find.text('Section 999'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'one long checklist virtualizes items and retains source offsets',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final source = [
        '```\n- [ ] Code only\n```\n',
        for (var i = 0; i < 2000; i++) '- [ ] Task $i',
      ].join('\n');
      int? toggled;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: scroll,
              slivers: [
                MarkdownPreview(
                  document: MarkdownDocument(source),
                  scrollController: scroll,
                  onToggle: (offset, _) => toggled = offset,
                  onFollow: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await previewReady(tester);
      for (var i = 0; i < 20; i++) {
        scroll.jumpTo(scroll.offset + 400);
        await tester.pump();
        expect(find.byType(Checkbox).evaluate().length, lessThan(40));
      }
      final checkbox =
          find.byType(Checkbox).evaluate().first.widget as Checkbox;
      checkbox.onChanged!(true);
      expect(toggled, isNotNull);
      expect(toggled, greaterThan(source.indexOf('Task 100')));
      expect(markdownTaskOffsets(source), contains(toggled));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> previewReady(WidgetTester tester) async {
  final state = tester.state<MarkdownPreviewState>(
    find.byType(MarkdownPreview),
  );
  var ready = false;
  state.ready.then((_) => ready = true);
  for (var i = 0; i < 300 && !ready; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready, isTrue);
  await tester.pump();
}
