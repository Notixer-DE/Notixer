import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/painting.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/operations.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' show PdfRect;

void verify(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> verifyAdvanced(Directory directory) async {
  final repo = LocalNotebookRepository(directory);
  final source = pw.Document()
    ..addPage(
      pw.Page(build: (_) => pw.Text('Original searchable lesson 6789')),
    );
  final original = await source.save();
  final note = await repo.create('Lecture', original);
  // Read old archives without eagerly rewriting them.
  final legacy = note.toJson()
    ..['version'] = 1
    ..remove('tags')
    ..remove('folderId')
    ..remove('folderName');
  final json = utf8.encode(jsonEncode(legacy));
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', json.length, json))
    ..addFile(ArchiveFile('document.pdf', original.length, original));
  final old = LocalNotebookRepository.decode(
    Uint8List.fromList(ZipEncoder().encode(archive)),
  ).$1;
  verify(
    old.tags.isEmpty && old.folderId == null,
    'Version 1 default metadata',
  );
  final folders = await Future.wait([
    repo.catalog.ensureFolder('Maths'),
    repo.catalog.ensureFolder('Maths'),
  ]);
  verify(
    folders[0].id == folders[1].id && repo.catalog.folders.length == 1,
    'Concurrent folder creation',
  );
  await repo.catalog.renameFolder(folders[0].id, 'Mathsmatics');
  final organized = await repo.save(
    note.copy(
      folderId: folders[0].id,
      folderName: 'Maths',
      tags: ['Exam', 'Semester 1'],
    ),
    original,
  );
  final other = LocalNotebookRepository(
    Directory('${directory.path}/transfer'),
  );
  final imported = await other.importArchive(
    await repo.exportArchive(organized),
  );
  verify(
    other.catalog.folderName(imported.folderId) == 'Mathsmatics' &&
        imported.tags.length == 2,
    'Folder rename and tags survive archive transfer',
  );
  await repo.catalog.setPreset(
    0,
    const PenPreset('Blue', 'ink', 0xFF2468B0, 3, .8),
  );
  final reloaded = LibraryCatalog(repo.catalog.file);
  await reloaded.load();
  verify(
    reloaded.presets[0].color == 0xFF2468B0 && reloaded.presets[0].width == 3,
    'Pen favorites persist',
  );
  final obstacle = Directory('${repo.catalog.file.path}.tmp');
  await obstacle.create();
  var failed = false;
  try {
    await repo.catalog.setPreset(
      0,
      const PenPreset('Fehler', 'ink', 0xFF000000, 1, 1),
    );
  } on FileSystemException {
    failed = true;
  }
  verify(
    failed && repo.catalog.presets[0].name == 'Blue',
    'Settings failures keep previous state',
  );
  await obstacle.delete();

  final preferences = PdfEditingPreferences(store: PdfMemoryPreferencesStore());
  await preferences.ready;
  final editing = PdfEditingController(original, preferences: preferences);
  try {
    preferences
      ..strokeWidth = 3
      ..opacity = .8;
    editing.addInkStroke(
      0,
      [(40, 40), (80, 65), (120, 90)],
      pressures: [.2, .6, .9],
    );
    editing.addInkStroke(
      0,
      [(300, 300), (340, 340), (380, 350)],
      pressures: [.3, .8, .6],
    );
    editing.finishInk();
    verify(
      editing.document.page(0).annotations.single.inkList!.length == 2,
      'Grouped ink fixture',
    );
    final selected = lassoSelect(editing, 0, const [
      Offset(20, 20),
      Offset(160, 20),
      Offset(160, 110),
      Offset(20, 110),
    ]);
    verify(
      selected == 1 && editing.document.page(0).annotations.length == 2,
      'Lasso splits grouped ink and selects one stroke',
    );
    editing.undo();
    verify(
      editing.document.page(0).annotations.single.inkList!.length == 2,
      'Undo restores the complete pre-lasso group',
    );
    editing.redo();
    lassoSelect(editing, 0, const [
      Offset(20, 20),
      Offset(160, 20),
      Offset(160, 110),
      Offset(20, 110),
    ]);
    final ink = editing.selectedAnnotation!;
    verify(
      (ink.appearanceOpacity - .8).abs() < .01 && ink.borderWidth == 3,
      'Lasso preserves ink style',
    );
    editing.moveSelected(20, 30);
    verify(
      editing.selectedAnnotation!.inkList!.first.first.$1 == 60,
      'Lasso selection moves',
    );
    final selectedName = editing.selectedAnnotation!.name;
    final beforeResize = editing.selectedAnnotation!.rect;
    editing.resizeSelected(
      PdfRect(
        beforeResize.left,
        beforeResize.bottom,
        beforeResize.left + beforeResize.width * 1.25,
        beforeResize.bottom + beforeResize.height * 1.25,
      ),
    );
    verify(
      (editing.selectedAnnotation!.rect.width - beforeResize.width * 1.25)
              .abs() <
          .01,
      'Lasso selection resizes proportionally',
    );
    editing.undo();
    editing.redo();
    editing.selectAnnotation(
      0,
      editing.document
          .page(0)
          .annotations
          .indexWhere((a) => a.name == selectedName),
    );
    editing.copySelectedAnnotations();
    editing.pasteAnnotations(0, at: (200, 200));
    verify(
      editing.document.page(0).annotations.length == 3,
      'Lasso selection copies and pastes',
    );
    editing.deleteSelected();
    editing.undo();
    editing.redo();
    verify(
      editing.document.page(0).annotations.length == 2,
      'Selection deletion undo/redo',
    );
    editing.addFreeText(
      0,
      const PdfRect(40, 200, 200, 240),
      'Typed explanation',
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 20, 10),
      ui.Paint()..color = const Color(0xFF2468B0),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(20, 10);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    verify(
      editing.placeImage(0, 200, 300, bytes!.buffer.asUint8List()),
      'PNG insertion',
    );
    image.dispose();
    picture.dispose();
    final stamp = editing.document.page(0).annotations.last;
    verify(
      (stamp.rect.width / stamp.rect.height - 2).abs() < .01,
      'Image aspect ratio',
    );
    addTape(editing, 0, const PdfRect(20, 400, 220, 440));
    verify(
      editing.document.page(0).annotations.where(isTape).length == 1,
      'Learning cover creation',
    );
    final without = PdfDocument.open(exportPdf(editing));
    final withCover = PdfDocument.open(exportPdf(editing, withTapes: true));
    verify(
      without.page(0).annotations.where(isTape).isEmpty,
      'Default PDF export omits covers',
    );
    verify(
      withCover.page(0).annotations.singleWhere(isTape).appearanceOpacity == 1,
      'Exercise PDF export shows covers',
    );
    verify(
      editing.document
              .page(0)
              .annotations
              .singleWhere(isTape)
              .appearanceOpacity ==
          0,
      'Export leaves editable source untouched',
    );
    for (final pdf in [
      exportPdf(editing),
      exportPdf(editing, withTapes: true),
    ]) {
      final file = File('${directory.path}/export-check.pdf');
      await file.writeAsBytes(pdf);
      if (File('/usr/bin/pdftotext').existsSync()) {
        final result = await Process.run('pdftotext', [file.path, '-']);
        verify(
          result.exitCode == 0 &&
              (result.stdout as String).contains(
                'Original searchable lesson 6789',
              ),
          'Original text survives PDF exports',
        );
      }
    }
    editing.duplicatePages([0]);
    verify(
      editing.document.pageCount == 2 &&
          editing.document.page(1).annotations.where(isTape).length == 1,
      'Page duplication preserves covers',
    );
    editing.movePage(0, 1);
    editing.rotatePages([1], 90);
    editing.copyPages([1]);
    verify(!editing.removePages([0, 1]), 'Last-page deletion refused');
    final targetPreferences = PdfEditingPreferences(
      store: PdfMemoryPreferencesStore(),
    );
    await targetPreferences.ready;
    final target = PdfEditingController(
      await createPaper('grid'),
      preferences: targetPreferences,
    );
    try {
      target.pastePages();
      verify(
        target.document.pageCount == 2 &&
            target.document.page(1).rotation == 90,
        'Cross-note page paste preserves rotation',
      );
      verify(
        target.document.page(1).annotations.where(isTape).length == 1,
        'Cross-note page paste preserves cover marker',
      );
      verify(
        target.document.page(1).annotations.any((a) => a.isImageStamp),
        'Cross-note page paste preserves images',
      );
      target.removePage(0);
      target.undo();
      verify(target.document.pageCount == 2, 'Page deletion undo');
    } finally {
      target.dispose();
      targetPreferences.dispose();
    }
    final saved = await repo.save(organized, editing.bytes);
    final transfer = await other.importArchive(await repo.exportArchive(saved));
    verify(
      PdfDocument.open(
            await other.load(transfer.id),
          ).page(1).annotations.where(isTape).length ==
          1,
      'Full document archive preserves covers and edited pages',
    );
    for (final rotation in [0, 90, 180, 270]) {
      final g = PdfPageGeometry(
        cropBox: const PdfRect(20, 30, 620, 830),
        rotation: rotation,
        viewSize: rotation % 180 == 0
            ? const Size(300, 400)
            : const Size(400, 300),
      );
      final p = g.toViewOffset(100, 300);
      final back = g.toPagePoint(p);
      verify(
        (back.$1 - 100).abs() < .001 && (back.$2 - 300).abs() < .001,
        'Page geometry round trip at rotation $rotation',
      );
    }
  } finally {
    editing.dispose();
    preferences.dispose();
  }
  final session = DocumentSession(
    organized,
    original,
    repo,
    preferencesStore: PdfMemoryPreferencesStore(),
  );
  try {
    session.editing.addFreeText(
      0,
      const PdfRect(30, 300, 200, 350),
      'Session one',
    );
    final saving = session.save();
    session.editing.addFreeText(
      0,
      const PdfRect(30, 400, 200, 450),
      'Session two',
    );
    verify(
      await saving && !session.dirty,
      'Session save drains edits arriving during write',
    );
    verify(
      PdfDocument.open(
            await repo.load(organized.id),
          ).page(0).annotations.length ==
          2,
      'Session saved newest revision',
    );
  } finally {
    session.dispose();
  }
}
