import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/ui/markdown_preview.dart';
import 'fixtures/long_markdown.dart';
import 'markdown_scroll_test.dart' show previewReady;

void main() {
  testWidgets(
    'large preview builds bounded cached blocks and ignores status-only document copies',
    (tester) async {
      final scroll = ScrollController();
      final key = GlobalKey<MarkdownPreviewState>();
      addTearDown(scroll.dispose);
      final document = MarkdownDocument(longMarkdown());
      Widget page(MarkdownDocument doc) => MaterialApp(
        builder: (_, child) => Material(child: child),
        home: CustomScrollView(
          controller: scroll,
          slivers: [
            MarkdownPreview(
              key: key,
              document: doc,
              scrollController: scroll,
              onToggle: (_, _) {},
              onFollow: (_) {},
            ),
          ],
        ),
      );
      await tester.pumpWidget(page(document));
      await previewReady(tester);
      final state = key.currentState!;
      expect(state.debugParses, 1);
      expect(
        state.debugBlockBuilds,
        lessThan(80),
        reason: 'Do not eagerly build thousands of Markdown widgets',
      );
      for (var i = 0; i < 20; i++) {
        scroll.jumpTo(scroll.offset + 500);
        await tester.pump();
      }
      expect(state.debugCachedBlocks, lessThanOrEqualTo(256));
      expect(state.debugParses, 1);
      final builds = state.debugBlockBuilds;
      await tester.pumpWidget(page(document.copy()));
      await tester.pump();
      expect(state.debugParses, 1);
      expect(state.debugBlockBuilds, builds);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an older background parse cannot replace a newer document', (
    tester,
  ) async {
    final scroll = ScrollController();
    final key = GlobalKey<MarkdownPreviewState>();
    addTearDown(scroll.dispose);
    Widget page(String source) => MaterialApp(
      builder: (_, child) => Material(child: child),
      home: CustomScrollView(
        controller: scroll,
        slivers: [
          MarkdownPreview(
            key: key,
            document: MarkdownDocument(source),
            scrollController: scroll,
            onToggle: (_, _) {},
            onFollow: (_) {},
          ),
        ],
      ),
    );
    await tester.pumpWidget(page(longMarkdown()));
    final old = key.currentState!.ready;
    await tester.pumpWidget(page('# Aktuell'));
    expect(find.text('Aktuell'), findsOneWidget);
    var finished = false;
    old.then((_) => finished = true);
    for (var i = 0; i < 300 && !finished; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(finished, isTrue);
    expect(find.text('Aktuell'), findsOneWidget);
    expect(find.text('Lange Textnotiz'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
