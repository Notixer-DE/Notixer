import 'dart:io';

import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/text_selection_toolbar.dart';
import 'package:noter/ui/editor_toolbar.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_graphics/pdf_graphics.dart';

Future<Uint8List> selectionPdf() async {
  final document = pw.Document();
  document.addPage(
    pw.Page(
      build: (_) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 100),
        child: pw.Text(
          'Alpha Beta Gamma\nSecond Zeile mit Text',
          style: pw.TextStyle(fontSize: 24),
        ),
      ),
    ),
  );
  return document.save();
}

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook note;
  late Uint8List bytes;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-text-selection-');
    repository = LocalNotebookRepository(directory);
    bytes = await selectionPdf();
    note = await repository.create('Textauswahl', bytes);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<EditorPaneState> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        localizationsDelegates: const [DartPdfEditorLocalizations.delegate],
        home: EditorPage(note: note, bytes: bytes, repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select text'));
    await tester.pumpAndSettle();
    return tester.state<EditorPaneState>(find.byType(EditorPane));
  }

  testWidgets(
    'selected PDF text creates a quoted Markdown source note with a return link',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pane = await open(tester);
      pane.viewer.selectAllTextOn(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Create linked source note'));
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 30));
        if (find.byType(MarkdownEditorPage).evaluate().isNotEmpty) break;
      }
      final notes = await tester.runAsync(repository.list);
      final source = notes!.singleWhere((n) => n.isMarkdown);
      final document = await tester.runAsync(
        () async => MarkdownDocument.decode(await repository.load(source.id)),
      );
      expect(document!.source, contains('> Alpha Beta Gamma'));
      final link = markdownLinks(document.source).single.href;
      expect(MarkdownLibrary.target(notes, source, link)?.id, note.id);
      expect(markdownPdfPage(Uri.parse(link).fragment), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  for (final (label, subtype) in [
    ('Highlight', 'Highlight'),
    ('Underline', 'Underline'),
    ('Strikethrough', 'StrikeOut'),
  ]) {
    for (final (name, color) in [
      ('Pink', 0xF4BBD0),
      ('Yellow', 0xFFE481),
      ('Blue', 0xB3E1F4),
      ('Green', 0xBCE9C9),
      ('Turquoise', 0x169FB8),
    ]) {
      testWidgets('$label $name preserves PDF text, pen style and undo', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pane = await open(tester);
        final editing = pane.editing;
        final previousColor = editing.color;
        final previousOpacity = editing.preferences.opacity;
        pane.viewer.selectAllTextOn(0);
        await tester.pumpAndSettle();
        expect(pane.viewer.selectedText, contains('Alpha Beta Gamma'));
        expect(pane.viewer.selectionRectsOn(0).length, greaterThanOrEqualTo(2));
        final before = tester.getRect(find.byType(PdfEditorView));
        await tester.ensureVisible(find.byTooltip('$label · $name'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('$label · $name'));
        await tester.pumpAndSettle();
        final annotation = editing.document.page(0).annotations.single;
        expect(annotation.subtype, subtype);
        expect(annotation.color, color);
        expect(annotation.dict['QuadPoints'], isNotNull);
        expect(editing.color, previousColor);
        expect(editing.preferences.opacity, previousOpacity);
        expect(editing.tool, isNull);
        expect(pane.viewer.hasSelection, isFalse);
        expect(tester.getRect(find.byType(PdfEditorView)), before);
        expect(
          find.byKey(const ValueKey('noter-text-selection-toolbar')),
          findsNothing,
        );
        editing.undo();
        expect(editing.document.page(0).annotations, isEmpty);
        editing.redo();
        expect(editing.document.page(0).annotations.single.subtype, subtype);
        await tester.runAsync(() async {
          expect(await pane.widget.session.save(), isTrue);
          final saved = PdfDocument.open(await repository.load(note.id));
          expect(saved.page(0).annotations.single.subtype, subtype);
          expect(
            PdfTextExtractor.extract(saved, 0).text,
            contains('Alpha Beta Gamma'),
          );
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final kind in [
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
  ]) {
    testWidgets('selects actual PDF text with ${kind.name}', (tester) async {
      final pane = await open(tester);
      // The annotation-selection arrow also supports native mouse text
      // selection and must offer the same markup actions as reader mode.
      if (kind == PointerDeviceKind.mouse) {
        pane.editing.tool = PdfEditTool.select;
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull, reason: 'opening editor');
      final text = PdfTextExtractor.extract(pane.editing.document, 0);
      final rect = pane.viewer.globalRectOf(
        0,
        text.findAll('Alpha').single.rects.single,
      )!;
      if (kind == PointerDeviceKind.mouse) {
        final gesture = await tester.startGesture(
          rect.centerLeft + const Offset(1, 0),
          kind: kind,
        );
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
        await gesture.moveTo(rect.centerRight - const Offset(1, 0));
        await tester.pump();
        await gesture.up();
      } else {
        final gesture = await tester.startGesture(rect.center, kind: kind);
        await tester.pump(const Duration(milliseconds: 800));
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'selecting text');
      expect(pane.viewer.selectedText, contains('Alpha'));
      expect(pane.viewer.selectedText, isNot(contains('Gamma')));
      expect(
        find.byKey(const ValueKey('noter-text-selection-toolbar')),
        findsOneWidget,
      );
      if (kind != PointerDeviceKind.mouse) {
        final beta = pane.viewer.globalRectOf(
          0,
          text.findAll('Beta').single.rects.single,
        )!;
        await tester.drag(
          find.byKey(const ValueKey('pdf-text-handle-end')),
          Offset(beta.right - rect.right, 0),
        );
        await tester.pumpAndSettle();
        expect(pane.viewer.selectedText, contains('Beta'));
        expect(pane.viewer.selectedText, isNot(contains('Gamma')));
      }
      await tester.tap(find.byTooltip('Highlight · Yellow'));
      await tester.pumpAndSettle();
      expect(
        pane.editing.document.page(0).annotations.single.subtype,
        'Highlight',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('copies and dismisses text without changing the PDF', (
    tester,
  ) async {
    final pane = await open(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    pane.viewer.selectAllTextOn(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy text'));
    await tester.pumpAndSettle();
    expect(copied, contains('Alpha Beta Gamma'));
    await tester.tap(find.byTooltip('Clear text selection'));
    await tester.pumpAndSettle();
    expect(pane.viewer.hasSelection, isFalse);
    expect(pane.editing.document.page(0).annotations, isEmpty);
    expect(pane.widget.session.dirty, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'selection bar scrolls on a phone with large text and in focus mode',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final pane = await open(tester);
      await tester.tap(find.byTooltip('Hide toolbars'));
      await tester.pumpAndSettle();
      pane.viewer.selectAllTextOn(0);
      await tester.pumpAndSettle();
      final toolbar = find.byType(NoterTextSelectionToolbar);
      await tester.scrollUntilVisible(
        find.byTooltip('Strikethrough · Turquoise'),
        150,
        scrollable: find.descendant(
          of: toolbar,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byTooltip('Strikethrough · Turquoise'));
      await tester.pumpAndSettle();
      expect(
        pane.editing.document.page(0).annotations.single.subtype,
        'StrikeOut',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'desktop keeps one tool strip and a collapsible page sidebar',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pane = await open(tester);
      final sidebar = find.byKey(const ValueKey('editor-page-sidebar'));
      expect(sidebar, findsOneWidget);
      expect(find.byType(EditorToolbar), findsOneWidget);
      expect(find.byType(PdfEditingToolbar), findsNothing);
      expect(
        tester
            .widget<PdfEditorView>(find.byType(PdfEditorView))
            .features
            .headerBar,
        isFalse,
      );
      pane.viewer.setZoom(1.5);
      await tester.pumpAndSettle();
      final scale = pane.viewer.zoom;
      await tester.tap(find.byTooltip('Page overview'));
      await tester.pumpAndSettle();
      expect(sidebar, findsNothing);
      expect(pane.viewer.zoom, closeTo(scale, .01));
      await tester.tap(find.byTooltip('Tool settings'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Color #238b7e'),
        ),
      );
      await tester.pumpAndSettle();
      expect(pane.editing.color, const Color(0xFF238B7E));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Page overview'));
      await tester.pumpAndSettle();
      expect(sidebar, findsOneWidget);
      await tester.tap(find.byTooltip('Hide toolbars'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorToolbar), findsNothing);
      expect(sidebar, findsNothing);
      expect(pane.viewer.zoom, closeTo(scale, .01));
      await tester.tap(find.byTooltip('Show toolbars'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorToolbar), findsOneWidget);
      expect(pane.viewer.zoom, closeTo(scale, .01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  for (final size in [const Size(390, 844), const Size(1100, 900)]) {
    testWidgets(
      'mobile opens page thumbnails as a dismissible sheet at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await open(tester);
        expect(find.byKey(const ValueKey('editor-page-sidebar')), findsNothing);
        await tester.tap(find.byTooltip('Page overview'));
        await tester.pumpAndSettle();
        final sheet = find.byKey(const ValueKey('editor-page-sheet'));
        expect(sheet, findsOneWidget);
        await tester.tap(find.descendant(of: sheet, matching: find.text('1')));
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
