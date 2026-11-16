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
            pw.Text('LINEARE ALGEBRA / VORLESUNG 04'),
            pw.SizedBox(height: 28),
            pw.Text(
              'Vektorraeume verstehen.',
              style: pw.TextStyle(fontSize: 28),
            ),
            pw.SizedBox(height: 25),
            pw.Text(
              'Ein Vektorraum ist eine Menge von Vektoren.\n'
              'Addition und skalare Multiplikation sind definiert.',
              style: pw.TextStyle(fontSize: 16),
            ),
            pw.SizedBox(height: 24),
            pw.Text(
              'Lineare Unabhaengigkeit bedeutet, dass kein Vektor\n'
              'als Linearkombination der anderen dargestellt wird.',
              style: pw.TextStyle(fontSize: 16),
            ),
            pw.SizedBox(height: 65),
            pw.Text('Geometrisch gedacht', style: pw.TextStyle(fontSize: 18)),
            pw.SizedBox(height: 30),
            pw.Text('A x = lambda x', style: pw.TextStyle(fontSize: 26)),
            pw.SizedBox(height: 45),
            pw.Text(
              'Eine Basis beschreibt alle Richtungen im Raum.',
              style: pw.TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
    final bytes = await document.save();
    final folder = await repository.catalog.ensureFolder('Studium');
    for (final data in [
      ('Vorlesungsnotizen', 'lined'),
      ('Mathematik', 'grid'),
    ]) {
      final note = await repository.create(
        data.$1,
        await createPaper(data.$2),
        paper: data.$2,
      );
      await repository.save(
        note.copy(folderId: folder.id, tags: ['Mathe']),
        await repository.load(note.id),
      );
    }
    final note = await repository.create('Lineare Algebra', bytes);
    await repository.save(
      note.copy(folderId: folder.id, tags: ['Prüfung']),
      bytes,
    );
    final markdown = await MarkdownLibrary(
      repository,
    ).create('Lernplan für diese Woche');
    final questions = await MarkdownLibrary(
      repository,
    ).create('Prüfungsfragen');
    final markdownBytes = MarkdownDocument(
      'Ein klarer Kopf. Ein kleiner Schritt nach dem anderen.\n\n'
      'Diese Woche möchte ich **die Grundlagen wirklich verstehen**, '
      'statt nur alles auswendig zu lernen.\n\n'
      '## Worauf es ankommt\n\n'
      '> Lieber jeden Tag 30 Minuten konzentriert lernen als alles auf '
      'den letzten Abend verschieben.\n\n'
      '## Meine nächsten Schritte\n\n'
      '- [x] Vorlesungsnotizen sortieren\n'
      '- [ ] Kapitel 3 zusammenfassen\n'
      '- [ ] Übungsblatt mit Lea durchgehen\n\n'
      '## Weiterführende Notizen\n\n'
      '[Lineare Algebra](${note.documentPath}) · '
      '[Prüfungsfragen](${questions.documentPath})\n',
    ).encode();
    final textNote = await repository.save(
      markdown.copy(folderId: folder.id),
      markdownBytes,
    );
    await repository.save(
      questions,
      MarkdownDocument(
        '# Prüfungsfragen\n\n[Lernplan](${markdown.documentPath})\n',
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
          (element.widget as Tooltip).message == 'Notizliste einblenden') {
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
