import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/editor/navigation.dart';
import 'package:noter/editor/operations.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' as pdf;

class _Viewer extends PdfViewerController {
  PdfViewport position = const PdfViewport(page: 0);
  @override
  PdfViewport captureViewport() => position;
  @override
  Future<void> jumpToPage(int index) async {
    position = PdfViewport(page: index);
  }

  @override
  void restoreViewport(PdfViewport viewport) => position = viewport;
  @override
  void showDestination(pdf.PdfDestination destination) {
    position = PdfViewport(page: destination.pageIndex);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repository;
  late DocumentSession session;
  var disposed = false;

  setUp(() async {
    disposed = false;
    directory = await Directory.systemTemp.createTemp('noter-navigation-');
    repository = LocalNotebookRepository(directory);
    final document = pw.Document();
    for (var i = 0; i < 4; i++) {
      document.addPage(pw.Page(build: (_) => pw.Text('Page $i')));
    }
    final bytes = await document.save();
    final note = await repository.create('Skript', bytes);
    session = DocumentSession(
      note,
      bytes,
      repository,
      preferencesStore: PdfMemoryPreferencesStore(),
      autosaveDelay: const Duration(days: 1),
      checkpointInterval: const Duration(days: 1),
    );
    await session.preferences.ready;
  });

  tearDown(() async {
    if (!disposed) session.dispose();
    await repository.flush();
    await directory.delete(recursive: true);
  });

  test('bookmarks persist, transfer, rename and delete with undo', () async {
    final editing = session.editing;
    expect(editing.outline.isEmpty, isTrue);
    expect(editing.addBookmark('  Kapitel 1  ', pageIndex: 2), isTrue);
    expect(session.dirty, isTrue);
    expect(editing.editBookmark([0], title: 'Exam'), isTrue);
    expect(await session.save(), isTrue);
    final reopened = PdfEditingController(
      await repository.load(session.note.id),
      preferences: session.preferences,
    );
    expect(reopened.outline.items.single.title, 'Exam');
    expect(reopened.outline.items.single.destination!.pageIndex, 2);
    reopened.dispose();

    final imported = await repository.importArchive(
      await repository.exportArchive(session.note),
    );
    expect(imported.id, isNot(session.note.id));
    final transferred = pdf.PdfOutline.of(
      pdf.PdfDocument.open(await repository.load(imported.id)),
    );
    expect(transferred.items.single.title, 'Exam');
    expect(transferred.items.single.destination!.pageIndex, 2);
    editing.deleteBookmark([0]);
    expect(editing.outline.isEmpty, isTrue);
    editing.undo();
    expect(editing.outline.items.single.title, 'Exam');
    editing.redo();
    expect(editing.outline.isEmpty, isTrue);
  });

  test(
    'page operations retain original targets; removed targets are unavailable',
    () async {
      final editing = session.editing;
      editing.addBookmark('Original', pageIndex: 2);
      editing.movePage(2, 0);
      expect(editing.outline.items.single.destination!.pageIndex, 0);
      await duplicateNotebookPages(editing, [0]);
      expect(editing.document.pageCount, 5);
      expect(editing.outline.items.length, 1);
      expect(editing.outline.items.single.destination!.pageIndex, 0);
      editing.removePages([0]);
      expect(editing.outline.items.single.destination, isNull);
      editing.undo();
      expect(editing.outline.items.single.destination!.pageIndex, 0);
      editing.undo();
      expect(editing.document.pageCount, 4);
      editing.undo();
      expect(editing.outline.items.single.destination!.pageIndex, 2);
      editing.apply((e) => e.insertBlankPage(at: 0));
      expect(editing.outline.items.single.destination!.pageIndex, 3);
    },
  );

  test(
    'imported outline preserves hierarchy and XYZ destination when renamed',
    () {
      final editing = session.editing;
      editing.apply((e) {
        final parent = e.addOutlineItem('Kapitel', pageIndex: 0);
        e.addOutlineItem(
          'Section',
          parent: parent,
          destination: pdf.PdfExplicitDestination.xyz(
            2,
            left: 12,
            top: 400,
            zoom: 2,
          ),
        );
      });
      editing.editBookmark([0, 0], title: 'Neuer Name');
      final child = editing.outline.items.single.children.single;
      expect(child.title, 'Neuer Name');
      expect(child.destination!.pageIndex, 2);
      expect(child.destination!.fit, 'XYZ');
      expect(child.destination!.params, [12, 400, 2]);
    },
  );

  test(
    'histories are per view, restore zoom/offsets and follow page identity',
    () {
      final left = _Viewer()
        ..position = const PdfViewport(page: 2, top: .3, left: .2, zoom: 2.5);
      final right = _Viewer()
        ..position = const PdfViewport(page: 1, top: .7, zoom: 1.5);
      final a = PaneNavigation(session.editing, left);
      final b = PaneNavigation(session.editing, right);
      a.jumpToPage(0);
      expect(b.canGoBack, isFalse);
      b.showDestination(
        const pdf.PdfDestination(pageIndex: 3, fit: 'Fit', params: []),
      );
      session.editing.movePage(2, 0);
      a.back();
      expect(
        left.position,
        const PdfViewport(page: 0, top: .3, left: .2, zoom: 2.5),
      );
      expect(right.position.page, 3);
      b.back();
      expect(right.position, const PdfViewport(page: 2, top: .7, zoom: 1.5));
      a.jumpToPage(3);
      session.editing.removePages([0]);
      expect(a.canGoBack, isFalse);
      a.back();
      expect(
        left.position.page,
        3,
      ); // No accidental fallback to a different page.
      a.dispose();
      b.dispose();
      left.dispose();
      right.dispose();
    },
  );

  testWidgets(
    'compact overview creates, renames and navigates; back restores real viewport',
    (tester) async {
      final key = GlobalKey<EditorPaneState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorPane(
              key: key,
              session: session,
              active: true,
              split: false,
              onActivate: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pane = key.currentState!;
      pane.viewer.restoreViewport(
        const PdfViewport(page: 1, top: .25, left: .1, zoom: 2),
      );
      await tester.pumpAndSettle();
      final before = pane.viewer.captureViewport()!;
      await tester.tap(find.byTooltip('Bookmarks and table of contents'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This PDF has no table of contents.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Bookmark current page'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Merken',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Merken'), findsOneWidget);
      await tester.tap(find.byTooltip('Bookmark actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Exam',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exam'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to previous position'));
      await tester.pumpAndSettle();
      final after = pane.viewer.captureViewport()!;
      expect(after.page, before.page);
      expect(after.zoom, closeTo(before.zoom, .001));
      expect(after.top, closeTo(before.top, .001));
      expect(after.left, closeTo(before.left, .001));
      await tester.tap(find.byTooltip('Bookmarks and table of contents'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bookmark actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(session.editing.outline.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => session.save());
      await tester.pumpWidget(const SizedBox.shrink());
      // Cancel the autosave timer in the zone in which it was scheduled.
      session.dispose();
      disposed = true;
    },
  );

  testWidgets(
    'two panes share outlines but keep real viewport histories independent',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final left = GlobalKey<EditorPaneState>();
      final right = GlobalKey<EditorPaneState>();
      session.editing.addBookmark('Kapitel', pageIndex: 3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: EditorPane(
                    key: left,
                    session: session,
                    active: true,
                    split: true,
                    onActivate: () {},
                  ),
                ),
                Expanded(
                  child: EditorPane(
                    key: right,
                    session: session,
                    active: false,
                    split: true,
                    onActivate: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      left.currentState!.viewer.restoreViewport(
        const PdfViewport(page: 1, top: .2, zoom: 2),
      );
      right.currentState!.viewer.restoreViewport(
        const PdfViewport(page: 2, top: .3, zoom: 1.5),
      );
      await tester.pumpAndSettle();
      final a = left.currentState!;
      final b = right.currentState!;
      final beforeLeft = a.viewer.captureViewport()!;
      final beforeRight = b.viewer.captureViewport()!;
      a.navigation.showDestination(
        session.editing.outline.items.single.destination!,
      );
      await tester.pumpAndSettle();
      expect(a.navigation.canGoBack, isTrue);
      expect(b.navigation.canGoBack, isFalse);
      expect(b.viewer.captureViewport(), beforeRight);
      a.navigation.back();
      await tester.pumpAndSettle();
      final after = a.viewer.captureViewport()!;
      expect(after.page, beforeLeft.page);
      expect(after.top, closeTo(beforeLeft.top, .001));
      expect(after.zoom, closeTo(beforeLeft.zoom, .001));
      expect(b.viewer.captureViewport(), beforeRight);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => session.save());
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      disposed = true;
    },
  );
}
