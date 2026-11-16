// Standalone engine check for environments where Flutter's test server cannot bind sockets.
import 'dart:io';
import 'dart:typed_data';
import '../test/advanced_scenarios.dart';
import '../test/sync_scenarios.dart';
import '../test/performance_scenarios.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:dart_pdf_editor_assets/dart_pdf_editor_assets.dart';
import 'package:flutter/material.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' show PdfRect;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
  // ignore: avoid_print
  print('PASS: $message');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledEditorAssets();
  final directory = await Directory.systemTemp.createTemp('noter-smoke-');
  try {
    final repo = LocalNotebookRepository(directory);
    for (final pattern in ['blank', 'lined', 'grid']) {
      final bytes = await createPaper(pattern, pages: 2);
      validatePdf(bytes);
      check(
        PdfDocument.open(bytes).pageCount == 2,
        '$pattern paper has two valid pages',
      );
    }
    final source = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('Searchable original 12345')));
    final original = await source.save();
    final preferences = PdfEditingPreferences(
      store: PdfMemoryPreferencesStore(),
    );
    await preferences.ready;
    preferences.fingerDrawsInk = false;
    final editing = PdfEditingController(original, preferences: preferences);
    editing.addInkStroke(
      0,
      [(50, 50), (100, 80), (120, 120)],
      pressures: [0.1, 0.5, 1],
    );
    editing.finishInk();
    final ink = Uint8List.fromList(editing.bytes);
    check(ink.length > original.length, 'ink creates a PDF revision');
    editing.undo();
    check(editing.bytes.length == original.length, 'undo restores original');
    editing.redo();
    check(editing.bytes.length == ink.length, 'redo restores handwriting');
    editing.tool = PdfEditTool.highlight;
    editing.addInkStroke(0, [(40, 200), (200, 200)]);
    editing.finishInk();
    editing.addFreeText(0, const PdfRect(40, 300, 250, 350), 'Getippte Notiz');
    check(
      editing.document.page(0).annotations.length == 3,
      'pen, highlighter and typed text create editable annotations',
    );
    var note = await repo.create('Übung', editing.bytes, paper: 'lined');
    note = await repo.save(note.copy(title: 'Mathematik'), editing.bytes);
    final reopened = LocalNotebookRepository(directory);
    check(
      (await reopened.list()).single.title == 'Mathematik',
      'metadata survives reopening',
    );
    final imported = await reopened.importArchive(
      await reopened.exportArchive(note),
    );
    check(
      imported.id != note.id && imported.paper == 'lined',
      'archive import preserves paper and uses a fresh ID',
    );
    final output = await reopened.load(imported.id);
    final file = File('${directory.path}/export.pdf');
    await file.writeAsBytes(output);
    final text = await Process.run('pdftotext', [file.path, '-']);
    check(
      text.exitCode == 0 &&
          (text.stdout as String).contains('Searchable original 12345'),
      'independent PDF reader finds original text after editing/export',
    );
    final obstacle = Directory('${directory.path}/${note.id}.noter.tmp');
    await obstacle.create();
    var failed = false;
    try {
      await repo.save(note.copy(title: 'Unsaved'), output);
    } on FileSystemException {
      failed = true;
    }
    check(
      failed &&
          (await repo.list()).any(
            (n) => n.id == note.id && n.title == 'Mathematik',
          ),
      'failed write preserves previous saved version',
    );
    await obstacle.delete();
    await repo.save(note.copy(title: 'Recovered'), output);
    check(
      (await repo.list()).any((n) => n.title == 'Recovered'),
      'save queue recovers after failure',
    );
    await repo.delete(note.id);
    check(
      (await repo.list()).length == 1,
      'delete removes only chosen document',
    );
    editing.dispose();
    preferences.dispose();
    // ignore: avoid_print
    print('Basic checks passed. Running Noter 1.1 scenarios …');
    await verifyAdvanced(Directory('${directory.path}/advanced'));
    await verifySync(Directory('${directory.path}/sync'));
    await verifyPerformance(Directory('${directory.path}/performance'));
    // ignore: avoid_print
    print(
      'All standalone smoke checks passed, including Noter 1.3 performance.',
    );
    exit(0);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  } finally {
    await directory.delete(recursive: true);
  }
}
