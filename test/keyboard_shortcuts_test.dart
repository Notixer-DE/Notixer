import 'dart:convert';
import 'dart:io';

import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/keyboard_shortcuts.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/workspace_navigation.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/keyboard_settings.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/ui/library.dart';
import 'package:noter/ui/markdown_editor.dart';

import 'widget_test.dart' show settleFileIo;

Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

Future<void> _controlAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await _control(tester, key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
}

void main() {
  test('all shortcut sections have distinct default bindings', () {
    expect(
      AppShortcut.values.map((action) => action.section).toSet(),
      ShortcutSection.values.toSet(),
    );
    expect(
      AppShortcut.values.map((action) => action.defaultBinding.keys).toSet(),
      hasLength(AppShortcut.values.length),
    );
  });
  test(
    'new PDF defaults preserve existing custom bindings on upgrade',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'noter-shortcuts-upgrade-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/shortcuts.json');
      final customSearch = AppShortcut.pdfHighlighter.defaultBinding;
      await file.writeAsString(
        jsonEncode({AppShortcut.knowledgeSearch.name: customSearch.toJson()}),
      );

      final shortcuts = KeyboardShortcuts(file);
      addTearDown(shortcuts.dispose);
      await shortcuts.load();
      expect(shortcuts[AppShortcut.knowledgeSearch]?.keys, customSearch.keys);
      expect(shortcuts[AppShortcut.pdfHighlighter], isNull);
      expect(
        shortcuts[AppShortcut.pdfEraser]?.keys,
        AppShortcut.pdfEraser.defaultBinding.keys,
      );

      await shortcuts.assign(
        AppShortcut.pdfHighlighter,
        const SingleActivator(LogicalKeyboardKey.f6),
      );
      final reopened = KeyboardShortcuts(file);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(
        reopened[AppShortcut.pdfHighlighter]?.trigger,
        LogicalKeyboardKey.f6,
      );
      expect(reopened[AppShortcut.knowledgeSearch]?.keys, customSearch.keys);
    },
  );

  testWidgets(
    'PDF tools and page navigation honor reassigned shortcuts',
    (tester) async {
      final (root, repository, note) = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'noter-pdf-shortcuts-',
        );
        final repository = LocalNotebookRepository(root);
        final note = await repository.create(
          'Keyboard PDF',
          await createPaper('blank', pages: 3),
        );
        return (root, repository, note);
      }))!;
      addTearDown(() => root.delete(recursive: true));
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentWorkspace(
            repository: repository,
            initialArea: WorkspaceArea.files,
          ),
        ),
      );
      await settleFileIo(
        tester,
        () => find.text(note.title).evaluate().isNotEmpty,
      );
      await _control(tester, LogicalKeyboardKey.comma);
      final keyboardEntry = find.widgetWithText(ListTile, 'Keyboard shortcuts');
      await settleFileIo(tester, () => keyboardEntry.evaluate().isNotEmpty);
      await tester.tap(keyboardEntry);
      final settings = find.byType(KeyboardSettingsPage);
      await settleFileIo(tester, () => settings.evaluate().isNotEmpty);

      Future<void> assign(String label, LogicalKeyboardKey key) async {
        final item = find.widgetWithText(ListTile, label);
        await tester.scrollUntilVisible(item, 250);
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AlertDialog, label), findsOneWidget);
        await tester.sendKeyEvent(key);
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await settleFileIo(
          tester,
          () => find
              .descendant(of: item, matching: find.text(key.keyLabel))
              .evaluate()
              .isNotEmpty,
        );
      }

      await assign('Next PDF page', LogicalKeyboardKey.f7);
      await assign('Highlighter', LogicalKeyboardKey.f6);
      await tester.pageBack();
      await settleFileIo(tester, () => settings.evaluate().isEmpty);
      await tester.tap(find.byKey(const ValueKey('workspace-files')));
      await settleFileIo(
        tester,
        () => find.text(note.title).evaluate().isNotEmpty,
      );
      await tester.tap(find.text(note.title));

      final editor = find.byType(EditorPane);
      await settleFileIo(
        tester,
        () =>
            editor.evaluate().isNotEmpty &&
            tester.state<EditorPaneState>(editor).widget.session.toolsReady,
      );
      final pane = tester.state<EditorPaneState>(editor);
      expect(find.byKey(const ValueKey('pdf-mode-read')), findsOneWidget);
      expect(pane.editing.tool, isNull);
      expect(find.byTooltip('Next page (F7)'), findsOneWidget);
      await _controlAlt(tester, LogicalKeyboardKey.keyE);
      expect(pane.editing.tool, PdfEditTool.eraser);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      expect(pane.editing.tool, PdfEditTool.highlight);
      await tester.pump();
      expect(find.byTooltip('Highlighter (F6)'), findsOneWidget);
      await _controlAlt(tester, LogicalKeyboardKey.keyD);
      expect(pane.editing.tool, PdfEditTool.ink);
      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await settleFileIo(tester, () => pane.viewer.currentPage == 1);
      await _control(tester, LogicalKeyboardKey.pageUp);
      await settleFileIo(tester, () => pane.viewer.currentPage == 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repository.flush);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  testWidgets(
    'workspace shortcuts open search and import and can be reassigned',
    (tester) async {
      final (root, repository, note) = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('noter-shortcuts-');
        final repository = LocalNotebookRepository(root);
        final note = await MarkdownLibrary(repository).create('Open note');
        return (root, repository, note);
      }))!;
      addTearDown(() => root.delete(recursive: true));
      const picker = MethodChannel('plugins.flutter.io/file_selector');
      final messenger = tester.binding.defaultBinaryMessenger;
      var pickerOpens = 0;
      messenger.setMockMethodCallHandler(picker, (call) async {
        expect(call.method, 'openFile');
        pickerOpens++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(picker, null));

      await tester.pumpWidget(
        MaterialApp(
          home: DocumentWorkspace(
            repository: repository,
            initialArea: WorkspaceArea.files,
          ),
        ),
      );
      await settleFileIo(
        tester,
        () => find.text(note.title).evaluate().isNotEmpty,
      );

      await _control(tester, LogicalKeyboardKey.keyK);
      final search = find.byType(KnowledgePage);
      await settleFileIo(tester, () => search.evaluate().isNotEmpty);
      expect(find.text('Search titles, text and tasks'), findsOneWidget);
      final field = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)).first,
      );
      expect(field.focusNode.hasFocus, isTrue);
      await _controlAlt(tester, LogicalKeyboardKey.keyJ);
      await settleFileIo(
        tester,
        () => find.text('Journal template').evaluate().isNotEmpty,
      );
      expect(find.text('Search titles, text and tasks'), findsNothing);
      await _control(tester, LogicalKeyboardKey.keyK);
      await settleFileIo(
        tester,
        () => find.text('Search titles, text and tasks').evaluate().isNotEmpty,
      );
      expect(find.text('Search titles, text and tasks'), findsOneWidget);
      await tester.pageBack();
      await settleFileIo(
        tester,
        () =>
            search.evaluate().isEmpty ||
            find.text('Search titles, text and tasks').evaluate().isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('workspace-files')));
      await tester.pumpAndSettle();

      await tester.tap(find.text(note.title));
      final editor = find.byType(MarkdownEditorPage);
      await settleFileIo(tester, () => editor.evaluate().isNotEmpty);
      final librarySearch = tester.widget<TextField>(
        find.descendant(
          of: find.byType(LibraryPage, skipOffstage: false),
          matching: find.byType(TextField, skipOffstage: false),
          skipOffstage: false,
        ),
      );
      expect(librarySearch.focusNode!.canRequestFocus, isFalse);
      await tester.tap(find.byKey(const ValueKey('markdown-source')));
      await tester.pump();
      await _controlAlt(tester, LogicalKeyboardKey.keyM);
      await settleFileIo(
        tester,
        () => find.text('This note is empty.').evaluate().isNotEmpty,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _control(tester, LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleFileIo(tester, () => pickerOpens == 1);
      expect(editor, findsOneWidget);

      await tester.tap(find.byTooltip('Open library and another note'));
      await settleFileIo(
        tester,
        () =>
            find.byKey(const ValueKey('workspace-more')).evaluate().isNotEmpty,
      );
      expect(librarySearch.focusNode!.canRequestFocus, isTrue);
      await tester.tap(find.byKey(const ValueKey('workspace-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardSettingsPage), findsOneWidget);
      expect(find.text('Ctrl + K'), findsOneWidget);
      expect(find.text('Ctrl + Shift + I'), findsOneWidget);
      await tester.tap(find.text('Open global search'));
      await tester.pumpAndSettle();
      await _control(tester, LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(
        find.text('Already assigned to Search file titles.'),
        findsOneWidget,
      );
      expect(pickerOpens, 1);
      await _control(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settleFileIo(
        tester,
        () => find.text('Ctrl + J').evaluate().length == 1,
      );

      final reloaded = KeyboardShortcuts(
        File('${root.path}/.keyboard-shortcuts.json'),
      );
      await tester.runAsync(reloaded.load);
      expect(
        reloaded[AppShortcut.knowledgeSearch]?.trigger,
        LogicalKeyboardKey.keyJ,
      );
      reloaded.dispose();

      await tester.pageBack();
      await settleFileIo(
        tester,
        () => find.byType(KeyboardSettingsPage).evaluate().isEmpty,
      );
      await _control(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(find.text('Search titles, text and tasks'), findsNothing);
      await _control(tester, LogicalKeyboardKey.keyJ);
      await settleFileIo(
        tester,
        () => find.text('Search titles, text and tasks').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
