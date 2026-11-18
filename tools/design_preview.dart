// Real-font screenshots of the existing application. Not an alternative UI.
// Run with tools/design_preview.py; all documents are disposable sample data.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/library_graph_page.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'preview.dart' show PreviewBinding;

final _boundary = GlobalKey();
Future<void> _pause() =>
    Future<void>.delayed(const Duration(milliseconds: 700));

Future<void> _show(Widget app) async {
  runApp(const SizedBox());
  await _pause();
  runApp(RepaintBoundary(key: _boundary, child: app));
  await _pause();
  await _pause();
}

Future<void> _capture(String name) async {
  final render =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await Directory('build/design-preview').create(recursive: true);
  await File(
    'build/design-preview/$name.png',
  ).writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
}

Widget _app(Widget home) => MaterialApp(
  theme: NoterTheme.light,
  debugShowCheckedModeBanner: false,
  builder: (context, child) =>
      Theme(data: NoterTheme.forWindow(context), child: child!),
  home: home,
);

Element _find(bool Function(Widget) matches) {
  Element? found;
  void visit(Element element) {
    if (matches(element.widget)) found ??= element;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return found ?? (throw StateError('Preview control missing'));
}

Future<void> main() async {
  final device = Platform.environment['NOTER_DESIGN_DEVICE'] ?? 'desktop';
  PreviewBinding.size = switch (device) {
    'phone' => const Size(390, 844),
    'tablet' => const Size(1024, 1000),
    _ => const Size(1440, 960),
  };
  PreviewBinding();
  debugDefaultTargetPlatformOverride = device == 'desktop'
      ? TargetPlatform.linux
      : TargetPlatform.android;
  registerBundledEditorAssets();
  final errors = <FlutterErrorDetails>[];
  FlutterError.onError = (details) {
    errors.add(details);
    FlutterError.dumpErrorToConsole(details);
  };
  final directory = await Directory.systemTemp.createTemp('noter-design-');
  final repository = LocalNotebookRepository(directory);
  try {
    final pdf = pw.Document()
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
                  fontSize: 25,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 16),
              pw.Text(
                'LECTURE 03  /  DIFFERENTIAL CALCULUS',
                style: const pw.TextStyle(
                  fontSize: 10,
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
    final bytes = await pdf.save();
    final folder = await repository.catalog.ensureFolder('Studies');
    var pdfNote = await repository.create('Analysis · Lecture 03', bytes);
    pdfNote = await repository.save(
      pdfNote.copy(folderId: folder.id, tags: ['Lecture']),
      bytes,
    );
    final markdownNote = await MarkdownLibrary(
      repository,
    ).create('Project meeting');
    final markdown = MarkdownDocument(
      '## A clearer next step\n\n'
      'One place for **thoughts, documents and decisions**.\n\n'
      '> Good tools keep the content in focus.\n\n'
      '### Decisions\n\n- [x] Draft discussed\n- [ ] Record next steps\n\n'
      '| Area | Status |\n| --- | --- |\n| Concept | Agreed |\n| Implementation | In progress |\n\n'
      '```dart\nfinal nextStep = "Keep thinking";\n```\n\n'
      '[Back to lecture](${pdfNote.documentPath})',
    ).encode();
    await repository.save(markdownNote, markdown);
    await MarkdownLibrary(repository).create('Reading list', checklist: true);
    await repository.create('Worksheet · week 03', bytes);

    await _show(NoterApp(repository: repository));
    await _capture('library-$device');
    await _show(_app(LibraryGraphPage(repository: repository)));
    await _capture('graph-$device');
    await _show(
      _app(EditorPage(note: pdfNote, bytes: bytes, repository: repository)),
    );
    await _capture('pdf-$device');
    await _show(
      _app(
        MarkdownEditorPage(
          note: markdownNote,
          bytes: markdown,
          repository: repository,
        ),
      ),
    );
    await _capture('markdown-$device');
    final mode =
        _find((widget) => widget is SegmentedButton<bool>).widget
            as SegmentedButton<bool>;
    mode.onSelectionChanged!({true});
    await _pause();
    await _capture('markdown-source-$device');
    if (errors.isNotEmpty) throw StateError('${errors.length} Flutter errors');
    // ignore: avoid_print
    print('PASS: real application screenshots rendered for $device');
  } finally {
    runApp(const SizedBox());
    await _pause();
    await repository.flush();
    await directory.delete(recursive: true);
  }
  exit(0);
}
