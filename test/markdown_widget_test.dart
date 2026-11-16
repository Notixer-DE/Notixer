import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/markdown_preview.dart';
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
      '## Lernplan\n\n**Wichtige Gedanken** und normaler Text.\n\n'
      '- [ ] Erste Aufgabe\n- [x] Zweite Aufgabe\n\n'
      '```\n- [ ] Nur Code\n```\n';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-markdown-ui-');
    repository = LocalNotebookRepository(directory);
    final library = MarkdownLibrary(repository);
    a = await library.create('Meine Textnotiz');
    b = await library.create('Andere Notiz');
    a = await repository.save(a, MarkdownDocument(source).encode());
    await repository.save(
      b,
      MarkdownDocument('## Zielabschnitt\n\nZurück zum Lernplan.').encode(),
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
    await markdownIo(tester, () => find.text('Lernplan').evaluate().isNotEmpty);
  }

  testWidgets(
    'desktop list toggles; source, formatting and checks share one saved document',
    (tester) async {
      await open(tester, const Size(1440, 1000));
      expect(find.text('Meine Notizen'), findsNothing);
      await tester.tap(find.byTooltip('Notizliste einblenden'));
      await tester.pumpAndSettle();
      expect(find.text('Meine Notizen'), findsOneWidget);
      await tester.tap(find.byTooltip('Notizliste ausblenden'));
      await tester.pumpAndSettle();
      expect(find.text('Meine Notizen'), findsNothing);

      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => FileGateway.beforeClose!());
      var saved = await tester.runAsync(() => repository.load(a.id));
      expect(
        MarkdownDocument.decode(saved!).source,
        contains('- [x] Erste Aufgabe'),
      );
      expect(
        MarkdownDocument.decode(saved).source,
        contains('```\n- [ ] Nur Code\n```'),
      );
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('markdown-source'));
      await tester.enterText(
        field,
        '# Neue Überschrift\n\nNormaler Text\n\n- [ ] Neu\n',
      );
      await tester.tap(find.byTooltip('Fett'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains('**Text**'),
      );
      await tester.tap(find.text('Formatiert'));
      await markdownIo(
        tester,
        () => find.text('Neue Überschrift').evaluate().isNotEmpty,
      );
      await markdownIo(
        tester,
        () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => FileGateway.beforeClose!());
      saved = await tester.runAsync(() => repository.load(a.id));
      expect(MarkdownDocument.decode(saved!).source, contains('**Text**'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'link chooser inserts a real relative link and opens the target with backlinks',
    (tester) async {
      await open(tester, const Size(1440, 1000));
      await tester.tap(find.byTooltip('Link einfügen'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Andere Notiz'),
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
      await tester.tap(find.text('Formatiert'));
      await markdownIo(
        tester,
        () => find.text('Andere Notiz').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('Andere Notiz'));
      await tester.tap(find.text('Andere Notiz'));
      await markdownIo(
        tester,
        () => find.text('Zielabschnitt').evaluate().isNotEmpty,
      );
      expect(find.text('Meine Textnotiz'), findsOneWidget); // Backlink button.
      expect(find.text('Verlinkt aus'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('source undo survives switching to the formatted view', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('markdown-source'));
    final controller = tester.widget<TextField>(field).controller!;
    await tester.enterText(field, 'Erster Absatz');
    await tester.pump(const Duration(milliseconds: 700));
    await markdownIo(
      tester,
      () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
    );
    await tester.enterText(field, 'Zweiter Absatz');
    await tester.pump(const Duration(milliseconds: 700));
    await markdownIo(
      tester,
      () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Formatiert'));
    await markdownIo(
      tester,
      () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Rückgängig'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Erster Absatz');
    await tester.tap(find.byTooltip('Wiederholen'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Zweiter Absatz');
    await tester.tap(find.byTooltip('Speichern'));
    await markdownIo(
      tester,
      () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
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
    await tester.tap(find.byTooltip('Link einfügen'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Andere Notiz'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      '[Diese Stelle](<${b.documentPath}>) bleibt erhalten',
    );
    await tester.tap(find.byTooltip('Speichern'));
    await markdownIo(
      tester,
      () => find.byTooltip('Lokal gespeichert').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('new note dialog creates and opens a checklist', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NoterApp(repository: repository));
    await markdownIo(
      tester,
      () => find.text('Meine Textnotiz').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Neue Notiz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checkliste').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Erstellen'));
    await markdownIo(
      tester,
      () => find.byKey(const ValueKey('markdown-source')).evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdown-source')))
          .controller!
          .text,
      '- [ ] Erste Aufgabe\n',
    );
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
        expect(find.text('Meine Notizen'), findsNothing);
        await tester.tap(find.byTooltip('Notizliste einblenden'));
        await tester.pumpAndSettle();
        expect(find.text('Meine Notizen'), findsOneWidget);
        await tester.tap(find.text('Andere Notiz'));
        await markdownIo(
          tester,
          () => find.text('Zielabschnitt').evaluate().isNotEmpty,
        );
        expect(find.text('Meine Notizen'), findsNothing);
        await tester.ensureVisible(find.text('Markdown'));
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        final source = find.byKey(const ValueKey('markdown-source'));
        await tester.enterText(
          source,
          'Text auf dem Handy\n\n- [ ] Eine Aufgabe',
        );
        await tester.runAsync(() => FileGateway.beforeClose!());
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
    // The common opening helper waits for the short fixture's "Lernplan".
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
    await markdownIo(
      tester,
      () => find.text('Meine Textnotiz').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Meine Textnotiz'));
    await markdownIo(
      tester,
      () => find.byType(MarkdownEditorPage).evaluate().isNotEmpty,
    );
    expect(find.text('Lernplan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
