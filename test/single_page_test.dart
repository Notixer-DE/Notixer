import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/editor/navigation.dart';
import 'package:noter/ui/single_page_view.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfEditingController editing;
  late NavigationViewerController viewer;
  final captureKey = GlobalKey();

  setUp(() async {
    final doc = pw.Document();
    for (final size in [
      PdfPageFormat.a4,
      PdfPageFormat.a4.landscape,
      const PdfPageFormat(300, 1600),
    ]) {
      doc.addPage(
        pw.Page(
          pageFormat: size,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Container(color: const PdfColor.fromInt(0xffff0000)),
        ),
      );
    }
    editing = PdfEditingController(
      await doc.save(),
      preferences: PdfEditingPreferences(store: PdfMemoryPreferencesStore()),
    );
    viewer = NavigationViewerController();
  });

  tearDown(() {
    viewer.dispose();
    editing.preferences.dispose();
    editing.dispose();
  });

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: SinglePageView(
              viewer: viewer,
              editing: editing,
              background: Colors.grey,
              canSwipe: () => true,
              child: PdfViewer(
                editing: editing,
                controller: viewer,
                minZoom: .001,
                autoRenderWorker: false,
              ),
            ),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  void expectFit(WidgetTester tester, int page) {
    expect(viewer.currentPage, page);
    final viewport = tester.getRect(find.byType(SinglePageView));
    final rect = viewer.globalRectOf(
      page,
      editing.document.page(page).cropBox,
    )!;
    expect(rect.width, lessThanOrEqualTo(viewport.width + 1));
    expect(rect.height, lessThanOrEqualTo(viewport.height + 1));
    expect((rect.center - viewport.center).distance, lessThan(1));
  }

  testWidgets('fits mixed page sizes and swipes without changing the PDF', (
    tester,
  ) async {
    final bytes = editing.bytes.toList();
    await mount(tester);
    expectFit(tester, 0);
    expect(viewer.captureViewport()!.page, 0);
    await tester.drag(find.byType(SinglePageView), const Offset(-180, 0));
    await frames(tester);
    expectFit(tester, 1);
    expect(viewer.captureViewport()!.page, 1);
    viewer.jumpToPage(2);
    await frames(tester);
    expectFit(tester, 2);
    await tester.drag(find.byType(SinglePageView), const Offset(180, 0));
    await frames(tester);
    expectFit(tester, 1);
    expect(editing.bytes, orderedEquals(bytes));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('zoomed panning and multi-touch never turn a page', (
    tester,
  ) async {
    await mount(tester);
    final fittedZoom = viewer.zoom;
    viewer.setZoom(fittedZoom * 2);
    await frames(tester);
    expect(viewer.zoom, closeTo(fittedZoom * 2, .01));
    await tester.drag(find.byType(SinglePageView), const Offset(-180, -70));
    await frames(tester);
    expect(viewer.currentPage, 0);
    expect(viewer.zoom, closeTo(fittedZoom * 2, .01));
    final viewport = tester.getRect(find.byType(SinglePageView));
    final rect = viewer.globalRectOf(0, editing.document.page(0).cropBox)!;
    if (rect.width > viewport.width) {
      expect(rect.left, lessThanOrEqualTo(viewport.left + 1));
      expect(rect.right, greaterThanOrEqualTo(viewport.right - 1));
    } else {
      expect((rect.center.dx - viewport.center.dx).abs(), lessThan(1));
    }
    viewer.jumpToPage(1);
    await frames(tester);
    final first = await tester.startGesture(
      const Offset(350, 250),
      pointer: 10,
    );
    final second = await tester.startGesture(
      const Offset(450, 350),
      pointer: 11,
    );
    final beforePinch = viewer.zoom;
    await first.moveBy(const Offset(-100, 0));
    await second.moveBy(const Offset(100, 0));
    await tester.pump();
    await second.up();
    await first.up();
    await frames(tester);
    expect(viewer.currentPage, 1);
    expect(viewer.zoom, greaterThan(beforePinch));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restores the selected page and refits after viewport resizing', (
    tester,
  ) async {
    await mount(tester);
    viewer.jumpToPage(1);
    await frames(tester);
    viewer.setZoom(viewer.zoom * 1.8);
    await frames(tester);
    final position = viewer.captureViewport()!;
    final zoom = viewer.zoom;
    expect(position.page, 1);
    viewer.jumpToPage(2);
    await frames(tester);
    viewer.restoreViewport(position);
    await frames(tester);
    expect(viewer.currentPage, 1);
    expect(viewer.zoom, closeTo(zoom, .01));
    await tester.binding.setSurfaceSize(const Size(420, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await frames(tester);
    expectFit(tester, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'tall PDF stays painted while panning to both vertical edges at zoom',
    (tester) async {
      await mount(tester);
      viewer.jumpToPage(2);
      await frames(tester);
      Future<void> expectPainted() async {
        final viewport = tester.getRect(find.byType(SinglePageView));
        final page = viewer.globalRectOf(2, editing.document.page(2).cropBox)!;
        final expected = page.intersect(viewport).deflate(24);
        expect(expected.isEmpty, isFalse);
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final pixels = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final width = image.width;
          image.dispose();
          return (bytes!, width);
        }))!;
        for (final point in [
          expected.topLeft,
          expected.topRight,
          expected.center,
          expected.bottomLeft,
          expected.bottomRight,
        ]) {
          final local = point - viewport.topLeft;
          final offset = (local.dy.floor() * pixels.$2 + local.dx.floor()) * 4;
          expect(
            pixels.$1.getUint8(offset),
            greaterThan(245),
            reason: 'PDF red channel at $point, page=$page, viewport=$viewport',
          );
          expect(
            pixels.$1.getUint8(offset + 1),
            lessThan(10),
            reason: 'PDF was clipped at $point',
          );
        }
      }

      viewer.setZoom(viewer.zoom * 8);
      await tester.pump();
      await expectPainted();
      await frames(tester);
      for (final dy in [-600.0, -1200.0, 1800.0]) {
        await tester.drag(find.byType(SinglePageView), Offset(0, dy));
        await frames(tester);
        expect(viewer.currentPage, 2);
        await expectPainted();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
