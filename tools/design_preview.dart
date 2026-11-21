// Real-font screenshots of the existing application. Not an alternative UI.
// Run with tools/design_preview.py; all documents are disposable sample data.
import 'dart:io';
import 'package:noter/data/media.dart';
import 'package:noter/ui/media_page.dart';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/knowledge_page.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/ui/library_graph_page.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:noter/input/stylus_eraser.dart' show NoterBinding;
import 'package:noter/ui/workspace_navigation.dart';
import 'preview.dart' show PreviewBinding, tapElement;

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

double _textScale = 1;
Widget _app(Widget home) => MaterialApp(
  theme: NoterTheme.light,
  debugShowCheckedModeBanner: false,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(_textScale)),
    child: Theme(data: NoterTheme.forWindow(context), child: child!),
  ),
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

Future<Element> _waitFor(bool Function(Widget) matches) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    try {
      return _find(matches);
    } on StateError {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return _find(matches);
}

Future<void> main() async {
  const interactive = bool.fromEnvironment('NOTIXER_DESIGN_INTERACTIVE');
  final device = Platform.environment['NOTER_DESIGN_DEVICE'] ?? 'desktop';
  PreviewBinding.size = switch (device) {
    'phone' || 'phone-large-text' => const Size(390, 844),
    'phone-landscape' => const Size(844, 390),
    'phone-small' => const Size(320, 568),
    'tablet-600' => const Size(600, 960),
    'tablet-768' => const Size(768, 1024),
    'tablet-landscape' => const Size(1024, 768),
    'desktop-small' => const Size(1280, 720),
    'small-desktop' => const Size(1024, 768),
    'tablet' => const Size(1024, 1000),
    _ => const Size(1440, 900),
  };
  _textScale = device == 'phone-large-text' ? 2 : 1;
  if (interactive) {
    NoterBinding();
  } else {
    PreviewBinding();
    debugDefaultTargetPlatformOverride =
        device.startsWith('desktop') || device == 'small-desktop'
        ? TargetPlatform.linux
        : TargetPlatform.android;
  }
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
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 480, 320),
        Paint()..color = const Color(0xFFEAF5F1),
      );
    canvas.drawCircle(
      const Offset(160, 130),
      80,
      Paint()..color = NoterTheme.accent,
    );
    canvas.drawRect(
      const Rect.fromLTWH(260, 70, 140, 180),
      Paint()..color = NoterTheme.ink,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(480, 320);
    final imageBytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    final photo = await repository.create(
      'Meeting whiteboard',
      imageBytes,
      paper: 'media:png',
    );
    await repository.save(
      photo.copy(folderId: folder.id, tags: ['Meeting']),
      imageBytes,
    );
    final audioBytes = Uint8List.fromList([
      0,
      0,
      0,
      24,
      ...'ftypM4A '.codeUnits,
      0,
      0,
      0,
      0,
    ]);
    final audio = await repository.create(
      'Voice message · meeting summary',
      audioBytes,
      paper: 'media:m4a',
    );

    final store = KnowledgeStore(repository);
    final today = DateUtils.dateOnly(DateTime.now());
    await store.addQuickTodo(
      'Review the lecture',
      due: today,
      projectId: folder.id,
    );
    await store.addQuickTodo(
      'Prepare reading notes',
      due: today.subtract(const Duration(days: 1)),
    );
    await store.addQuickTodo('Collect sources');
    await store.appendJournal(
      today,
      'Finished the first set of exercises and wrote down the next question.',
      entryId: 'preview',
      recordedAt: today.add(const Duration(hours: 9, minutes: 15)),
    );
    if (interactive) {
      runApp(_app(DocumentWorkspace(repository: repository)));
      await WidgetsBinding.instance.endOfFrame;
      // Keep the seeded workspace alive until the native app exits.
      await ProcessSignal.sigint.watch().first;
      return;
    }

    Future<void> destination(WorkspaceArea area) => tapElement(
      _find((widget) => widget.key == ValueKey('workspace-${area.name}')),
    );
    await _show(_app(DocumentWorkspace(repository: repository)));
    final startTimer = await _waitFor(
      (widget) => widget is IconButton && widget.tooltip == 'Open focus timer',
    );
    await _capture('today-$device');
    await tapElement(startTimer);
    await tapElement(
      await _waitFor((widget) => widget is Text && widget.data == 'Start'),
    );
    final running = await _waitFor(
      (widget) => widget is Text && widget.data == 'Time tracked · Running',
    );
    await _capture('focus-timer-$device');
    Navigator.of(running).pop();
    await _pause();
    await destination(WorkspaceArea.journal);
    await _capture('workspace-journal-$device');
    await destination(WorkspaceArea.tasks);
    await _capture('workspace-tasks-$device');
    await destination(WorkspaceArea.files);
    await _capture('library-$device');
    final workspace =
        (_find((widget) => widget is DocumentWorkspace) as StatefulElement)
                .state
            as DocumentWorkspaceState;
    await workspace.openNotebook(pdfNote);
    await _pause();
    await _pause();
    await _pause();
    await _capture('workspace-pdf-$device');
    await tapElement(
      _find((widget) => widget.key == const ValueKey('pdf-mode-draw')),
    );
    await _capture('workspace-pdf-draw-$device');
    await workspace.openNotebook(markdownNote);
    await _pause();
    await _capture('workspace-markdown-$device');
    await workspace.openNotebook(pdfNote);
    await _pause();
    await _pause();
    await _capture('workspace-pdf-return-$device');
    await workspace.openNotebook(markdownNote);
    await _pause();
    final hideTabs =
        _find(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Hide document tabs',
            ).widget
            as IconButton;
    hideTabs.onPressed!();
    await _pause();
    await _capture('workspace-hidden-tabs-$device');
    await _show(_app(LibraryGraphPage(repository: repository)));
    await _capture('graph-$device');
    await KnowledgeStore(repository).journal(DateTime(2026, 11, 18));
    await _show(
      _app(KnowledgePage(repository: repository, initialSection: 'Tasks')),
    );
    await _capture('tasks-$device');
    await _show(
      _app(KnowledgePage(repository: repository, initialSection: 'Journal')),
    );
    await _capture('journal-$device');
    await _show(
      _app(KnowledgePage(repository: repository, initialSection: 'Templates')),
    );
    await _capture('templates-$device');
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
    await _show(
      _app(
        MediaPage(
          name: photo.title,
          bytes: imageBytes,
          format: MediaFormat.of('png')!,
          note: photo,
          repository: repository,
        ),
      ),
    );
    await _capture('media-image-$device');
    await _show(
      _app(
        MediaPage(
          name: audio.title,
          bytes: audioBytes,
          format: MediaFormat.of('m4a')!,
          note: audio,
          repository: repository,
        ),
      ),
    );
    await _capture('media-audio-$device');
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
