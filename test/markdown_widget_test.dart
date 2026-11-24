import 'dart:io';
import 'widget_test.dart' show openWorkspaceFiles;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_task.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/quick_todos.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/markdown_preview.dart';
import 'package:noter/ui/todo_list_page.dart';
import 'package:noter/ui/wiki_link_suggestions.dart';
import 'package:noter/ui/noter_theme.dart';

import 'fixtures/long_markdown.dart';

Future<void> markdownIo(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (ready() &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Markdown file operation did not finish.');
}

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook a, b;
  const source =
      '## Study plan\n\n**Important thoughts** und normal text.\n\n'
      '- [ ] First task\n- [x] Second task\n\n'
      '```\n- [ ] Code only\n```\n';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-markdown-ui-');
    repository = LocalNotebookRepository(directory);
    final library = MarkdownLibrary(repository);
    a = await library.create('My text note');
    b = await library.create('Other note');
    a = await repository.save(a, MarkdownDocument(source).encode());
    await repository.save(
      b,
      MarkdownDocument('## Target section\n\nBack zum Study plan.').encode(),
    );
  });
  tearDown(() async {
    FileGateway.beforeClose = null;
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => repository.load(a.id));
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: MarkdownEditorPage(
          note: a,
          bytes: bytes!,
          repository: repository,
        ),
      ),
    );
    await markdownIo(
      tester,
      () => find.text('Study plan').evaluate().isNotEmpty,
    );
  }

  testWidgets(
    'formatted view keeps compact interactive tasks without inline text editing',
    (tester) async {
      const original =
          '```text\r\nShared paragraph\r\n```\r\n\r\n'
          '## Study plan ##\r\n\r\nShared paragraph\r\n\r\n'
          '- [ ] First item\r\n- [x] Second item\r\n';
      await tester.runAsync(
        () => repository.save(a, MarkdownDocument(original).encode()),
      );
      await open(tester, const Size(1024, 1000));
      final tasks = find.byType(Checkbox);
      expect(tasks, findsNWidgets(2));
      expect(
        tester.getCenter(tasks.last).dy - tester.getCenter(tasks.first).dy,
        lessThan(52),
      );
      expect(find.text('Edit in preview'), findsNothing);
      expect(find.text('Write Markdown'), findsNothing);
      final title = find.byKey(const ValueKey('markdown-title'));
      expect(tester.widget<TextField>(title).readOnly, isTrue);
      await tester.tap(tasks.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await markdownIo(
        tester,
        () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
      );
      final bytes = await tester.runAsync(() => repository.load(a.id));
      expect(
        MarkdownDocument.decode(
          bytes!,
        ).source.split('\r\n').map(visibleTaskText).join('\r\n'),
        original.replaceFirst('- [ ] First item', '- [x] First item'),
      );
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(title).readOnly, isFalse);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );

  testWidgets('formatted task hides saved timer data', (tester) async {
    final tracked = updateDocumentTask(
      source,
      markdownTaskOffsets(source).first,
      timer: TodoTimerAction.start,
      countdown: const Duration(minutes: 5),
    );
    expect(tracked, contains('<!-- notixer-task'));
    await tester.runAsync(
      () => repository.save(a, MarkdownDocument(tracked).encode()),
    );
    await open(tester, const Size(390, 844));
    expect(find.text('First task', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('notixer-task', findRichText: true),
      findsNothing,
    );
    expect(find.byType(Checkbox), findsNWidgets(2));
  });

  testWidgets(
    'formatted Markdown zoom rebuilds blocks without reparsing source',
    (tester) async {
      await open(tester, const Size(1440, 1000));
      await tester.tap(find.byTooltip('Hide folders'));
      await tester.pumpAndSettle();
      expect(find.text('New text note'), findsNothing);
      await tester.tap(find.byTooltip('Show folders'));
      await tester.pumpAndSettle();
      expect(find.text('New text note'), findsOneWidget);
      final preview = find.byType(MarkdownPreview);
      final state = tester.state<MarkdownPreviewState>(preview);
      final parses = state.debugParses;
      await tester.tap(find.byTooltip('Zoom in (Ctrl++)'));
      await tester.pumpAndSettle();
      expect(tester.widget<MarkdownPreview>(preview).zoom, closeTo(1.1, .001));
      expect(state.debugParses, parses);
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.text('Formatted'));
      await markdownIo(
        tester,
        () => find.byType(MarkdownPreview).evaluate().isNotEmpty,
      );
      expect(tester.widget<MarkdownPreview>(preview).zoom, closeTo(1.1, .001));
      await tester.tap(find.byTooltip('Reset reading zoom (Ctrl+0)'));
      await tester.pumpAndSettle();
      expect(tester.widget<MarkdownPreview>(preview).zoom, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('Tab indents selected source lines and code blocks render', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('markdown-source'));
    await tester.tap(field);
    await tester.enterText(field, 'one\ntwo\nthree');
    final controller = tester.widget<TextField>(field).controller!;
    final originalSize = tester.widget<TextField>(field).style!.fontSize!;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      tester.widget<TextField>(field).style!.fontSize!,
      greaterThan(originalSize),
    );
    expect(controller.text, 'one\ntwo\nthree');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.widget<TextField>(field).style!.fontSize, originalSize);

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, '    one\n    two\nthree');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.text, 'one\ntwo\nthree');
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, 'one    \ntwo\nthree');
    await tester.enterText(field, 'print("hello");');
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    await tester.drag(
      find.byTooltip('Zoom in (Ctrl++)'),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Code block'));
    await tester.tap(find.byTooltip('Code block'));
    await tester.pumpAndSettle();
    expect(controller.text, '\n```\nprint("hello");\n```\n');
    var saveFinished = false;
    FileGateway.beforeClose!().then((saved) => saveFinished = saved);
    await markdownIo(tester, () => saveFinished);
    final saved = await tester.runAsync(() => repository.load(a.id));
    expect(MarkdownDocument.decode(saved!).source, controller.text);
    await tester.tap(find.text('Formatted'));
    await markdownIo(
      tester,
      () => find.textContaining('print("hello");').evaluate().isNotEmpty,
    );
    expect(find.textContaining('print("hello");'), findsWidgets);
  });

  testWidgets(
    'desktop list toggles; source, formatting and checks share one saved document',
    (tester) async {
      Future<void> saveEditor() async {
        var saved = false;
        FileGateway.beforeClose!().then((result) => saved = result);
        await markdownIo(tester, () => saved);
      }

      await open(tester, const Size(1440, 1000));
      expect(find.text('My notes'), findsNothing);
      final folders = find.byTooltip('Hide folders');
      final noteList = find.byTooltip('Show note list');
      expect(
        find.descendant(
          of: folders,
          matching: find.byIcon(Icons.folder_open_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: noteList,
          matching: find.byIcon(Icons.list_alt_outlined),
        ),
        findsOneWidget,
      );
      expect(
        tester.getCenter(folders).dx,
        lessThan(tester.getCenter(noteList).dx),
      );
      expect(
        tester.getCenter(noteList).dx,
        lessThan(tester.getCenter(find.byTooltip('Save')).dx),
      );
      await tester.tap(noteList);
      await tester.pumpAndSettle();
      expect(find.text('My notes'), findsOneWidget);
      await tester.tap(folders);
      await tester.pumpAndSettle();
      expect(find.text('My notes'), findsOneWidget);
      await tester.tap(find.byTooltip('Show folders'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide note list'));
      await tester.pumpAndSettle();
      expect(find.text('My notes'), findsNothing);

      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await saveEditor();
      var saved = await tester.runAsync(() => repository.load(a.id));
      expect(
        MarkdownDocument.decode(saved!).source,
        contains('- [x] First task'),
      );
      expect(
        MarkdownDocument.decode(saved).source,
        contains('```\n- [ ] Code only\n```'),
      );
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('markdown-source'));
      await tester.enterText(
        field,
        '# New heading\n\nNormaler Text\n\n- [ ] Neu\n',
      );
      await tester.tap(find.byTooltip('Bold'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains('**Text**'),
      );
      await tester.tap(find.text('Formatted'));
      await markdownIo(
        tester,
        () => find.text('New heading').evaluate().isNotEmpty,
      );
      await markdownIo(
        tester,
        () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      await saveEditor();
      saved = await tester.runAsync(() => repository.load(a.id));
      expect(MarkdownDocument.decode(saved!).source, contains('**Text**'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    timeout: const Timeout(Duration(seconds: 35)),
  );

  testWidgets(
    'PDF page picker validates bounds and follows a one-based page link',
    (tester) async {
      final target = await tester.runAsync(
        () async => repository.create(
          'PDF pages',
          await createPaper('blank', pages: 3),
        ),
      );
      await open(tester, const Size(1440, 1000));
      await tester.tap(find.byTooltip('Insert link'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Link to page in PDF pages'));
      await markdownIo(
        tester,
        () => find.text('Page number').evaluate().isNotEmpty,
      );
      final number = find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextFormField),
      );
      await tester.enterText(number, '4');
      await tester.tap(find.text('Insert page link'));
      await tester.pump();
      expect(find.text('Enter a page from 1 to 3.'), findsOneWidget);
      await tester.enterText(number, '2');
      await tester.tap(find.text('Insert page link'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      final text = tester
          .widget<TextField>(find.byKey(const ValueKey('markdown-source')))
          .controller!
          .text;
      expect(text, contains('${target!.documentPath}#page=2'));
      await tester.tap(find.text('Formatted'));
      await markdownIo(
        tester,
        () => find.text('PDF pages · Page 2').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('PDF pages · Page 2'));
      await tester.tap(find.text('PDF pages · Page 2'));
      await markdownIo(
        tester,
        () => find.byType(EditorPane).evaluate().isNotEmpty,
      );
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (tester
                .state<EditorPaneState>(find.byType(EditorPane))
                .viewer
                .currentPage ==
            1) {
          break;
        }
      }
      expect(
        tester
            .state<EditorPaneState>(find.byType(EditorPane))
            .viewer
            .currentPage,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Markdown note actions save tags without losing the source', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folders and tags'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Tags'),
      'Study, study, Exam',
    );
    await tester.tap(find.text('Save'));
    await markdownIo(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    final notes = await tester.runAsync(() => repository.list());
    expect(notes!.firstWhere((note) => note.id == a.id).tags, [
      'Study',
      'Exam',
    ]);
    final persisted = await tester.runAsync(
      () async => MarkdownDocument.decode(await repository.load(a.id)),
    );
    expect(persisted!.source, source);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final otherFile in [false, true]) {
    testWidgets(
      'heading picker inserts and follows a ${otherFile ? "cross-file" : "local"} anchor',
      (tester) async {
        await open(tester, const Size(1440, 1000));
        await tester.tap(find.byTooltip('Insert link'));
        await tester.pumpAndSettle();
        await tester.tap(
          otherFile
              ? find.byTooltip('Link to heading in Other note')
              : find.text('Heading in this note'),
        );
        await markdownIo(
          tester,
          () => find
              .text(otherFile ? 'Target section' : 'Study plan')
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog).last,
            matching: find.text(otherFile ? 'Target section' : 'Study plan'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        final field = find.byKey(const ValueKey('markdown-source'));
        final text = tester.widget<TextField>(field).controller!.text;
        expect(text, contains(otherFile ? '#target-section' : '#study-plan'));
        if (otherFile) expect(text, contains(b.documentPath));
        await tester.tap(find.text('Formatted'));
        await markdownIo(
          tester,
          () => find.byType(MarkdownPreview).evaluate().isNotEmpty,
        );
        final preview = find.byType(MarkdownPreview);
        final link = find
            .descendant(
              of: preview,
              matching: find.text(otherFile ? 'Target section' : 'Study plan'),
            )
            .last;
        await tester.ensureVisible(link);
        await tester.tap(link);
        await markdownIo(
          tester,
          () =>
              otherFile ? find.text('Linked from').evaluate().isNotEmpty : true,
        );
        expect(find.textContaining('Heading not found:'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'link chooser inserts a real relative link and opens the target with backlinks',
    (tester) async {
      await open(tester, const Size(1440, 1000));
      await tester.tap(find.byTooltip('Insert link'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Other note'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('markdown-source'));
      expect(field, findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains(b.documentPath),
      );
      await tester.tap(find.text('Formatted'));
      await markdownIo(
        tester,
        () => find.text('Other note').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('Other note'));
      await tester.tap(find.text('Other note'));
      await markdownIo(
        tester,
        () => find.text('Target section').evaluate().isNotEmpty,
      );
      expect(find.text('My text note'), findsOneWidget); // Backlink button.
      expect(find.text('Linked from'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'bare Markdown links open formatted even for an empty or already open note',
    (tester) async {
      await tester.runAsync(() async {
        await repository.save(
          a,
          MarkdownDocument(
            '## Study plan\n\n[Open target](${MarkdownLibrary.linkTo(a, b)})',
          ).encode(),
        );
        await repository.save(b, MarkdownDocument('').encode());
      });
      await tester.pumpWidget(NoterApp(repository: repository));
      await openWorkspaceFiles(tester);
      await markdownIo(tester, () => find.text(a.title).evaluate().isNotEmpty);
      await tester.tap(find.text(a.title));
      final link = find.text('Open target');
      await markdownIo(tester, () => link.evaluate().isNotEmpty);
      await tester.tap(link);
      final source = find.byKey(const ValueKey('markdown-source'));
      await markdownIo(
        tester,
        () =>
            link.evaluate().isEmpty &&
            find.text('This note is empty.').evaluate().isNotEmpty,
      );
      expect(source, findsNothing);

      await tester.tap(find.text('Edit'));
      await tester.pump();
      await tester.enterText(source, '# Edited target');
      await tester.tap(find.byKey(ValueKey('document-tab-${a.id}')));
      await markdownIo(tester, () => link.evaluate().isNotEmpty);
      await tester.tap(link);
      await markdownIo(
        tester,
        () => find.text('Edited target').evaluate().isNotEmpty,
      );
      expect(source, findsNothing);
      await tester.tap(find.byTooltip('Save'));
      await markdownIo(
        tester,
        () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'wiki completion inserts stable file and heading links with keyboard support',
    (tester) async {
      await open(tester, const Size(1440, 1000));
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('markdown-source'));
      await tester.enterText(field, '[[Other');
      await tester.pump(const Duration(milliseconds: 200));
      final suggestion = find.descendant(
        of: find.byType(WikiLinkSuggestions),
        matching: find.text('Other note'),
      );
      await markdownIo(tester, () => suggestion.evaluate().isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains(b.documentPath),
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        isNot(contains('[[')),
      );
      await tester.enterText(field, '[[Other note#Target');
      await tester.pump(const Duration(milliseconds: 200));
      final heading = find.descendant(
        of: find.byType(WikiLinkSuggestions),
        matching: find.text('Target section'),
      );
      await markdownIo(tester, () => heading.evaluate().isNotEmpty);
      await tester.tap(heading);
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains('#target-section'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('wiki suggestions stay inactive inside fenced code examples', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('markdown-source'));
    await tester.enterText(field, '```text\n[[Other');
    await tester.pump(const Duration(milliseconds: 250));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.descendant(
        of: find.byType(WikiLinkSuggestions),
        matching: find.text('Other note'),
      ),
      findsNothing,
    );
    expect(
      tester.widget<TextField>(field).controller!.text,
      '```text\n[[Other',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('source undo survives switching to the formatted view', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('markdown-source'));
    final controller = tester.widget<TextField>(field).controller!;
    await tester.enterText(field, 'Erster Paragraph');
    await tester.pump(const Duration(milliseconds: 700));
    await markdownIo(
      tester,
      () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
    );
    await tester.enterText(field, 'Secondr Paragraph');
    await tester.pump(const Duration(milliseconds: 700));
    await markdownIo(
      tester,
      () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Formatted'));
    await markdownIo(
      tester,
      () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Erster Paragraph');
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Secondr Paragraph');
    await tester.tap(find.byTooltip('Save'));
    await markdownIo(
      tester,
      () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('selected source text becomes the link label', (tester) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('markdown-source'));
    await tester.enterText(field, 'Diese Stelle bleibt erhalten');
    tester.widget<TextField>(field).controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 12,
    );
    await tester.tap(find.byTooltip('Insert link'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Other note'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      '[Diese Stelle](<${b.documentPath}>) bleibt erhalten',
    );
    await tester.tap(find.byTooltip('Save'));
    await markdownIo(
      tester,
      () => find.byTooltip('Saved locally').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('new to-do list has its own editor and preserves task changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NoterApp(repository: repository));
    await openWorkspaceFiles(tester);
    await markdownIo(
      tester,
      () => find.text('My text note').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Errands');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('To-do list').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await markdownIo(
      tester,
      () => find.text('No tasks yet.').evaluate().isNotEmpty,
    );
    expect(find.byType(TodoListPage), findsOneWidget);
    expect(find.byType(MarkdownEditorPage), findsNothing);
    final input = find.widgetWithText(TextField, 'New task');
    await tester.enterText(input, 'Buy [tea]');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Buy [tea]'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.enterText(input, 'Collect a parcel');
    await tester.pump();
    await tester.tap(find.byTooltip('Add task'));
    await tester.pump();
    final second = find.widgetWithText(ListTile, 'Collect a parcel');
    final first = find.widgetWithText(ListTile, 'Buy [tea]');
    expect(tester.getSize(first).height, lessThanOrEqualTo(46));
    expect(
      tester.getTopLeft(second).dy - tester.getTopLeft(first).dy,
      lessThanOrEqualTo(46),
    );
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(tester.getSize(first).height, greaterThan(60));
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump();
    await tester.tap(
      find.descendant(of: second, matching: find.byTooltip('Edit task')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Task'),
      'Collect both parcels',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final checkbox = find.descendant(
      of: find.widgetWithText(ListTile, 'Buy [tea]'),
      matching: find.byType(Checkbox),
    );
    await tester.tap(checkbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);

    await tester.tap(find.byTooltip('Close tab: Errands'));
    await markdownIo(
      tester,
      () => find.byType(TodoListPage).evaluate().isEmpty,
    );
    await tester.tap(find.text('Errands'));
    await markdownIo(
      tester,
      () => find.text('Collect both parcels').evaluate().isNotEmpty,
    );
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'phone editor, note sheet and toolbar fit at text scale $scale',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(tester, const Size(390, 844));
        expect(find.text('My notes'), findsNothing);
        await tester.tap(find.byTooltip('Show note list'));
        await tester.pumpAndSettle();
        expect(find.text('My notes'), findsOneWidget);
        await tester.tap(find.text('Other note'));
        await markdownIo(
          tester,
          () => find.text('Target section').evaluate().isNotEmpty,
        );
        expect(find.text('My notes'), findsNothing);
        await tester.ensureVisible(find.text('Markdown'));
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        final source = find.byKey(const ValueKey('markdown-source'));
        await tester.enterText(source, 'Text auf dem Handy\n\n- [ ] Eine Task');
        bool? closed;
        FileGateway.beforeClose!().then((ok) => closed = ok);
        await markdownIo(tester, () => closed != null);
        expect(closed, isTrue);
        final saved = await tester.runAsync(() => repository.load(b.id));
        expect(
          MarkdownDocument.decode(saved!).source,
          startsWith('Text auf dem Handy'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('long editor bounds the hidden and visible source scroll area', (
    tester,
  ) async {
    await tester.runAsync(
      () => repository.save(a, MarkdownDocument(longMarkdown()).encode()),
    );
    // The common opening helper waits for the short fixture's "Study plan".
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => repository.load(a.id));
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: MarkdownEditorPage(
          note: a,
          bytes: bytes!,
          repository: repository,
        ),
      ),
    );
    await markdownIo(
      tester,
      () => find.byType(MarkdownPreview).evaluate().isNotEmpty,
    );
    final source = find.byKey(
      const ValueKey('markdown-source'),
      skipOffstage: false,
    );
    expect(tester.getSize(source).height, lessThanOrEqualTo(900));
    final preview = tester.widget<MarkdownPreview>(
      find.byType(MarkdownPreview),
    );
    for (var i = 0; i < 20; i++) {
      preview.scrollController.jumpTo(preview.scrollController.offset + 400);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(Checkbox).evaluate().length, lessThan(40));
    }
    preview.scrollController.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(source).expands, isTrue);
    expect(tester.getSize(source).height, lessThanOrEqualTo(900));
    await tester.drag(source, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('library opens Markdown rather than a PDF editor', (
    tester,
  ) async {
    await tester.pumpWidget(NoterApp(repository: repository));
    await openWorkspaceFiles(tester);
    await markdownIo(
      tester,
      () => find.text('My text note').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('My text note'));
    await markdownIo(
      tester,
      () => find.byType(MarkdownEditorPage).evaluate().isNotEmpty,
    );
    expect(find.text('Study plan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
