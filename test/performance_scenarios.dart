import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/ink.dart';
import 'fixtures/large_pdf.dart';

void requirePerformance(bool value, String message) {
  if (!value) throw StateError(message);
}

class CountingRepository extends LocalNotebookRepository {
  CountingRepository(super.directory);
  int saves = 0;
  @override
  Future<Notebook> save(Notebook note, Uint8List pdf) {
    saves++;
    return super.save(note, pdf);
  }

  @override
  Future<Notebook> saveWithInk(Notebook note, Uint8List pdf, InkDocument ink) {
    saves++;
    return super.saveWithInk(note, pdf, ink);
  }
}

Future<void> verifyPerformance(Directory directory) async {
  final repo = LocalNotebookRepository(Directory('${directory.path}/large'));
  final pdf = largeScan(pages: 500, side: 2048);
  final note = await repo.create('Großer Scan', pdf);
  final file = File('${repo.directory.path}/${note.id}.noter');
  final original = await file.readAsBytes();
  final zip = ZipDecoder().decodeBytes(original, verify: true);
  requirePerformance(
    zip.find('document.pdf')!.compression == CompressionType.none,
    'PDF payload must not be redundantly deflated',
  );
  requirePerformance(
    (await repo.list()).single.id == note.id,
    'Large document appears in library',
  );
  final loaded = await repo.load(note.id);
  requirePerformance(
    PdfDocument.open(loaded).pageCount == 500,
    'All 500 pages survive background save/load',
  );
  // An invalid PDF payload proves that listing reads only the manifest. The
  // full CRC/PDF validation is still mandatory when the note is opened.
  final corrupt = Uint8List.fromList(original);
  final header = String.fromCharCodes(corrupt.take(4096)).indexOf('%PDF-');
  requirePerformance(header >= 0, 'Stored PDF header found');
  corrupt[header] = 0;
  await file.writeAsBytes(corrupt, flush: true);
  requirePerformance(
    (await repo.list()).single.title == note.title,
    'Library metadata must not inflate or validate complete PDF payloads',
  );
  var rejected = false;
  try {
    await repo.load(note.id);
  } catch (_) {
    rejected = true;
  }
  requirePerformance(rejected, 'Opening still rejects corrupt payloads');
  await file.writeAsBytes(original, flush: true);

  // Keep v1/v2 DEFLATE archives readable after switching local writes to STORE.
  final legacy = Archive()
    ..addFile(zip.find('manifest.json')!)
    ..addFile(ArchiveFile('document.pdf', pdf.length, pdf));
  await file.writeAsBytes(ZipEncoder().encode(legacy), flush: true);
  requirePerformance(
    (await repo.list()).single.id == note.id &&
        PdfDocument.open(await repo.load(note.id)).pageCount == 500,
    'Legacy compressed archives remain readable',
  );

  final small = await createPaper('lined');
  final counted = CountingRepository(Directory('${directory.path}/session'));
  final saved = await counted.create('Stift', small);
  final session = DocumentSession(
    saved,
    small,
    counted,
    preferencesStore: PdfMemoryPreferencesStore(),
    autosaveDelay: const Duration(milliseconds: 20),
    checkpointInterval: const Duration(milliseconds: 30),
  );
  try {
    await session.preferences.ready;
    var notifications = 0;
    session.addListener(() {
      notifications++;
    });
    session.eraser.handle(
      const PointerDownEvent(
        pointer: 90,
        kind: PointerDeviceKind.stylus,
        position: Offset(30, 30),
        buttons: kStylusContact,
      ),
      (_) {},
    );
    session.editing.addInkStroke(0, [(30, 30), (50, 50)]);
    requirePerformance(session.dirty, 'Pending live ink is shown as unsaved');
    final initialNotifications = notifications;
    for (var i = 0; i < 20; i++) {
      session.editing.addInkStroke(0, [(30.0 + i, 30), (50.0 + i, 50)]);
    }
    requirePerformance(
      notifications == initialNotifications,
      'Buffered strokes must not rebuild the workspace once per stroke',
    );
    final previousSaves = counted.saves;
    await Future<void>.delayed(const Duration(milliseconds: 90));
    requirePerformance(
      counted.saves == previousSaves,
      'Autosave must defer while the physical stylus contact is active',
    );
    session.eraser.handle(
      const PointerUpEvent(
        pointer: 90,
        kind: PointerDeviceKind.stylus,
        position: Offset(50, 50),
      ),
      (_) {},
    );
    for (var i = 0; i < 100 && session.dirty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    requirePerformance(
      !session.dirty && counted.saves > previousSaves,
      'Pending strokes are checkpointed after the stylus is lifted',
    );
    requirePerformance(
      PdfDocument.open(
        await counted.load(saved.id),
      ).page(0).annotations.isNotEmpty,
      'Checkpointed handwriting survives reopening',
    );
    requirePerformance(
      notifications < 10,
      'Status updates remain bounded for 21 strokes',
    );
  } finally {
    session.dispose();
  }
}
