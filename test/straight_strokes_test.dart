import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/ink_gestures.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'sync_scenarios.dart' show MemoryRemote;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ruler uses two snapped endpoints with bounded live work and preserves freehand',
    () {
      final ink = InkController(InkDocument(generation: 'ruler'));
      final live = LiveInk(ink);
      live.begin('1:0', 0xff123456, 2, straight: true);
      live.add(10, 20, .5);
      for (var i = 0; i < 10000; i++) {
        live.add(10 + i * .1, 20 + (i % 5), .5);
        expect(live.tailPoints, lessThanOrEqualTo(2));
      }
      live.finish();
      final horizontal = ink.index.strokes.single;
      expect(horizontal.pointCount, 2);
      expect(horizontal.points[1], horizontal.points[4]);
      live.begin('1:0', 0xff123456, 2, straight: true);
      live.add(300, 30, .5);
      live.add(304, 400, .5);
      live.finish();
      final vertical = ink.index.strokes.last;
      expect(vertical.points[0], vertical.points[3]);
      live.begin('1:0', 0xff123456, 2);
      live.add(10, 20, .5);
      live.add(30, 40, .5);
      live.add(60, 70, .5);
      live.finish();
      expect(ink.index.strokes.last.pointCount, 3);
      live.dispose();
      ink.dispose();
    },
  );

  test('point eraser splits the middle of a two-point ruler line', () {
    final ink = InkController(InkDocument(generation: 'erase-line'));
    final live = LiveInk(ink)..begin('1:0', 0xff123456, 2, straight: true);
    live.add(20, 100, .5);
    live.add(200, 100, .5);
    live.finish();
    final erase = InkEraserGesture(ink, '1:0', 4)..add(const Offset(100, 100));
    erase.finish();
    final pieces = ink.index.strokes.toList();
    expect(pieces, hasLength(2));
    expect(pieces.first.points.first, 20);
    expect(pieces.last.points[pieces.last.points.length - 3], 200);
    expect(pieces.every((s) => s.points[1] == s.points[4]), isTrue);
    expect(pieces.first.points[pieces.first.points.length - 3], lessThan(100));
    expect(pieces.last.points.first, greaterThan(100));
    live.dispose();
    ink.dispose();
  });

  test(
    'ruler policy persists while straight geometry transfers independently through sync and PDF',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-ruler-');
      try {
        final repo = LocalNotebookRepository(Directory('${root.path}/a'));
        final bytes = await createPaper('blank');
        final note = await repo.create('Lineal', bytes);
        await repo.catalog.drawingPreferences.setStraightStrokes(true);
        final ink = InkController(InkDocument(generation: 'sync-ruler'));
        final live = LiveInk(ink)
          ..begin(
            inkPageId(PdfDocument.open(bytes), 0),
            0x80445566,
            4,
            straight: true,
          );
        live.add(20, 100, .5);
        live.add(300, 110, .5);
        live.finish();
        await repo.saveWithInk(note, bytes, ink.snapshot());
        final remote = MemoryRemote();
        await NotebookSync(repo, remote).run();
        final other = LocalNotebookRepository(Directory('${root.path}/b'));
        await NotebookSync(other, remote).run();
        final loaded = (await other.openInk(note.id)).$1;
        expect(
          loaded.strokes.single.points,
          orderedEquals(ink.index.strokes.single.points),
        );
        final pdf = PdfDocument.open(await other.loadPdf(note.id));
        expect(pdf.page(0).annotations.single.inkList!.single, [
          (20, 100),
          (300, 100),
        ]);
        final reopened = LocalNotebookRepository(repo.directory);
        await reopened.catalog.load();
        expect(reopened.catalog.drawingPreferences.straightStrokes, isTrue);
        live.dispose();
        ink.dispose();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
