import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/learning.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/pdf_search.dart';
import 'package:noter/data/templates.dart';
import 'package:noter/data/tapes.dart' show findTapes;
import 'package:noter/editor/operations.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' as pdf;

Future<Uint8List> templateFixture() async {
  final document = pw.Document(
    title: 'Private source title',
    author: 'Private author',
  );
  for (var i = 0; i < 3; i++) {
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(420 + i * 30, 600 + i * 20),
        build: (_) => pw.Container(
          color: PdfColors.yellow100,
          child: pw.Text('PAGE_$i', style: const pw.TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
  final preferences = PdfEditingPreferences(store: PdfMemoryPreferencesStore());
  await preferences.ready;
  final editing = PdfEditingController(
    await document.save(),
    preferences: preferences,
  );
  try {
    editing.addInkStroke(0, [(50, 50), (100, 100)], pressures: [.2, .9]);
    editing.finishInk();
    editing.addFreeText(
      0,
      const pdf.PdfRect(40, 150, 180, 200),
      'Editable template text',
    );
    addTape(editing, 0, const pdf.PdfRect(50, 220, 180, 260));
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 20, 10),
      Paint()..color = const Color(0xFF24AABB),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(20, 10);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(editing.placeImage(0, 200, 300, png!.buffer.asUint8List()), isTrue);
    image.dispose();
    picture.dispose();
    editing.apply((editor) => editor.rotatePage(1, 90));
    editing.addBookmark('Source-only chapter', pageIndex: 1);
    return Uint8List.fromList(editing.bytes);
  } finally {
    editing.dispose();
    preferences.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalNotebookRepository repository;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-templates-');
    repository = LocalNotebookRepository(root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'page and notebook templates persist offline and retain page order, geometry and contents',
    () async {
      final bytes = await templateFixture();
      final source = pdf.PdfDocument.open(bytes);
      final all = await repository.templates.save('Lesson', bytes);
      final page = await repository.templates.save('Landscape', bytes, page: 1);
      final reopened = TemplateRepository(Directory('${root.path}/.templates'));
      expect(
        (await reopened.list()).where((t) => !t.builtIn).map((t) => t.name),
        ['Landscape', 'Lesson'],
      );
      expect(all.kind, TemplateKind.notebook);
      expect(all.pageCount, 3);
      expect(page.kind, TemplateKind.page);
      final copied = await reopened.instantiate(all.id);
      final copy = pdf.PdfDocument.open(copied);
      for (var index = 0; index < 3; index++) {
        expect(copy.page(index).mediaBox, source.page(index).mediaBox);
        expect(copy.page(index).cropBox, source.page(index).cropBox);
        expect(copy.page(index).rotation, source.page(index).rotation);
        expect(
          copy.page(index).contentBytes(),
          source.page(index).contentBytes(),
          reason:
              'Keep searchable text and vector backgrounds, not a raster screenshot',
        );
        expect(
          (await searchPdf(copied, 'PAGE_$index')).hits.single.pageIndex,
          index,
        );
      }
      final annotations = copy.page(0).annotations;
      expect(annotations.any((a) => a.inkList != null), isTrue);
      expect(annotations.any((a) => a.subtype == 'FreeText'), isTrue);
      expect(annotations.any((a) => a.isImageStamp), isTrue);
      expect(annotations.where(isTape).single.appearanceOpacity, 0);
      expect(copy.info, isEmpty);
      expect(pdf.PdfOutline.of(copy).isEmpty, isTrue);
      final extracted = await reopened.instantiate(page.id);
      final single = pdf.PdfDocument.open(extracted);
      expect(single.pageCount, 1);
      expect(single.page(0).rotation, 90);
      expect((await searchPdf(extracted, 'PAGE_1')).hits.single.pageIndex, 0);
      expect((await searchPdf(extracted, 'PAGE_0')).hits, isEmpty);
    },
  );

  test(
    'new notes and repeated insertions are independent, with new annotation and notebook identities',
    () async {
      final bytes = await templateFixture();
      final folder = await repository.catalog.ensureFolder('Source folder');
      var source = await repository.create('Source title', bytes);
      final sourceTape = findTapes(pdf.PdfDocument.open(bytes)).single;
      source = await repository.save(
        source.copy(
          folderId: folder.id,
          tags: ['source-tag'],
          learning: source.learning.assess(
            sourceTape.id,
            ReviewRating.known,
            id: 'source-review',
            at: DateTime.utc(2026, 11, 11),
          ),
        ),
        bytes,
      );
      expect(source.learning.isEmpty, isFalse);
      final entry = await repository.templates.save(
        'Reusable',
        await repository.load(source.id),
      );
      final savedTemplate = await repository.templates.preview(entry.id);
      final first = await repository.create(
        'First',
        await repository.templates.instantiate(entry.id),
      );
      final second = await repository.create(
        'Second',
        await repository.templates.instantiate(entry.id),
      );
      expect({source.id, first.id, second.id}, hasLength(3));
      expect(first.folderId, isNull);
      expect(first.tags, isEmpty);
      expect(first.title, 'First');
      expect(first.learning.isEmpty, isTrue);
      expect(second.learning.isEmpty, isTrue);
      final a = pdf.PdfDocument.open(await repository.load(first.id));
      final b = pdf.PdfDocument.open(await repository.load(second.id));
      expect(findTapes(a).single.id, isNot(sourceTape.id));
      expect(findTapes(b).single.id, isNot(sourceTape.id));
      expect(findTapes(a).single.id, isNot(findTapes(b).single.id));
      final namesA = a.page(0).annotations.map((a) => a.name).toSet();
      final namesB = b.page(0).annotations.map((a) => a.name).toSet();
      expect(namesA.intersection(namesB), isEmpty);
      expect(namesA.contains(null), isFalse);

      final preferences = PdfEditingPreferences(
        store: PdfMemoryPreferencesStore(),
      );
      await preferences.ready;
      final editing = PdfEditingController(
        await createPaper('blank'),
        preferences: preferences,
      );
      try {
        editing.insertPagesFromBytes(
          await repository.templates.instantiate(entry.id),
          at: 1,
        );
        expect(editing.document.pageCount, 4);
        editing.undo();
        expect(editing.document.pageCount, 1);
        editing.redo();
        expect(editing.document.pageCount, 4);
        editing.insertPagesFromBytes(
          await repository.templates.instantiate(entry.id),
          at: 4,
        );
        final insertedNames = [
          for (final index in [1, 4])
            ...editing.document.page(index).annotations.map((a) => a.name),
        ];
        expect(insertedNames.toSet().length, insertedNames.length);
        final insertedTasks = findTapes(editing.document);
        expect(insertedTasks.map((tape) => tape.id).toSet(), hasLength(2));
        expect(insertedTasks.any((tape) => tape.id == sourceTape.id), isFalse);
        expect(
          (await searchPdf(
            editing.bytes,
            'PAGE_0',
          )).hits.map((h) => h.pageIndex),
          [1, 4],
        );
        editing.addFreeText(
          1,
          const pdf.PdfRect(50, 400, 200, 440),
          'Changed copy',
        );
        await repository.save(first, editing.bytes);
        expect(await repository.templates.preview(entry.id), savedTemplate);
        expect(
          (await searchPdf(
            await repository.load(second.id),
            'Changed copy',
          )).hits,
          isEmpty,
        );
      } finally {
        editing.dispose();
        preferences.dispose();
      }
      await repository.templates.delete(entry.id);
      expect(
        (await repository.list()).map((n) => n.id),
        containsAll([source.id, first.id, second.id]),
      );
      expect(
        await repository.syncIds(),
        containsAll([source.id, first.id, second.id]),
      );
      expect(await repository.syncIds(), hasLength(3));
    },
  );

  test(
    'rename is atomic, failed writes recover, invalid paths/names and corrupt archives are isolated',
    () async {
      final entry = await repository.templates.save(
        'Before',
        await createPaper('grid'),
      );
      final original = await repository.templates.preview(entry.id);
      final obstacle = Directory(
        '${root.path}/.templates/${entry.id}.template.tmp',
      );
      await obstacle.create();
      await expectLater(
        repository.templates.rename(entry.id, 'Failed'),
        throwsA(anything),
      );
      expect((await repository.templates.list()).first.name, 'Before');
      await obstacle.delete();
      await Future.wait([
        repository.templates.rename(entry.id, 'Middle'),
        repository.templates.rename(entry.id, 'After'),
      ]);
      expect((await repository.templates.list()).first.name, 'After');
      expect(await repository.templates.preview(entry.id), original);
      for (final name in ['', '   ', 'x' * 121, 'bad\nname']) {
        expect(
          () => repository.templates.rename(entry.id, name),
          throwsFormatException,
        );
      }
      await expectLater(
        repository.templates.instantiate('../outside'),
        throwsFormatException,
      );
      expect(
        () => repository.templates.delete('starter_cornell'),
        throwsFormatException,
      );
      await expectLater(
        repository.templates.save('Invalid', Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      await expectLater(
        repository.templates.save(
          'Invalid page',
          await createPaper('blank'),
          page: 5,
        ),
        throwsRangeError,
      );
      final malformed = File('${root.path}/.templates/broken.template');
      await malformed.writeAsString('not a ZIP');
      final items = await repository.templates.list();
      expect(items.any((t) => t.id == entry.id), isTrue);
      expect(repository.templates.readErrors, ['broken.template']);

      final file = File('${root.path}/.templates/${entry.id}.template');
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final manifest =
          jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
              as Map<String, dynamic>;
      expect(manifest.keys.toSet(), {'version', 'id', 'name', 'kind', 'pages'});
    },
  );

  test(
    'saving freezes caller bytes and repository flush waits for template writes',
    () async {
      final bytes = await createPaper('lined');
      final saved = repository.templates.save('Snapshot', bytes);
      bytes.fillRange(0, bytes.length, 0);
      await repository.flush();
      final reopened = TemplateRepository(Directory('${root.path}/.templates'));
      final entry = (await reopened.list()).singleWhere((t) => !t.builtIn);
      expect(entry.id, (await saved).id);
      expect(
        pdf.PdfDocument.open(await reopened.instantiate(entry.id)).pageCount,
        1,
      );
    },
  );

  test(
    'all three offline starter layouts generate real, searchable pages',
    () async {
      expect((await repository.templates.list()).length, 3);
      for (final entry in starterTemplates) {
        final bytes = await repository.templates.instantiate(entry.id);
        expect(pdf.PdfDocument.open(bytes).pageCount, 1);
        expect((await searchPdf(bytes, entry.name)).hits, isNotEmpty);
      }
    },
  );
}
