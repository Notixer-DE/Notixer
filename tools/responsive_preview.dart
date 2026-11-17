// Render the responsive library and editor with real, local example documents.
// Run with tools/responsive_preview.py; no account or network is needed.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:noter/main.dart';
import 'package:noter/input/stylus_eraser.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';

class ResponsiveBinding extends NoterBinding {
  static final mode = Platform.environment['NOTER_RESPONSIVE_SIZE'] ?? 'tablet';
  static final size = switch (mode) {
    'phone' => const Size(390, 844),
    'portrait' => const Size(768, 1024),
    _ => const Size(1180, 820),
  };
  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) =>
      ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(size),
        physicalConstraints: BoxConstraints.tight(size),
        devicePixelRatio: 1,
      );
}

Future<void> main() async {
  ResponsiveBinding();
  FileGateway.initialize();
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.toString());
    stderr.writeln(details);
  };
  final directory = await Directory.systemTemp.createTemp('noter-responsive-');
  final repository = LocalNotebookRepository(directory);
  final boundary = GlobalKey();
  final navigator = GlobalKey<NavigatorState>();
  Future<void> pause() =>
      Future<void>.delayed(const Duration(milliseconds: 900));
  Future<void> capture(String scene) async {
    await pause();
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      'build/current-$scene-${ResponsiveBinding.mode}.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  }

  try {
    final document = pw.Document();
    document.addPage(
      pw.Page(
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('LINEAR ALGEBRA / LECTURE 04'),
            pw.SizedBox(height: 28),
            pw.Text(
              'Understanding vector spaces.',
              style: pw.TextStyle(fontSize: 28),
            ),
            pw.SizedBox(height: 25),
            pw.Text(
              'A vector space is a set of vectors.\n'
              'Addition and scalar multiplication are defined.',
              style: pw.TextStyle(fontSize: 16),
            ),
            pw.SizedBox(height: 24),
            pw.Text(
              'Linear independence means that no vector\n'
              'is a linear combination of the others.',
              style: pw.TextStyle(fontSize: 16),
            ),
            pw.SizedBox(height: 65),
            pw.Text(
              'Thinking geometrically',
              style: pw.TextStyle(fontSize: 18),
            ),
            pw.SizedBox(height: 30),
            pw.Text('A x = lambda x', style: pw.TextStyle(fontSize: 26)),
            pw.SizedBox(height: 45),
            pw.Text(
              'A basis describes all directions in the space.',
              style: pw.TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
    final bytes = await document.save();
    final folder = await repository.catalog.ensureFolder('Studies');
    for (final data in [('Lecture notes', 'lined'), ('Mathematics', 'grid')]) {
      final note = await repository.create(
        data.$1,
        await createPaper(data.$2),
        paper: data.$2,
      );
      await repository.save(
        note.copy(folderId: folder.id, tags: ['Maths']),
        await repository.load(note.id),
      );
    }
    final note = await repository.create('Linear algebra', bytes);
    await repository.save(
      note.copy(folderId: folder.id, tags: ['Exam']),
      bytes,
    );
    final markdown = await MarkdownLibrary(
      repository,
    ).create('Study plan for this week');
    final questions = await MarkdownLibrary(
      repository,
    ).create('Exam questions');
    final markdownBytes = MarkdownDocument(
      'A clear head. One small step at a time.\n\n'
      'This week I want to **really understand the basics**, '
      'rather than simply memorize everything.\n\n'
      '## What matters\n\n'
      '> Prefer 30 minutes of focused study each day to leaving everything '
      'until the final evening.\n\n'
      '## My next steps\n\n'
      '- [x] Organize lecture notes\n'
      '- [ ] Summarize chapter 3\n'
      '- [ ] Review the worksheet with Lea\n\n'
      '## Further notes\n\n'
      '[Linear algebra](${note.documentPath}) · '
      '[Exam questions](${questions.documentPath})\n',
    ).encode();
    final textNote = await repository.save(
      markdown.copy(folderId: folder.id),
      markdownBytes,
    );
    await repository.save(
      questions,
      MarkdownDocument(
        '# Exam questions\n\n[Study plan](${markdown.documentPath})\n',
      ).encode(),
    );
    runApp(
      RepaintBoundary(
        key: boundary,
        child: Builder(
          builder: (context) {
            final app =
                NoterApp(repository: repository).build(context) as MaterialApp;
            return MaterialApp(
              navigatorKey: navigator,
              theme: app.theme,
              locale: app.locale,
              supportedLocales: app.supportedLocales,
              localizationsDelegates: app.localizationsDelegates,
              debugShowCheckedModeBanner: false,
              home: app.home,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(size: ResponsiveBinding.size),
                child: child!,
              ),
            );
          },
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    await capture('library');
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            EditorPage(note: note, bytes: bytes, repository: repository),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    EditorPaneState? pane;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditorPaneState) {
        pane = element.state as EditorPaneState;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement!.visitChildren(visit);
    pane!.selectText();
    await pause();
    final text = PdfTextExtractor.extract(pane!.editing.document, 0);
    final rect = pane!.viewer.globalRectOf(
      0,
      text.findAll('Linearkombination').single.rects.single,
    )!;
    WidgetsBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: 30, position: rect.center),
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    WidgetsBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: 30, position: rect.center),
    );
    await capture('editor');
    if (!pane!.viewer.selectedText.contains('Linearkombination')) {
      throw StateError('Native text selection failed');
    }
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => MarkdownEditorPage(
          note: textNote,
          bytes: markdownBytes,
          repository: repository,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await capture('markdown');
    Element? toggle;
    void findToggle(Element element) {
      if (element.widget is Tooltip &&
          (element.widget as Tooltip).message == 'Show note list') {
        toggle = element;
      }
      element.visitChildren(findToggle);
    }

    WidgetsBinding.instance.rootElement!.visitChildren(findToggle);
    final box = toggle!.findRenderObject()! as RenderBox;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    WidgetsBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: 31, position: center),
    );
    WidgetsBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: 31, position: center),
    );
    await capture('markdown-list');
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    // ignore: avoid_print
    print(
      'PASS: responsive library, page previews and editor (${ResponsiveBinding.mode})',
    );
  } finally {
    runApp(const SizedBox.shrink());
    await pause();
    await repository.flush();
    await directory.delete(recursive: true);
  }
  exit(0);
}
