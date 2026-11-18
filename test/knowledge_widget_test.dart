import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/ui/noter_theme.dart';

Future<void> waitKnowledge(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (ready() &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(AlertDialog).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Knowledge operation did not finish.');
}

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook note;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-hub-ui-');
    repository = LocalNotebookRepository(directory);
    note = await KnowledgeStore(repository).capture(
      'Source note',
      '# Outline\n\n- [ ] Read the chapter\n- [x] Finished',
    );
    FileGateway.beforeClose = null;
    FileGateway.workspaceBeforeClose = null;
    FileGateway.fallbackBeforeClose = null;
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets(
      'hub tasks can be completed and sections fit at width ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            home: KnowledgePage(
              repository: repository,
              initialSection: 'Tasks',
            ),
          ),
        );
        await waitKnowledge(
          tester,
          () => find.text('Read the chapter').evaluate().isNotEmpty,
        );
        expect(find.text('Finished'), findsNothing);
        await tester.tap(find.byType(Checkbox).first);
        await waitKnowledge(
          tester,
          () => find.text('No matches.').evaluate().isNotEmpty,
        );
        final document = await tester.runAsync(
          () async => MarkdownDocument.decode(await repository.load(note.id)),
        );
        expect(document!.source, contains('- [x] Read the chapter'));
        for (final section in [
          'Journal',
          'Templates',
          'Tags',
          'Views',
          'Backups',
          'Search',
        ]) {
          final chip = find.widgetWithText(ChoiceChip, section);
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('renaming a selected tag leaves search filters valid', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: KnowledgePage(repository: repository),
      ),
    );
    await waitKnowledge(
      tester,
      () => find.text('All tags').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('All tags'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inbox').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Tags'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#Inbox'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Captured');
    await tester.tap(find.text('Save'));
    await waitKnowledge(
      tester,
      () => find.text('#Captured').evaluate().isNotEmpty,
    );
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Search'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Search'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'journal creates a dated template entry and returns its destination',
    (tester) async {
      KnowledgeDestination? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open journal'),
                onPressed: () async {
                  selected = await Navigator.push<KnowledgeDestination>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => KnowledgePage(
                        repository: repository,
                        initialSection: 'Journal',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open journal'));
      await waitKnowledge(
        tester,
        () => find.text('Open day').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Open day'));
      await waitKnowledge(tester, () => selected != null);
      expect(selected!.note.tags, contains('Journal'));
      final document = await tester.runAsync(
        () async =>
            MarkdownDocument.decode(await repository.load(selected!.note.id)),
      );
      expect(document!.source, contains('## Reflection'));
      expect(document.source, isNot(contains('{{date}}')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('templates are editable and persist in the hub', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: KnowledgePage(
          repository: repository,
          initialSection: 'Templates',
        ),
      ),
    );
    await waitKnowledge(
      tester,
      () => find.text('Daily journal').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Create Markdown template'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Template name'),
      'Meeting',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Markdown'),
      '# {{title}}\n- [ ] Agenda',
    );
    await tester.tap(find.text('Save template'));
    await waitKnowledge(
      tester,
      () => find.text('Meeting').evaluate().isNotEmpty,
    );
    final store = KnowledgeStore(repository);
    await tester.runAsync(store.load);
    expect(
      store.templates.singleWhere((t) => t.name == 'Meeting').source,
      '# {{title}}\n- [ ] Agenda',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
