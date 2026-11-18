import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/ui/library_graph_page.dart';
import 'package:noter/ui/noter_theme.dart';

void main() {
  for (final graph in [false, true]) {
    testWidgets(
      '${graph ? "graph" : "search"} remains usable with a landscape phone keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('noter-ui-audit-'),
        ))!;
        final repo = LocalNotebookRepository(directory);
        await tester.runAsync(
          () => KnowledgeStore(repo).capture('A note', '- [ ] Read'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: const EdgeInsets.only(bottom: 180)),
              child: child!,
            ),
            home: graph
                ? LibraryGraphPage(repository: repo)
                : KnowledgePage(repository: repo),
          ),
        );
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tester.takeException(), isNull);
        if (graph) {
          expect(find.byType(TextField), findsNothing);
          await tester.tap(find.byTooltip('Search graph'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
}
