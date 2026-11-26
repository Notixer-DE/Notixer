import 'dart:io';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_toolbar.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/markdown_preview.dart';
import 'package:noter/ui/markdown_style.dart';
import 'package:noter/ui/notebook_preview.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/workspace_chrome.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'markdown_widget_test.dart' show markdownIo;
import 'widget_test.dart' show openWorkspaceFiles, settleFileIo;

const _captureKey = ValueKey('redesign-preview');

/// Optional geometry snapshots use Flutter's deterministic test fonts.
/// For real-font design review, use tools/design_preview.py instead.
Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['NOTER_DESIGN_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _frame(Widget app) => RepaintBoundary(key: _captureKey, child: app);
Widget _documentApp(Widget child) => MaterialApp(
  theme: NoterTheme.light,
  localizationsDelegates: const [DartPdfEditorLocalizations.delegate],
  builder: (context, child) =>
      Theme(data: NoterTheme.forWindow(context), child: child!),
  home: child,
);

void main() {
  test(
    'shared palette and typography distinguish chrome from document content',
    () {
      expect(NoterTheme.accent, const Color(0xFF238B7E));
      expect(NoterTheme.workspace, const Color(0xFFF5F7F7));
      expect(NoterTheme.ink, const Color(0xFF293139));
      expect(NoterTheme.border, const Color(0xFFE7EBE9));
      expect(NoterTheme.active, const Color(0xFFEAF5F1));
      expect(NoterTheme.light.cardTheme.elevation, 0);
      expect(NoterTheme.light.textTheme.bodyMedium!.fontSize, 14);
    },
  );

  for (final (platform, extent, height) in [
    (TargetPlatform.linux, 36.0, 44.0),
    (TargetPlatform.android, 48.0, 52.0),
  ]) {
    testWidgets(
      'toolbar keeps correct ${platform.name} targets even on a large screen',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        await tester.pumpWidget(
          _documentApp(
            Scaffold(
              body: WorkspaceToolbar(
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Tool',
                      onPressed: () => taps++,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byType(WorkspaceToolbar)).height, height);
        expect(
          tester.getSize(find.byType(IconButton)).width,
          greaterThanOrEqualTo(extent),
        );
        await tester.tap(find.byTooltip('Tool'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'reduced motion removes route fades without changing route content',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) {
                const content = SizedBox(
                  key: ValueKey('still-functional-route'),
                );
                final theme = Theme.of(context);
                final transition = theme
                    .pageTransitionsTheme
                    .builders[theme.platform]!
                    .buildTransitions(
                      MaterialPageRoute<void>(builder: (_) => content),
                      context,
                      const AlwaysStoppedAnimation<double>(.1),
                      const AlwaysStoppedAnimation<double>(0),
                      content,
                    );
                expect(transition, same(content));
                return transition;
              },
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('still-functional-route')),
        findsOneWidget,
      );
    },
  );

  for (final viewport in [
    (
      name: 'desktop',
      size: const Size(1440, 960),
      platform: TargetPlatform.linux,
      scale: 1.0,
    ),
    (
      name: 'short desktop',
      size: const Size(1100, 540),
      platform: TargetPlatform.linux,
      scale: 1.0,
    ),
    (
      name: 'phone',
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      scale: 1.0,
    ),
    (
      name: 'tablet',
      size: const Size(1024, 1000),
      platform: TargetPlatform.android,
      scale: 1.0,
    ),
    (
      name: 'large-text',
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      scale: 2.0,
    ),
  ]) {
    testWidgets(
      'library, PDF and Markdown share a readable ${viewport.name} workspace',
      (tester) async {
        tester.view.physicalSize = viewport.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = viewport.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('noter-redesign-'),
        ))!;
        // Repository queues must be created in the real event loop as well;
        // otherwise runAsync would wait on an unpumped fake-zone Future.value.
        final repository = (await tester.runAsync(
          () async => LocalNotebookRepository(directory),
        ))!;
        try {
          final doc = pw.Document()
            ..addPage(
              pw.Page(
                pageFormat: PdfPageFormat.a4,
                margin: const pw.EdgeInsets.all(48),
                build: (_) => pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Foundations of analysis',
                      style: pw.TextStyle(
                        fontSize: 24,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 16),
                    pw.Text(
                      'Lecture 03 / Differentialrechnung',
                      style: const pw.TextStyle(
                        fontSize: 12,
                        color: PdfColors.grey600,
                      ),
                    ),
                    pw.SizedBox(height: 36),
                    pw.Text(
                      '1. Understanding derivatives',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 20),
                    pw.Text(
                      'A derivative describes the instantaneous slope of a function. '
                      'It helps us describe local changes precisely.',
                      style: const pw.TextStyle(fontSize: 14, lineSpacing: 7),
                    ),
                    pw.SizedBox(height: 24),
                    pw.Container(
                      color: PdfColor.fromHex('#FFE481'),
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text(
                        'f(x) = x²     /     Derivative: 2x',
                        style: const pw.TextStyle(fontSize: 16),
                      ),
                    ),
                    pw.SizedBox(height: 32),
                    pw.Text(
                      '2. Think it through',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 16),
                    pw.Text(
                      'What is the slope of the function at x = 2? '
                      'Write down your steps and highlight important terms.',
                      style: const pw.TextStyle(fontSize: 14, lineSpacing: 7),
                    ),
                  ],
                ),
              ),
            );
          final pdfBytes = await tester.runAsync(doc.save);
          final pdfNote = await tester.runAsync(
            () => repository.create('Analysis · Lecture 03', pdfBytes!),
          );
          final markdownNote = await tester.runAsync(() async {
            final note = await MarkdownLibrary(
              repository,
            ).create('Project meeting');
            return repository.save(
              note,
              MarkdownDocument(
                '## A clearer next step\n\n'
                'One place for **thoughts, documents and decisions**.\n\n'
                '> Good tools keep the content in focus.\n\n'
                '### Decisions\n\n- [x] Draft discussed\n- [ ] Record next steps\n\n'
                '| Area | Status |\n| --- | --- |\n| Concept | Agreed |\n| Implementation | In progress |\n\n'
                '```dart\nfinal nextStep = "Keep thinking";\n```\n\n'
                '[Back to lecture](${pdfNote!.documentPath})',
              ).encode(),
            );
          });

          await tester.pumpWidget(_frame(NoterApp(repository: repository)));
          await openWorkspaceFiles(tester);
          await settleFileIo(
            tester,
            () => find.text('Project meeting').evaluate().isNotEmpty,
          );
          expect(
            find.byType(NotebookPreview),
            findsNothing,
            reason: 'Compact rows are the default',
          );
          if (find.byTooltip('Hide folders').evaluate().isNotEmpty) {
            expect(find.byType(WorkspaceSidebar), findsOneWidget);
            await tester.tap(find.byTooltip('Hide folders'));
            await tester.pumpAndSettle();
            expect(find.byType(WorkspaceSidebar), findsNothing);
            await tester.tap(find.byTooltip('Show folders'));
            await tester.pumpAndSettle();
            expect(find.byType(WorkspaceSidebar), findsOneWidget);
          }
          final row = find.byKey(ValueKey('library-row-${markdownNote!.id}'));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          if (viewport.scale == 1) {
            expect(tester.getSize(row).height, lessThan(110));
          }
          expect(find.byType(DocumentTypeBadge), findsWidgets);
          expect(tester.takeException(), isNull);
          await _capture(tester, 'library-${viewport.name}');
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();

          await tester.pumpWidget(
            _frame(
              _documentApp(
                EditorPage(
                  note: pdfNote!,
                  bytes: pdfBytes!,
                  repository: repository,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(EditorToolbar), findsOneWidget);
          expect(find.byType(PdfEditingToolbar), findsNothing);
          expect(
            tester.getSize(find.byType(PdfEditorView)).height,
            greaterThan(viewport.size.height * .6),
            reason: 'Content, not chrome, owns the viewport',
          );
          expect(tester.takeException(), isNull);
          await _capture(tester, 'pdf-${viewport.name}');
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();

          final markdownBytes = await tester.runAsync(
            () => repository.load(markdownNote.id),
          );
          await tester.pumpWidget(
            _frame(
              _documentApp(
                MarkdownEditorPage(
                  note: markdownNote,
                  bytes: markdownBytes!,
                  repository: repository,
                ),
              ),
            ),
          );
          await markdownIo(
            tester,
            () => find.byType(MarkdownPreview).evaluate().isNotEmpty,
          );
          final preview = tester.widget<MarkdownPreview>(
            find.byType(MarkdownPreview),
          );
          expect(
            find.byTooltip('Hide folders'),
            viewport.name == 'desktop' ? findsOneWidget : findsNothing,
          );
          expect(find.byTooltip('Show file list'), findsOneWidget);
          final paragraphFinder = find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                (widget.textSpan?.toPlainText().startsWith('One place for') ??
                    false),
          );
          for (var i = 0; i < 20 && paragraphFinder.evaluate().isEmpty; i++) {
            preview.scrollController.jumpTo(
              preview.scrollController.offset + 150,
            );
            await tester.pump();
          }
          final paragraph = tester.widget<SelectableText>(paragraphFinder);
          expect(paragraph.strutStyle!.fontSize, 14);
          expect(paragraph.strutStyle!.height, 1.55);
          expect(
            noterMarkdownStyle(
              tester.element(find.byType(MarkdownPreview)),
            ).codeblockDecoration,
            isA<BoxDecoration>(),
          );
          for (
            var i = 0;
            i < 20 && find.byType(Checkbox).evaluate().length < 2;
            i++
          ) {
            preview.scrollController.jumpTo(
              preview.scrollController.offset + 150,
            );
            await tester.pump();
          }
          expect(find.byType(Checkbox), findsNWidgets(2));
          preview.scrollController.jumpTo(0);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await _capture(tester, 'markdown-${viewport.name}');
          await tester.ensureVisible(find.text('Edit'));
          await tester.tap(find.text('Edit'));
          await tester.pumpAndSettle();
          final source = tester.widget<TextField>(
            find.byKey(const ValueKey('markdown-source')),
          );
          expect(source.undoController, isNotNull);
          expect(source.controller!.text, contains('## A clearer'));
          expect(tester.takeException(), isNull);
          await _capture(tester, 'markdown-source-${viewport.name}');
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        } finally {
          await tester.runAsync(() => directory.delete(recursive: true));
        }
      },
      variant: TargetPlatformVariant({viewport.platform}),
    );
  }
}
