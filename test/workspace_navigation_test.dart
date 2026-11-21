import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/journal_calendar.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';

import 'widget_test.dart' show settleFileIo;

Finder _destination(String name) => find.byKey(ValueKey('workspace-$name'));

void main() {
  late Directory root;
  late LocalNotebookRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('notixer-workspace-');
    repository = LocalNotebookRepository(root);
  });
  tearDown(() async {
    await repository.flush();
    await root.delete(recursive: true);
  });

  Future<void> launch(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: DocumentWorkspace(repository: repository),
      ),
    );
    await settleFileIo(
      tester,
      () => find.text('Due tasks').evaluate().isNotEmpty,
    );
  }

  testWidgets('Today opens a timer directly and keeps it running in Tasks', (
    tester,
  ) async {
    final store = KnowledgeStore(repository);
    final now = DateUtils.dateOnly(DateTime.now());
    final due = await tester.runAsync(
      () => store.addQuickTodo('Read chapter four', due: now),
    );
    await launch(tester, const Size(390, 844));
    expect(find.text('Read chapter four'), findsOneWidget);
    await tester.tap(find.byTooltip('Start timer'));
    await settleFileIo(
      tester,
      () => find.text('Time tracked · Running').evaluate().isNotEmpty,
    );
    final started = (await tester.runAsync(store.quickTodos.read))![due!.id]!;
    expect(started.timerStartedAt, isNotNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All tasks due today'));
    final today = find.widgetWithText(ChoiceChip, 'Today');
    await settleFileIo(
      tester,
      () =>
          today.evaluate().isNotEmpty &&
          find.text('Read chapter four').evaluate().isNotEmpty,
    );
    expect(tester.widget<ChoiceChip>(today).selected, isTrue);
    expect(find.byTooltip('Open focus timer'), findsOneWidget);
    final reopened = (await tester.runAsync(store.quickTodos.read))![due.id]!;
    expect(reopened.timerStartedAt, started.timerStartedAt);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search keeps its query and journal keeps its selected date', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await repository.create(
        'Workspace source',
        MarkdownDocument('# Source\n\nAn indexed handoff passage.').encode(),
        paper: 'markdown',
      );
    });
    await launch(tester, const Size(1024, 768));
    await tester.tap(find.byTooltip('Search (Ctrl + K)'));
    final search = find.widgetWithText(
      TextField,
      'Search titles, text and tasks',
    );
    await settleFileIo(tester, () => search.evaluate().isNotEmpty);
    await tester.enterText(search, 'handoff');
    await tester.tap(find.byTooltip('Search'));
    final hit = find.text('An indexed handoff passage.');
    await settleFileIo(tester, () => hit.evaluate().isNotEmpty);
    await tester.tap(hit);
    await settleFileIo(
      tester,
      () => find.byType(MarkdownEditorPage).evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('markdown-source')), findsNothing);
    expect(find.text('An indexed handoff passage.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to library'));
    await settleFileIo(
      tester,
      () => search.evaluate().isNotEmpty && hit.evaluate().isNotEmpty,
    );
    expect(tester.widget<TextField>(search).controller!.text, 'handoff');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(search, findsNothing);

    await tester.tap(_destination('journal'));
    final calendar = find.byType(JournalCalendar);
    await settleFileIo(tester, () => calendar.evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pump();
    final month = tester.widget<JournalCalendar>(calendar).month;
    final selected = DateTime(month.year, month.month, 12);
    tester.widget<JournalCalendar>(calendar).onDay!(selected);
    await tester.pump();
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    expect(tester.widget<JournalCalendar>(calendar).selected, selected);
    expect(tester.widget<JournalCalendar>(calendar).month, month);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('workspace navigation adapts to every issue viewport', (
    tester,
  ) async {
    await launch(tester, const Size(320, 568));
    for (final (size, rail) in [
      (const Size(320, 568), false),
      (const Size(390, 844), false),
      (const Size(600, 960), false),
      (const Size(768, 1024), false),
      (const Size(1024, 768), true),
      (const Size(1280, 720), true),
      (const Size(1440, 900), true),
      (const Size(844, 390), false),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();
      expect(find.byType(NavigationRail), rail ? findsOneWidget : findsNothing);
      for (final name in ['today', 'files', 'tasks', 'journal', 'more']) {
        expect(_destination(name), findsOneWidget);
      }
      expect(find.byTooltip('Create'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(320, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(_destination('journal'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
