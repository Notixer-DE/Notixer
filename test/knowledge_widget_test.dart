import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/ui/library.dart';
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

Future<void> openSection(WidgetTester tester, String section) async {
  final destination = find.byKey(ValueKey('knowledge-section-$section'));
  if (destination.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('knowledge-more-sections')));
    await tester.pumpAndSettle();
    if (destination.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        destination,
        100,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        ),
      );
    }
  }
  await tester.ensureVisible(destination);
  await tester.tap(destination);
  await waitKnowledge(tester, () => true);
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
  testWidgets('plan a to-do from Unsorted and review Today and Projects', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final store = KnowledgeStore(repository);
      final overdue = await store.addQuickTodo('Overdue draft');
      final future = await store.addQuickTodo('Future draft');
      await store.addQuickTodo('Review plan');
      final tasks = (await store.scan(
        const KnowledgeView('', openTasks: true),
      )).tasks;
      final now = DateTime.now();
      await store.planQuickTodo(
        tasks.singleWhere((task) => task.note.id == overdue.id),
        projectId: null,
        due: DateUtils.addDaysToDate(now, -1),
      );
      await store.planQuickTodo(
        tasks.singleWhere((task) => task.note.id == future.id),
        projectId: null,
        due: DateUtils.addDaysToDate(now, 1),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: KnowledgePage(repository: repository, initialSection: 'Tasks'),
      ),
    );
    await waitKnowledge(
      tester,
      () => find.text('Review plan').evaluate().isNotEmpty,
    );
    expect(find.text('Read the chapter'), findsOneWidget);

    Future<void> view(String name) async {
      await tester.tap(find.byKey(ValueKey('task-view-$name')));
      await tester.pump();
    }

    Finder row(String title) => find.widgetWithText(ListTile, title);
    final review = row('Review plan');
    final plan = find.descendant(
      of: review,
      matching: find.byTooltip('Plan to-do'),
    );
    await view('unsorted');
    expect(find.text('Read the chapter'), findsNothing);
    expect(review, findsOneWidget);
    await tester.tap(plan);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New project…').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Project name'),
      'Launch',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set due date'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitKnowledge(
      tester,
      () =>
          find.text('Overdue draft').evaluate().isNotEmpty &&
          review.evaluate().isEmpty,
    );

    await view('today');
    final overdue = row('Overdue draft');
    expect(overdue, findsOneWidget);
    expect(review, findsOneWidget);
    expect(find.text('Future draft'), findsNothing);
    expect(
      tester.getTopLeft(overdue).dy,
      lessThan(tester.getTopLeft(review).dy),
    );
    await tester.tap(
      find.descendant(of: overdue, matching: find.byType(Checkbox)),
    );
    await waitKnowledge(
      tester,
      () => overdue.evaluate().isEmpty && review.evaluate().isNotEmpty,
    );

    await view('projects');
    expect(find.textContaining('Launch · Due'), findsOneWidget);
    await tester.tap(plan);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final unsorted = find.text('Unsorted').last;
    await tester.tap(unsorted);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    await tester.tap(find.byTooltip('Clear due date'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitKnowledge(
      tester,
      () => find.text('No open project to-dos.').evaluate().isNotEmpty,
    );
    await view('today');
    expect(find.text('No open to-dos due today or overdue.'), findsOneWidget);
    await view('unsorted');
    expect(review, findsOneWidget);
    await view('all');
    await waitKnowledge(
      tester,
      () => find.text('Read the chapter').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('library quick to-do saves directly to unsorted tasks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: LibraryPage(repository: repository),
      ),
    );
    await waitKnowledge(
      tester,
      () => find.text('Source note').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Add to-do'));
    final dialog = find.widgetWithText(AlertDialog, 'Add to-do');
    for (var i = 0; i < 100 && dialog.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(dialog, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      'Send the meeting notes',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await waitKnowledge(
      tester,
      () => find.text('View to-dos').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('View to-dos'));
    await waitKnowledge(
      tester,
      () => find.byType(Checkbox).evaluate().isNotEmpty,
    );
    expect(find.text(unsortedTodos), findsWidgets);
    expect(find.text('Send the meeting notes'), findsOneWidget);
    expect(find.text('Read the chapter'), findsNothing);
    await tester.tap(find.byType(Checkbox));
    await waitKnowledge(
      tester,
      () => find.text('No open unsorted to-dos.').evaluate().isNotEmpty,
    );
    (Notebook, MarkdownDocument)? savedTodo;
    final read = repository.list().then((notes) async {
      final saved = notes.singleWhere(
        (note) => note.tags.contains(unsortedTodos),
      );
      savedTodo = (
        saved,
        MarkdownDocument.decode(await repository.load(saved.id)),
      );
    });
    await waitKnowledge(tester, () => savedTodo != null);
    await read;
    final (saved, document) = savedTodo!;
    expect(saved.title, 'Send the meeting notes');
    expect(document.source, '- [x] Send the meeting notes\n');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shared text survives a failed save and capture can be retried', (
    tester,
  ) async {
    FileGateway.sharedText.value = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: LibraryPage(repository: repository),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (find.text('Source note').evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    FileGateway.workspaceBeforeClose = () async => false;
    FileGateway.sharedText.value = 'A shared paragraph';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(FileGateway.sharedText.value, 'A shared paragraph');
    expect(find.byType(KnowledgePage), findsNothing);
    FileGateway.workspaceBeforeClose = () async => true;
    await tester.tap(find.text('Retry capture'));
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
    }
    expect(find.widgetWithText(AlertDialog, 'Quick capture'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Text or Markdown'))
          .controller!
          .text,
      'A shared paragraph',
    );
    expect(FileGateway.sharedText.value, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    FileGateway.workspaceBeforeClose = null;
  });

  for (final (size, platform) in const [
    (Size(390, 844), TargetPlatform.android),
    (Size(844, 390), TargetPlatform.android),
    (Size(1024, 1000), TargetPlatform.android),
    (Size(1200, 900), TargetPlatform.linux),
  ]) {
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
        expect(
          find.byKey(const ValueKey('knowledge-sidebar')),
          platform == TargetPlatform.linux ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          platform == TargetPlatform.linux ? findsNothing : findsOneWidget,
        );
        expect(find.text('Finished'), findsNothing);
        expect(find.byTooltip('Quick capture'), findsNothing);
        expect(
          find.byKey(ValueKey('knowledge-section-$unsortedTodos')),
          findsNothing,
        );
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
          'Inbox',
          'Search',
        ]) {
          await openSection(tester, section);
          expect(
            find.byTooltip('Quick capture'),
            section == 'Inbox' ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  testWidgets(
    'cancelled quick capture still shows the inbox and reload updates it',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: KnowledgePage(
            repository: repository,
            initialSection: 'Inbox',
            sharedText: '',
          ),
        ),
      );
      final dialog = find.widgetWithText(AlertDialog, 'Quick capture');
      for (var i = 0; i < 100 && dialog.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await waitKnowledge(
        tester,
        () => find.text('Source note').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Show search filters'));
      await tester.pump();
      expect(find.text('Search the inbox'), findsOneWidget);
      expect(find.text('All tags'), findsNothing);

      await tester.runAsync(
        () => KnowledgeStore(repository).capture('New inbox note', 'Text'),
      );
      await tester.tap(find.byTooltip('Reload'));
      await waitKnowledge(
        tester,
        () => find.text('New inbox note').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

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
      () => find.byTooltip('Show search filters').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Show search filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All tags'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inbox').last);
    await tester.pumpAndSettle();
    await openSection(tester, 'Tags');
    await tester.tap(find.text('#Inbox'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Captured');
    await tester.tap(find.text('Save'));
    await waitKnowledge(
      tester,
      () => find.text('#Captured').evaluate().isNotEmpty,
    );
    await openSection(tester, 'Search');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'saved views retain filters even when their tag currently has no files',
    (tester) async {
      final store = KnowledgeStore(repository);
      await tester.runAsync(store.load);
      store.views = [
        const KnowledgeView('Empty inbox view', tag: 'Missing tag'),
      ];
      await tester.runAsync(store.save);
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: KnowledgePage(repository: repository, initialSection: 'Views'),
        ),
      );
      await waitKnowledge(
        tester,
        () => find.text('Empty inbox view').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Empty inbox view'));
      await waitKnowledge(
        tester,
        () => find.text('No matches.').evaluate().isNotEmpty,
      );
      expect(find.text('Source note'), findsNothing);
      await tester.tap(find.byTooltip('Show search filters'));
      await tester.pumpAndSettle();
      expect(find.text('Missing tag'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
