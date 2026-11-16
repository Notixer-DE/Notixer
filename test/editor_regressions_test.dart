import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/operations.dart';
import 'package:pdf_document/pdf_document.dart'
    show PdfRect, PdfAnnotationEditing;
import 'package:pdf_cos/pdf_cos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repo;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-regression-');
    repo = LocalNotebookRepository(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'a damaged catalog cannot block opening or saving intact notes',
    () async {
      final bytes = await createPaper('lined');
      final note = await repo.create('Intakt', bytes);
      for (final damaged in [
        '{',
        '{"version":1,"folders":[],"presets":[{}]}',
      ]) {
        await repo.catalog.file.writeAsString(damaged);
        final reopened = LocalNotebookRepository(directory);
        await reopened.catalog.load();
        expect(reopened.catalog.loadWarning, isNotNull);
        expect(
          await File('${reopened.catalog.file.path}.invalid').readAsString(),
          damaged,
        );
        expect((await reopened.list()).single.id, note.id);
        expect(await reopened.load(note.id), bytes);
        await reopened.save(note.copy(title: 'Weiterarbeiten'), bytes);
        await reopened.catalog.ensureFolder('Neu');
        expect(await reopened.load(note.id), bytes);
      }
    },
  );

  test(
    'custom paper color survives archive import, restart and metadata copies',
    () async {
      final bytes = await createPaper('lined', lineColor: 0x123456);
      final note = await repo.create(
        'Farbige Linien',
        bytes,
        paper: 'lined',
        lineColor: 0x123456,
      );
      final reopened = LocalNotebookRepository(directory);
      expect((await reopened.list()).single.lineColor, 0x123456);
      final imported = await reopened.importArchive(
        await repo.exportArchive(note),
      );
      expect(imported.copy(title: 'Kopie').lineColor, 0x123456);
      final legacy = note.toJson()..remove('lineColor');
      expect(Notebook.fromJson(legacy).lineColor, 0xDCE4EC);
    },
  );

  test('paper exports the requested arbitrary RGB line color', () async {
    for (final pattern in ['lined', 'grid']) {
      final document = PdfDocument.open(
        await createPaper(pattern, lineColor: 0x123456),
      );
      final page = document.page(0);
      final ops = ContentStreamParser.parse(
        page.document.cos.decodeStreamData(
          page.document.cos.resolve(page.dict['Contents']) as CosStream,
        ),
      );
      final rgb = ops.firstWhere((op) => op.operator == 'RG').operands;
      double number(CosObject value) => value is CosReal
          ? value.value
          : (value as CosInteger).value.toDouble();
      expect(number(rgb[0]), closeTo(0x12 / 255, .001));
      expect(number(rgb[1]), closeTo(0x34 / 255, .001));
      expect(number(rgb[2]), closeTo(0x56 / 255, .001));
    }
  });

  test(
    'mixed lasso transforms every object about one origin and undoes once',
    () async {
      final bytes = await createPaper('blank');
      final note = await repo.create('Auswahl', bytes);
      final session = DocumentSession(
        note,
        bytes,
        repo,
        preferencesStore: PdfMemoryPreferencesStore(),
      );
      await session.ready;
      await session.toolReady;
      addTearDown(session.dispose);
      final editing = session.editing;
      editing.apply((editor) {
        editor.addSquare(
          0,
          const PdfRect(100, 100, 120, 120),
          fillColor: 0xff0000,
        );
        editor.addSquare(
          0,
          const PdfRect(150, 150, 170, 170),
          fillColor: 0x00ff00,
        );
      });
      session.ink.apply(
        InkEdit(
          add: [
            InkStroke(
              id: 'ink',
              page: inkPageId(editing.document, 0),
              order: 0,
              color: 0xff123456,
              width: 2,
              points: Float32List.fromList([100, 150, .3, 120, 170, .8]),
              startDirection: const Offset(1, 0),
            ),
          ],
        ),
      );
      editing.selectAnnotationSlots([(0, 0), (0, 1)]);
      session.ink.select(['ink']);
      final original = Uint8List.fromList(editing.bytes);
      final oldInk = session.ink.index['ink']!;
      final bounds = oldInk.bounds.expandToInclude(
        const Rect.fromLTRB(100, 100, 170, 170),
      );
      final origin = bounds.center;
      session.transaction(
        () => transformNotebookSelection(
          editing,
          session.ink,
          rotation: math.pi / 2,
        ),
      );
      final annotations = editing.document.page(0).annotations;
      for (var i = 0; i < 2; i++) {
        final oldCenter = Offset(110 + i * 50.0, 110 + i * 50.0);
        final expected =
            origin +
            Offset(-(oldCenter.dy - origin.dy), oldCenter.dx - origin.dx);
        final rect = annotations[i].rect;
        expect(
          (Offset((rect.left + rect.right) / 2, (rect.bottom + rect.top) / 2) -
                  expected)
              .distance,
          lessThan(.01),
        );
      }
      expect(session.ink.index['ink']!.startDirection!.dy, closeTo(1, .001));
      editing.undo();
      expect(editing.bytes, orderedEquals(original));
      expect(session.ink.index['ink']!.points, orderedEquals(oldInk.points));
      editing.redo();
      expect(
        session.ink.index['ink']!.points,
        isNot(orderedEquals(oldInk.points)),
      );
      editing.selectAnnotationSlots([(0, 0), (0, 1)]);
      session.ink.select(['ink']);
      session.transaction(
        () => transformNotebookSelection(editing, session.ink, scale: 2),
      );
      expect(
        editing.document.page(0).annotations[0].rect.width,
        closeTo(40, .01),
      );
      expect(
        editing.document.page(0).annotations[1].rect.width,
        closeTo(40, .01),
      );
      expect(session.ink.index['ink']!.width, 4);
      await session.save();
    },
  );
  test(
    'lasso rotates and scales PDF handwriting, text and images without losing orientation',
    () async {
      final preferences = PdfEditingPreferences(
        store: PdfMemoryPreferencesStore(),
      );
      await preferences.ready;
      final editing = PdfEditingController(
        await createPaper('blank'),
        preferences: preferences,
      );
      final ink = InkController(InkDocument(generation: 'objects'));
      addTearDown(() {
        ink.dispose();
        editing.dispose();
        preferences.dispose();
      });
      editing.addFreeText(0, const PdfRect(100, 100, 180, 130), 'Text');
      final recorder = PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 20, 10),
        Paint()..color = const Color(0xff123456),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(20, 10);
      final data = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      expect(
        editing.placeImage(0, 240, 200, data!.buffer.asUint8List()),
        isTrue,
      );
      editing.addInkStroke(0, [(40, 40), (70, 80)], pressures: [.2, .8]);
      editing.finishInk();
      expect(
        lassoSelect(editing, 0, const [
          Offset(0, 0),
          Offset(600, 0),
          Offset(600, 800),
          Offset(0, 800),
        ]),
        3,
      );
      final original = Uint8List.fromList(editing.bytes);
      transformNotebookSelection(
        editing,
        ink,
        rotation: math.pi / 6,
        scale: 1.5,
      );
      final first = editing.document.page(0).annotations;
      expect(first.map((annotation) => annotation.subtype).toSet(), {
        'FreeText',
        'Stamp',
        'Ink',
      });
      final before = [for (final a in first) a.appearanceQuad!];
      transformNotebookSelection(editing, ink, scale: 2);
      final after = PdfDocument.open(editing.bytes).page(0).annotations;
      for (var i = 0; i < after.length; i++) {
        final q = after[i].appearanceQuad!;
        final a = Offset(
          before[i][1].$1 - before[i][0].$1,
          before[i][1].$2 - before[i][0].$2,
        );
        final b = Offset(q[1].$1 - q[0].$1, q[1].$2 - q[0].$2);
        expect(b.distance / a.distance, closeTo(2, .001));
        expect(math.atan2(b.dy, b.dx), closeTo(math.atan2(a.dy, a.dx), .001));
      }
      editing.undo();
      editing.undo();
      expect(editing.bytes, orderedEquals(original));
    },
  );
}
