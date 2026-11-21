import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/learning.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/page_manager.dart';
import 'package:noter/ui/template_library.dart';
import 'templates_test.dart' show templateFixture;
import 'widget_test.dart' show openWorkspaceFiles, settleFileIo;

void main() {
  late Directory root;
  late LocalNotebookRepository repository;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-template-ui-');
    repository = LocalNotebookRepository(root);
  });
  tearDown(() => root.delete(recursive: true));

  testWidgets(
    'editor saves the current page and the entire notebook without changing the source',
    (tester) async {
      final bytes = await tester.runAsync(templateFixture);
      final note = await tester.runAsync(
        () => repository.create('Quelle', bytes!),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(note: note!, bytes: bytes!, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      final original = List<int>.of(pane.editing.bytes);
      pane.revealAll();
      await tester.pumpAndSettle();
      expect(
        pane.editing.bytes,
        original,
        reason: 'Revealed answers are view state, never template contents',
      );
      final sourceSession = pane.widget.session;
      await tester.runAsync(
        () => sourceSession.rateTape(
          sourceSession.tapes.single.id,
          ReviewRating.known,
        ),
      );
      await tester.pumpAndSettle();
      expect(sourceSession.note.learning.isEmpty, isFalse);
      for (final item in [
        ('Save current page as template', 'Eine Page'),
        ('Save note as template', 'All Pages'),
      ]) {
        await tester.tap(find.byTooltip('Tools and export'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item.$1));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, item.$2);
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await settleFileIo(
          tester,
          () => find.text('Template saved.').evaluate().isNotEmpty,
        );
      }
      final entries = await tester.runAsync(() => repository.templates.list());
      expect(
        entries!.where((t) => !t.builtIn).map((t) => (t.name, t.pageCount)),
        [('All Pages', 3), ('Eine Page', 1)],
      );
      expect(pane.editing.bytes, original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final page = entries.singleWhere((entry) => entry.name == 'Eine Page');
      final copiedBytes = await tester.runAsync(
        () => repository.templates.instantiate(page.id),
      );
      final copy = await tester.runAsync(
        () => repository.create('Kopie', copiedBytes!),
      );
      expect(copy!.learning.isEmpty, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(
            note: copy,
            bytes: copiedBytes!,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.state<EditorPaneState>(find.byType(EditorPane)).toggleLearning();
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'Reveal answer',
        ),
        findsOneWidget,
        reason:
            'The source revealed its answer; the new copy must start covered',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'Hide answer',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('new note dialog selects and creates a complete template copy', (
    tester,
  ) async {
    final entry = await tester.runAsync(
      () async => repository.templates.save('Seminar', await templateFixture()),
    );
    await tester.pumpWidget(NoterApp(repository: repository));
    await openWorkspaceFiles(tester);
    await settleFileIo(
      tester,
      () => find
          .text('0 notes · Most recently modified first')
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Meine Kopie');
    await tester.tap(find.text('Choose template'));
    await settleFileIo(
      tester,
      () => find.byKey(ValueKey(entry!.id)).evaluate().isNotEmpty,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey(entry!.id)),
        matching: find.text('Use'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Seminar · 3 Pages'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await settleFileIo(
      tester,
      () => find.byType(EditorPane).evaluate().isNotEmpty,
    );
    final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
    expect(pane.editing.document.pageCount, 3);
    final created = (await tester.runAsync(() => repository.list()))!.single;
    expect(created.title, 'Meine Kopie');
    expect(created.id, isNot(entry.id));
    expect(created.tags, isEmpty);
    expect(created.folderId, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'page manager inserts all template pages in one undoable operation',
    (tester) async {
      final entry = await tester.runAsync(
        () async =>
            repository.templates.save('Drei Pages', await templateFixture()),
      );
      final bytes = await tester.runAsync(
        () => repository.templates.instantiate('starter_cornell'),
      );
      final note = await tester.runAsync(
        () => repository.create('Ziel', bytes!),
      );
      final session = DocumentSession(
        note!,
        bytes!,
        repository,
        preferencesStore: PdfMemoryPreferencesStore(),
        autosaveDelay: const Duration(days: 1),
        checkpointInterval: const Duration(days: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PageManager(
                    session: session,
                    currentPage: 0,
                    onPage: (_) {},
                    onCopyTo: (_, _) async {},
                  ),
                ),
                child: const Text('Pages'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Insert from template'));
      await settleFileIo(
        tester,
        () => find.byKey(ValueKey(entry!.id)).evaluate().isNotEmpty,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(entry!.id)),
          matching: find.text('Use'),
        ),
      );
      await settleFileIo(
        tester,
        () => find.text('Page 4').evaluate().isNotEmpty,
      );
      expect(session.editing.document.pageCount, 4);
      session.editing.undo();
      await tester.pump();
      expect(session.editing.document.pageCount, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'template library previews, renames and deletes on a phone with large text',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final entry = await tester.runAsync(
        () async => repository.templates.save(
          'Custom template',
          await templateFixture(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: TemplateLibrary(repository: repository.templates)),
      );
      await settleFileIo(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(entry!.id)),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Preview').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview').first);
      await settleFileIo(
        tester,
        () => find.text('Page 1 of 3').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Next template page'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Close preview'));
      await settleFileIo(
        tester,
        () => find.byType(TemplatePreview).evaluate().isEmpty,
      );
      await tester.ensureVisible(find.byTooltip('Template actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Template actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' ');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'Umbenannt');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settleFileIo(
        tester,
        () => find
            .descendant(
              of: find.byKey(ValueKey(entry.id)),
              matching: find.text('Umbenannt'),
            )
            .evaluate()
            .isNotEmpty,
      );
      await tester.ensureVisible(find.byTooltip('Template actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Template actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Umbenannt'), findsOneWidget);
      await tester.tap(find.byTooltip('Template actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settleFileIo(
        tester,
        () => find.text('Umbenannt').evaluate().isEmpty,
      );
      expect(
        (await tester.runAsync(
          () => repository.templates.list(),
        ))!.where((t) => !t.builtIn),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
