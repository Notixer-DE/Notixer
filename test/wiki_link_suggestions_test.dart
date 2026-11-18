import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/wiki_link_suggestions.dart';

void main() {
  for (final moveIntoCode in [false, true]) {
    testWidgets(
      'stale wiki options cannot be used after ${moveIntoCode ? "moving into code" : "changing query"}',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('noter-wiki-audit-'),
        ))!;
        final repository = LocalNotebookRepository(directory);
        final notes = (await tester.runAsync(() async {
          final store = KnowledgeStore(repository);
          return [
            await store.capture('Current', 'Text'),
            await store.capture('Other', 'Text'),
          ];
        }))!;
        final controller = TextEditingController.fromValue(
          const TextEditingValue(
            text: '[[O\n\n```text\n[[O',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        final key = GlobalKey<WikiLinkSuggestionsState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WikiLinkSuggestions(
                key: key,
                controller: controller,
                note: notes.first,
                notes: notes,
                repository: repository,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        for (var i = 0; i < 100 && find.text('Other').evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('Other'), findsOneWidget);
        final staleTap = tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Other'))
            .onTap!;
        if (moveIntoCode) {
          controller.selection = TextSelection.collapsed(
            offset: controller.text.length,
          );
        } else {
          controller.value = const TextEditingValue(
            text: '[[Missing',
            selection: TextSelection.collapsed(offset: 9),
          );
        }
        final unchangedText = controller.text;
        staleTap();
        expect(controller.text, unchangedText);
        await tester.pump();
        expect(
          key.currentState!.handleKey(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.enter,
              logicalKey: LogicalKeyboardKey.enter,
              timeStamp: Duration.zero,
            ),
          ),
          isFalse,
        );
        expect(find.text('Other'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
}
