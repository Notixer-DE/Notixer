import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/learning.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/operations.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/study_page.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect;

Future<void> waitStudyIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (done()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Study operation did not complete.');
}

void main() {
  late Directory root;
  late LocalNotebookRepository repo;
  late DocumentSession session;
  var disposed = false;
  final now = DateTime.utc(2026, 1, 1, 12);

  setUp(() async {
    disposed = false;
    root = await Directory.systemTemp.createTemp('noter-study-ui-');
    repo = LocalNotebookRepository(root);
    final bytes = await createPaper('blank');
    final note = await repo.create('Vorlesung', bytes);
    session = DocumentSession(
      note,
      bytes,
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
      clock: () => now,
      autosaveDelay: const Duration(days: 1),
      checkpointInterval: const Duration(days: 1),
    );
    await session.preferences.ready;
    session.editing.insertPagesFromBytes(await createPaper('blank'));
    addTape(session.editing, 1, const PdfRect(50, 500, 230, 560));
    await session.save();
  });
  tearDown(() async {
    if (!disposed) session.dispose();
    // Each test waits for its I/O before unmounting. Do not await a Future
    // created in the widget's fake-clock zone from this real-clock teardown.
    await root.delete(recursive: true);
  });

  testWidgets(
    'learning controls require reveal and share progress, not reveal state',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final left = GlobalKey<EditorPaneState>();
      final right = GlobalKey<EditorPaneState>();
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
                    showChrome: false,
                    onActivate: () {},
                  ),
                ),
                Expanded(
                  child: EditorPane(
                    key: right,
                    session: session,
                    active: false,
                    split: true,
                    showChrome: false,
                    onActivate: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final id = session.tapes.single.id;
      final leftReview = left.currentState!.beginReview(id);
      final rightReview = right.currentState!.beginReview(id);
      // Page commands animate; advance the fake clock before awaiting them.
      await tester.pumpAndSettle();
      await Future.wait([leftReview, rightReview]);
      await tester.pumpAndSettle();
      final leftPane = find.byKey(left), rightPane = find.byKey(right);
      Finder button(Finder pane, String text) => find.descendant(
        of: pane,
        matching: find.widgetWithText(TextButton, text),
      );
      expect(
        tester.widget<TextButton>(button(leftPane, 'Gewusst')).onPressed,
        isNull,
      );
      await tester.tap(button(leftPane, 'Antwort aufdecken'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextButton>(button(leftPane, 'Gewusst')).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<TextButton>(button(rightPane, 'Gewusst')).onPressed,
        isNull,
      );
      final revision = session.editing.revisionId;
      await tester.tap(button(leftPane, 'Gewusst'));
      await tester.pump();
      await waitStudyIo(tester, () => !session.saving && !session.dirty);
      expect(session.note.learning.schedule(id)!.count, 1);
      expect(session.editing.revisionId, revision);
      expect(
        tester.widget<TextButton>(button(rightPane, 'Gewusst')).onPressed,
        isNull,
      );
      expect(find.textContaining('1 Bewertungen'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      disposed = true;
    },
  );

  testWidgets(
    'due queue opens the exact original note, page and hidden target',
    (tester) async {
      tester.view.physicalSize = const Size(420, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final id = session.tapes.single.id;
      await tester.pumpWidget(
        MaterialApp(
          home: StudyPage(repository: repo, clock: () => now),
        ),
      );
      await waitStudyIo(
        tester,
        () => find.text('Vorlesung · Seite 2').evaluate().isNotEmpty,
      );
      expect(find.textContaining('1 jetzt fällige Aufgaben'), findsOneWidget);
      await tester.tap(find.text('Vorlesung · Seite 2'));
      await waitStudyIo(
        tester,
        () => find.byType(EditorPage).evaluate().isNotEmpty,
      );
      final editor = tester.widget<EditorPage>(find.byType(EditorPage));
      expect(editor.note.id, session.note.id);
      expect(editor.initialPage, 1);
      expect(editor.initialTapeId, id);
      expect(find.text('Antwort aufdecken'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'future and deleted tasks are not due; refresh observes newly due tasks',
    (tester) async {
      await tester.runAsync(
        () => session.rateTape(session.tapes.single.id, ReviewRating.known),
      );
      var clock = now;
      await tester.pumpWidget(
        MaterialApp(
          home: StudyPage(repository: repo, clock: () => clock),
        ),
      );
      await waitStudyIo(
        tester,
        () => find.text('Für jetzt ist alles erledigt.').evaluate().isNotEmpty,
      );
      clock = now.add(const Duration(days: 1));
      await tester.tap(find.byTooltip('Aufgaben neu laden'));
      await waitStudyIo(
        tester,
        () => find.text('Vorlesung · Seite 2').evaluate().isNotEmpty,
      );
      session.editing.selectAnnotation(1, 0);
      session.editing.deleteSelected();
      await tester.runAsync(() => session.save());
      await tester.tap(find.byTooltip('Aufgaben neu laden'));
      await waitStudyIo(
        tester,
        () => find.text('Für jetzt ist alles erledigt.').evaluate().isNotEmpty,
      );
      expect(find.textContaining('0 jetzt fällige Aufgaben'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      disposed = true;
    },
  );
}
