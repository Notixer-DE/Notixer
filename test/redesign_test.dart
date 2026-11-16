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
import 'widget_test.dart' show settleFileIo;

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
                      tooltip: 'Werkzeug',
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
        await tester.tap(find.byTooltip('Werkzeug'));
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
                      'Grundlagen der Analysis',
                      style: pw.TextStyle(
                        fontSize: 24,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 16),
                    pw.Text(
                      'Vorlesung 03 / Differentialrechnung',
                      style: const pw.TextStyle(
                        fontSize: 12,
                        color: PdfColors.grey600,
                      ),
                    ),
                    pw.SizedBox(height: 36),
                    pw.Text(
                      '1. Ableitungen verstehen',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 20),
                    pw.Text(
                      'Die Ableitung beschreibt die momentane Steigung einer Funktion. '
                      'Sie hilft uns, lokale Veraenderungen praezise zu beschreiben.',
                      style: const pw.TextStyle(fontSize: 14, lineSpacing: 7),
                    ),
                    pw.SizedBox(height: 24),
                    pw.Container(
                      color: PdfColor.fromHex('#FFE481'),
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text(
                        'f(x) = x²     /     Ableitung: 2x',
                        style: const pw.TextStyle(fontSize: 16),
                      ),
                    ),
                    pw.SizedBox(height: 32),
                    pw.Text(
                      '2. Gemeinsam weiterdenken',
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 16),
                    pw.Text(
                      'Welche Steigung hat die Funktion an der Stelle x = 2? '
                      'Notiere deinen Rechenweg und markiere wichtige Begriffe.',
                      style: const pw.TextStyle(fontSize: 14, lineSpacing: 7),
                    ),
                  ],
                ),
              ),
            );
          final pdfBytes = await tester.runAsync(doc.save);
          final pdfNote = await tester.runAsync(
            () => repository.create('Analysis · Vorlesung 03', pdfBytes!),
          );
          final markdownNote = await tester.runAsync(() async {
            final note = await MarkdownLibrary(
              repository,
            ).create('Projektbesprechung');
            return repository.save(
              note,
              MarkdownDocument(
                '## Klarheit im nächsten Schritt\n\n'
                'Ein gemeinsamer Ort für **Gedanken, Dokumente und Entscheidungen**.\n\n'
                '> Gute Werkzeuge lassen den Inhalt im Mittelpunkt stehen.\n\n'
                '### Entscheidungen\n\n- [x] Entwurf besprochen\n- [ ] Nächste Schritte festhalten\n\n'
                '| Bereich | Stand |\n| --- | --- |\n| Konzept | Abgestimmt |\n| Umsetzung | In Arbeit |\n\n'
                '```dart\nfinal nextStep = "Einfach weiterdenken";\n```\n\n'
                '[Zur Vorlesung](${pdfNote!.documentPath})',
              ).encode(),
            );
          });

          await tester.pumpWidget(_frame(NoterApp(repository: repository)));
          await settleFileIo(
            tester,
            () => find.text('Projektbesprechung').evaluate().isNotEmpty,
          );
          expect(
            find.byType(NotebookPreview),
            findsNothing,
            reason: 'Compact rows are the default',
          );
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
          final paragraphFinder = find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                (widget.textSpan?.toPlainText().startsWith(
                      'Ein gemeinsamer Ort',
                    ) ??
                    false),
          );
          for (var i = 0; i < 20 && paragraphFinder.evaluate().isEmpty; i++) {
            preview.scrollController.jumpTo(
              preview.scrollController.offset + 150,
            );
            await tester.pump();
          }
          final paragraph = tester.widget<SelectableText>(paragraphFinder);
          expect(paragraph.strutStyle!.fontSize, 16);
          expect(paragraph.strutStyle!.height, 1.65);
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
          await tester.ensureVisible(find.text('Markdown'));
          await tester.tap(find.text('Markdown'));
          await tester.pumpAndSettle();
          final source = tester.widget<TextField>(
            find.byKey(const ValueKey('markdown-source')),
          );
          expect(source.undoController, isNotNull);
          expect(source.controller!.text, contains('## Klarheit'));
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
