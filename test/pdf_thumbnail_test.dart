import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/ink_layer.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/page_manager.dart';
import 'package:noter/ui/pdf_thumbnail.dart';
import 'package:noter/ui/notebook_preview.dart';
import 'package:noter/ui/template_library.dart';
import 'package:pdf/pdf.dart' show PdfColor, PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfDocument document;
  late InkController ink;
  late InkPathCache cache;
  late Uint8List bytes;
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook note;
  const colors = [0xff229944, 0xff2255bb, 0xffcc6622];
  List<int> rgb(int page) => [
    (colors[page % colors.length] >> 16) & 255,
    (colors[page % colors.length] >> 8) & 255,
    colors[page % colors.length] & 255,
  ];
  setUp(() async {
    final pdf = pw.Document();
    for (var i = 0; i < 12; i++) {
      pdf.addPage(
        pw.Page(
          pageFormat: i.isEven ? PdfPageFormat.a4 : PdfPageFormat.a4.landscape,
          margin: pw.EdgeInsets.zero,
          build: (_) =>
              pw.Container(color: PdfColor.fromInt(colors[i % colors.length])),
        ),
      );
    }
    bytes = await pdf.save();
    document = PdfDocument.open(bytes);
    ink = InkController(InkDocument(generation: 'thumbnail'));
    cache = InkPathCache();
    directory = await Directory.systemTemp.createTemp('noter-thumbnail-');
    repository = LocalNotebookRepository(directory);
    note = await repository.create('Preview', bytes);
  });
  tearDown(() async {
    ink.dispose();
    cache.clear();
    await directory.delete(recursive: true);
  });

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<List<int>> pixel(WidgetTester tester, String key, {Offset? at}) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(ValueKey(key)),
    );
    final result = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final point = at == null
          ? Offset(image.width / 2, image.height / 2)
          : boundary.globalToLocal(at);
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      final color = List<int>.generate(3, (i) => data!.getUint8(offset + i));
      image.dispose();
      return color;
    });
    return result!;
  }

  testWidgets(
    'cached offscreen thumbnails render on entry without rebuilding their parent',
    (tester) async {
      final scroll = ScrollController();
      final builds = <int, int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: scroll,
              scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
              itemExtent: 120,
              itemCount: document.pageCount,
              itemBuilder: (context, index) {
                builds.update(index, (count) => count + 1, ifAbsent: () => 1);
                return Center(
                  child: RepaintBoundary(
                    key: ValueKey('thumbnail-$index'),
                    child: SizedBox(
                      width: 72,
                      height: 100,
                      child: InkPagePreview(
                        page: document.page(index),
                        pageId: inkPageId(document, index),
                        controller: ink,
                        cache: cache,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await frames(tester);
      expect(await pixel(tester, 'thumbnail-0'), rgb(0));
      expect(
        builds[8],
        1,
        reason: 'The future visible page is already cached.',
      );
      scroll.jumpTo(840);
      await frames(tester);
      expect(builds[8], 1, reason: 'Entering must not need a parent rebuild.');
      expect(await pixel(tester, 'thumbnail-8'), rgb(8));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'page manager paints immediately and refreshes after page operations',
    (tester) async {
      final session = await tester.runAsync(() async {
        final value = DocumentSession(
          note,
          bytes,
          repository,
          preferencesStore: PdfMemoryPreferencesStore(),
          autosaveDelay: const Duration(days: 1),
          checkpointInterval: const Duration(days: 1),
        );
        await Future.wait([value.ready, value.toolReady]);
        return value;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('manager'),
              child: PageManager(
                session: session!,
                currentPage: 0,
                onPage: (_) {},
                onCopyTo: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      Future<void> expectPage(int slot, int original) async {
        final thumbnail = find.byType(PdfThumbnail).at(slot);
        expect(
          await pixel(tester, 'manager', at: tester.getCenter(thumbnail)),
          rgb(original),
        );
        final size = tester.getSize(thumbnail);
        final page = session.editing.document.page(slot);
        final ratio = page.rotation % 180 == 0
            ? page.cropBox.width / page.cropBox.height
            : page.cropBox.height / page.cropBox.width;
        expect(size.width / size.height, closeTo(ratio, .001));
      }

      // No checkbox toggle or other rebuild is allowed to make these pass.
      await expectPage(0, 0);
      await expectPage(1, 1);
      final first = tester.state(find.byType(PdfThumbnail).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(tester.state(find.byType(PdfThumbnail).first), same(first));
      session.editing.movePage(0, 1);
      await frames(tester);
      await expectPage(0, 1);
      await expectPage(1, 0);
      session.editing.insertPagesFromBytes(document.extractPages([2]), at: 0);
      await frames(tester);
      await expectPage(0, 2);
      session.editing.removePages([0]);
      await frames(tester);
      await expectPage(0, 1);
      session.editing.apply((editor) => editor.rotatePage(0, 90));
      await frames(tester);
      await expectPage(0, 1);
      // The same page object keeps its thumbnail State across reordering.
      expect(tester.state(find.byType(PdfThumbnail).at(1)), same(first));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.byTooltip('Duplicate pages'));
      await frames(tester);
      await expectPage(0, 1);
      await expectPage(1, 1);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ReorderableListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(360);
      await frames(tester);
      final entered = find.byWidgetPredicate(
        (widget) =>
            widget is PdfThumbnail &&
            session.editing.document.pageIndexOf(widget.page.dict) == 4,
      );
      expect(
        await pixel(tester, 'manager', at: tester.getCenter(entered)),
        rgb(3),
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'a route entering from below renders without any user interaction',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      navigator.currentState!.push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) => Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('route-thumbnail'),
                child: SizedBox(
                  width: 72,
                  height: 100,
                  child: PdfThumbnail(page: document.page(0)),
                ),
              ),
            ),
          ),
          transitionsBuilder: (_, animation, _, child) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 2),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
      );
      await frames(tester);
      expect(await pixel(tester, 'route-thumbnail'), rgb(0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notebook and template previews paint on their first appearance',
    (tester) async {
      final previews = NotebookPreviewCache(repository);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('notebook'),
              child: NotebookPreview(note: note, cache: previews),
            ),
          ),
        ),
      );
      // The document extraction runs on a storage isolate.
      for (
        var i = 0;
        i < 150 && find.byType(PdfThumbnail).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await frames(tester);
      expect(find.byType(PdfThumbnail), findsOneWidget);
      expect(
        await pixel(
          tester,
          'notebook',
          at: tester.getCenter(find.byType(PdfThumbnail)),
        ),
        rgb(0),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('template'),
              child: TemplatePreview(name: 'Vorlage', bytes: bytes),
            ),
          ),
        ),
      );
      await frames(tester);
      expect(
        await pixel(
          tester,
          'template',
          at: tester.getCenter(find.byType(PdfThumbnail)),
        ),
        rgb(0),
      );
      await tester.tap(find.byTooltip('Next template page'));
      await frames(tester);
      expect(
        await pixel(
          tester,
          'template',
          at: tester.getCenter(find.byType(PdfThumbnail)),
        ),
        rgb(1),
      );
      final size = tester.getSize(find.byType(PdfThumbnail));
      expect(
        size.width / size.height,
        closeTo(
          PdfPageFormat.a4.landscape.width / PdfPageFormat.a4.landscape.height,
          .001,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      previews.dispose();
    },
  );

  testWidgets(
    'editor sidebar and writing loupe show their PDF content immediately',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('editor'),
            child: EditorPage(note: note, bytes: bytes, repository: repository),
          ),
        ),
      );
      await frames(tester);
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      final sidebarThumbnail = find
          .descendant(
            of: find.byKey(const ValueKey('editor-page-sidebar')),
            matching: find.byType(PdfThumbnail),
          )
          .first;
      expect(
        await pixel(tester, 'editor', at: tester.getCenter(sidebarThumbnail)),
        rgb(0),
      );
      pane.toggleLoupe();
      await frames(tester);
      // The overview precedes the PDF canvas/sidebar in the pane.
      final loupeThumbnail = find.byType(PdfThumbnail).first;
      expect(
        await pixel(tester, 'editor', at: tester.getCenter(loupeThumbnail)),
        rgb(0),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );
}
