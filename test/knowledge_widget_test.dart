import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/quick_todos.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/ui/journal_calendar.dart';
import 'package:noter/ui/library.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/todo_timer.dart';

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

  testWidgets('desktop focus countdown makes the remaining time prominent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final date = DateTime(2026);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: TodoTimer(
            todo: QuickTodo(
              id: 'focus',
              text: 'Read chapter',
              created: date,
              modified: date,
            ),
            directStart: true,
            onChanged: ({timer, workTime, countdown}) => null,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open focus timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Countdown'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CircularProgressIndicator)).width, 306);
    expect(
      tester.widget<Text>(find.text('25:00')).style!.fontSize,
      greaterThan(60),
    );
    expect(find.text('Time tracked'), findsOneWidget);
    expect(find.text('Start').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'swipe deletes a quick to-do and long press deletes a checklist row',
    (tester) async {
      await tester.runAsync(
        () => KnowledgeStore(repository).addQuickTodo('Swipe this'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: KnowledgePage(repository: repository, initialSection: 'Tasks'),
        ),
      );
      final quick = find.text('Swipe this');
      await waitKnowledge(tester, () => quick.evaluate().isNotEmpty);
      await tester.ensureVisible(quick);
      await tester.drag(quick, const Offset(500, 0));
      await waitKnowledge(tester, () => quick.evaluate().isEmpty);
      expect(
        await tester.runAsync(
          () => KnowledgeStore(repository).quickTodos.read(),
        ),
        isEmpty,
      );

      final checklist = find.text('Read the chapter');
      await tester.ensureVisible(checklist);
      await tester.longPress(checklist);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete to-do'));
      await waitKnowledge(tester, () => checklist.evaluate().isEmpty);
      final source = await tester.runAsync(
        () async =>
            MarkdownDocument.decode(await repository.load(note.id)).source,
      );
      expect(source, '# Outline\n\n- [x] Finished');
    },
  );

  testWidgets(
    'stopwatch pauses, resumes and stops while task sync is pending',
    (tester) async {
      final store = KnowledgeStore(repository);
      final pendingSync = Completer<void>();
      final todo = await tester.runAsync(
        () => store.addQuickTodo('Focused task'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: KnowledgePage(
            repository: repository,
            initialSection: 'Tasks',
            onQuickTodosChanged: () => pendingSync.future,
          ),
        ),
      );
      final task = find.ancestor(
        of: find.text('Focused task'),
        matching: find.byType(ListTile),
      );
      await waitKnowledge(tester, () => task.evaluate().isNotEmpty);
      await tester.tap(
        find.descendant(of: task, matching: find.byTooltip('Task timer')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open focus timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await waitKnowledge(
        tester,
        () => find.text('Time tracked · Running').evaluate().isNotEmpty,
      );
      expect(find.text('Focus timer'), findsOneWidget);
      await tester.tap(find.text('Pause'));
      await waitKnowledge(
        tester,
        () => find.text('Resume').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Resume'));
      await waitKnowledge(
        tester,
        () => find.text('Time tracked · Running').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Stop'));
      await waitKnowledge(
        tester,
        () => find.text('Start').evaluate().isNotEmpty,
      );
      expect(find.text('Stop'), findsNothing);
      expect(pendingSync.isCompleted, isFalse);

      Future<void> timeMenu(String label) async {
        await tester.tap(find.byTooltip('Time options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      await timeMenu('Set tracked time');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Minutes'),
        '12',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Seconds'),
        '0',
      );
      await tester.tap(find.text('Save'));
      await waitKnowledge(
        tester,
        () => find.text('12:00').evaluate().isNotEmpty,
      );
      await timeMenu('Reset timer');
      await waitKnowledge(
        tester,
        () => find.text('00:00').evaluate().isNotEmpty,
      );
      final updated = await tester.runAsync(() => store.quickTodos.read());
      expect(updated![todo!.id]!.workMilliseconds, 0);
      expect(updated[todo.id]!.timerStartedAt, isNull);
      pendingSync.complete();
      await tester.tap(find.byType(CloseButton));
      await tester.pump(const Duration(milliseconds: 400));
      await waitKnowledge(tester, () => task.evaluate().isNotEmpty);
    },
  );

  testWidgets('countdown expiration keeps tracking task time after reopening', (
    tester,
  ) async {
    final store = KnowledgeStore(repository);
    final task = (await tester.runAsync(
      () => store.addQuickTodo('Countdown task'),
    ))!;
    await tester.runAsync(
      () => store.changeQuickTodoTimer(
        task.id,
        workTime: const Duration(minutes: 12),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: KnowledgePage(repository: repository, initialSection: 'Tasks'),
      ),
    );
    final row = find.widgetWithText(ListTile, 'Countdown task');
    final menu = find.descendant(
      of: row,
      matching: find.byTooltip('Task timer'),
    );

    Future<void> openTimer() async {
      await waitKnowledge(tester, () => menu.evaluate().isNotEmpty);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open focus timer'));
      await tester.pumpAndSettle();
    }

    await openTimer();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Countdown'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Stopwatch'))
          .selected,
      isFalse,
    );
    expect(find.text('12:00'), findsOneWidget);
    await tester.tap(find.text('Set countdown'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Minutes'), '0');
    await tester.enterText(find.widgetWithText(TextFormField, 'Seconds'), '1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('00:01 remaining'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await waitKnowledge(
      tester,
      () => find.text('Time tracked · Running').evaluate().isNotEmpty,
    );
    await tester.tap(find.byType(CloseButton));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1150)),
    );
    await openTimer();
    expect(find.text('Time is up'), findsOneWidget);
    expect(find.text('Work time is still being tracked.'), findsOneWidget);
    final running = (await tester.runAsync(store.quickTodos.read))![task.id]!;
    expect(running.timerStartedAt, isNotNull);
    expect(
      running.workTimeAt(DateTime.now()),
      greaterThan(const Duration(minutes: 12, seconds: 1)),
    );

    await tester.tap(find.text('Pause'));
    await waitKnowledge(
      tester,
      () => find.text('Resume').evaluate().isNotEmpty,
    );
    expect(find.text('Time is up'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await waitKnowledge(tester, () => find.text('Start').evaluate().isNotEmpty);
    final stopped = (await tester.runAsync(store.quickTodos.read))![task.id]!;
    expect(stopped.timerStartedAt, isNull);
    expect(stopped.timerPaused, isFalse);
    expect(stopped.workMilliseconds, greaterThan(721000));
    await tester.pumpWidget(const SizedBox.shrink());
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
        tasks.singleWhere((task) => task.quickTodo?.id == overdue.id),
        projectId: null,
        due: DateUtils.addDaysToDate(now, -1),
      );
      await store.planQuickTodo(
        tasks.singleWhere((task) => task.quickTodo?.id == future.id),
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
    final notes = await tester.runAsync(repository.list);
    expect(notes!.map((note) => note.id), [note.id]);
    final savedTodo = await tester.runAsync(
      () async =>
          (await KnowledgeStore(repository).quickTodos.read()).values.single,
    );
    expect(savedTodo!.text, 'Send the meeting notes');
    expect(savedTodo.done, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('library captures Markdown straight into the Inbox', (
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
    await tester.tap(find.byTooltip('Capture to Inbox'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Quick capture'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Title (optional)'),
      'Library capture',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Text or Markdown'),
      '**Draft**',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Capture'));
    await waitKnowledge(
      tester,
      () => find.text('Saved to Inbox').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Open Inbox'));
    await waitKnowledge(
      tester,
      () => find
          .descendant(
            of: find.byType(KnowledgePage),
            matching: find.text('Library capture'),
          )
          .evaluate()
          .isNotEmpty,
    );
    final notes = await tester.runAsync(repository.list);
    expect(
      notes!.singleWhere((n) => n.title == 'Library capture').tags,
      contains('Inbox'),
    );
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

  testWidgets('all tasks can filter completed tasks and save that status', (
    tester,
  ) async {
    final store = KnowledgeStore(repository);
    await tester.runAsync(() async {
      final todo = await store.addQuickTodo('Completed quick item');
      await store.changeTaskStatus(todo, true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: KnowledgePage(repository: repository, initialSection: 'Tasks'),
      ),
    );
    final openTask = find.text('Read the chapter');
    final closedTask = find.text('Finished');
    final closedQuickTask = find.text('Completed quick item');
    await waitKnowledge(tester, () => openTask.evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Show search filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open tasks only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Completed tasks only').last);
    await waitKnowledge(tester, () => closedTask.evaluate().isNotEmpty);
    expect(openTask, findsNothing);
    expect(closedQuickTask, findsOneWidget);

    await tester.tap(find.text('Save view'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Finished work',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitKnowledge(tester, () => closedTask.evaluate().isNotEmpty);
    await tester.runAsync(store.reload);
    expect(store.views.single.name, 'Finished work');
    expect(store.views.single.completedTasks, isTrue);
    expect(store.views.single.openTasks, isFalse);
    await openSection(tester, 'Views');
    await tester.tap(find.text('Finished work'));
    await waitKnowledge(tester, () => closedTask.evaluate().isNotEmpty);
    expect(openTask, findsNothing);
    expect(closedQuickTask, findsOneWidget);
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
    'journal opens past days and applies an edited template only to new entries',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = DateUtils.dateOnly(DateTime.now());
      final past = DateTime(today.year, today.month - 1, 10);
      final previous = (await tester.runAsync(() async {
        final journal = await KnowledgeStore(repository).journal(past);
        await repository.save(
          journal,
          MarkdownDocument('# Earlier entry\n').encode(),
        );
        return journal;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: KnowledgePage(
            repository: repository,
            initialSection: 'Journal',
          ),
        ),
      );
      await waitKnowledge(
        tester,
        () => find.byTooltip('Previous month').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      final pastDay = find.byKey(ValueKey('journal-day-${journalDate(past)}'));
      await tester.tap(pastDay);
      await waitKnowledge(
        tester,
        () => find.text('Earlier entry').evaluate().isNotEmpty,
      );
      expect(find.text('Formatted'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to journal'));
      await waitKnowledge(tester, () => pastDay.evaluate().isNotEmpty);
      expect(
        tester
            .widget<JournalCalendar>(find.byType(JournalCalendar))
            .month
            .month,
        past.month,
      );

      await tester.tap(find.text('Journal template'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Template Markdown'),
        '# Daily {{date}}\n',
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Daily ${journalDate(past)}'), findsOneWidget);
      await tester.tap(find.text('Save template'));
      await waitKnowledge(
        tester,
        () => find.byType(JournalCalendar).evaluate().isNotEmpty,
      );

      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(find.text('No journal entry for this day.'), findsOneWidget);
      expect(
        await tester.runAsync(
          () async => (await repository.list())
              .where((note) => journalEntryDate(note) == journalDate(today))
              .isEmpty,
        ),
        isTrue,
      );
      final create = find.text('Create journal page');
      await tester.scrollUntilVisible(
        create,
        180,
        scrollable: find
            .ancestor(
              of: find.byType(JournalCalendar),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump();
      await tester.tap(create.hitTestable());
      final source = find.byKey(const ValueKey('markdown-source'));
      await waitKnowledge(tester, () => source.evaluate().isNotEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.widget<TextField>(source).controller!.text,
        '# Daily ${journalDate(today)}\n',
      );
      await tester.tap(find.byTooltip('Back to journal'));
      await tester.pump(const Duration(milliseconds: 400));
      await waitKnowledge(
        tester,
        () =>
            find.byType(JournalCalendar).evaluate().isNotEmpty &&
            tester
                .widget<JournalCalendar>(find.byType(JournalCalendar))
                .entryDays
                .contains(journalDate(today)),
      );
      expect(create, findsNothing);
      await tester.ensureVisible(find.text('Add entry'));
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Journal entry'),
        'Write it down',
      );
      await tester.pump();
      await tester.tap(find.text('Save entry'));
      await waitKnowledge(
        tester,
        () => find.text(journalDate(today)).evaluate().isNotEmpty,
      );
      final saved = (await tester.runAsync(
        () async => MarkdownDocument.decode(
          await repository.load('journal-${journalDate(today)}'),
        ),
      ))!;
      expect(saved.source, contains('# Daily ${journalDate(today)}'));
      expect(saved.source, contains('Write it down'));
      final old = await tester.runAsync(
        () async => MarkdownDocument.decode(await repository.load(previous.id)),
      );
      expect(old!.source, '# Earlier entry\n');
      expect(tester.takeException(), isNull);
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
