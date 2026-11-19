import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/keyboard_shortcuts.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/keyboard_settings.dart';
import 'package:noter/ui/knowledge_page.dart';
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
        MaterialApp(home: DocumentWorkspace(repository: repository)),
      );
      await settleFileIo(
        tester,
        () => find.text(note.title).evaluate().isNotEmpty,
      );

      await _control(tester, LogicalKeyboardKey.keyK);
      final search = find.byType(KnowledgePage);
      await settleFileIo(tester, () => search.evaluate().isNotEmpty);
      expect(find.text('Search Markdown and PDFs'), findsOneWidget);
      final field = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)).first,
      );
      expect(field.focusNode.hasFocus, isTrue);
      await _controlAlt(tester, LogicalKeyboardKey.keyJ);
      await tester.pumpAndSettle();
      expect(find.text('Search Markdown and PDFs'), findsNothing);
      await _control(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(find.text('Search Markdown and PDFs'), findsOneWidget);
      await tester.pageBack();
      await settleFileIo(tester, () => search.evaluate().isEmpty);

      await tester.tap(find.text(note.title));
      final editor = find.byType(MarkdownEditorPage);
      await settleFileIo(tester, () => editor.evaluate().isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('markdown-source')));
      await tester.pump();
      await _controlAlt(tester, LogicalKeyboardKey.keyM);
      await settleFileIo(
        tester,
        () => find.text('Edit in preview').evaluate().isNotEmpty,
      );
      await _control(tester, LogicalKeyboardKey.keyF);
      await settleFileIo(tester, () => pickerOpens == 1);
      expect(editor, findsOneWidget);

      await tester.tap(find.byTooltip('Open library and another note'));
      await settleFileIo(
        tester,
        () => find.byTooltip('Library actions').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Library actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(KeyboardSettingsPage), findsOneWidget);
      expect(find.text('Ctrl + K'), findsOneWidget);
      expect(find.text('Ctrl + F'), findsOneWidget);
      await tester.tap(find.text('Search in Knowledge Hub'));
      await tester.pumpAndSettle();
      await _control(tester, LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(
        find.text('Already assigned to Open file picker.'),
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
        reloaded[AppShortcut.knowledgeSearch].trigger,
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
      expect(search, findsNothing);
      await _control(tester, LogicalKeyboardKey.keyJ);
      await settleFileIo(tester, () => search.evaluate().isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
