import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/pdf_search.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/pdf_search_page.dart';
import 'package:pdf/widgets.dart' as pw;

import 'widget_test.dart' show settleFileIo;

Future<Uint8List> textPdf(List<String> pages) async {
  final document = pw.Document();
  for (final text in pages) {
    document.addPage(pw.Page(build: (_) => pw.Text(text)));
  }
  return document.save();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'searches actual PDF text across pages, case-insensitively and literally',
    () async {
      final bytes = await textPdf([
        'Algebra und ALGEBRA',
        'Andere Inhalte',
        'Noch Algebra und a.b',
      ]);
      final result = await searchPdf(bytes, ' algebra ');
      expect(result.hits.map((h) => h.pageIndex), [0, 0, 2]);
      expect(result.hits.first.snippet, contains('Algebra'));
      expect(result.truncated, isFalse);
      expect((await searchPdf(bytes, 'a.b')).hits.length, 1);
      expect((await searchPdf(bytes, 'fehlend')).hits, isEmpty);
      expect((await searchPdf(bytes, '  ')).hits, isEmpty);
    },
  );

  test(
    'bounds results and distinguishes exact limit from truncation',
    () async {
      final bytes = await textPdf(['Wort Wort Wort']);
      final capped = await searchPdf(bytes, 'Wort', limit: 2);
      expect(capped.hits.length, 2);
      expect(capped.truncated, isTrue);
      expect((await searchPdf(bytes, 'Wort', limit: 3)).truncated, isFalse);
    },
  );

  test('rejects unreadable documents', () async {
    await expectLater(
      searchPdf(Uint8List.fromList([1, 2, 3]), 'Wort'),
      throwsA(anything),
    );
  });

  testWidgets('searches only selected documents and opens the matching page', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('noter-search-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    late LocalNotebookRepository repository;
    late Notebook first, second, excluded;
    await tester.runAsync(() async {
      repository = LocalNotebookRepository(directory);
      first = await repository.create(
        'Erstes PDF',
        await textPdf(['Andere Seite', 'Algebra']),
      );
      second = await repository.create(
        'Zweites PDF',
        await textPdf(['Algebra']),
      );
      excluded = await repository.create(
        'Nicht ausgewählt',
        await textPdf(['Algebra']),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PdfSearchPage(
          notes: [first, second, excluded],
          repository: repository,
        ),
      ),
    );
    await tester.tap(find.text('Erstes PDF'));
    await tester.tap(find.text('Zweites PDF'));
    await tester.enterText(find.byType(TextField), 'algebra');
    await tester.pump();
    await tester.tap(find.text('In 2 Dokumenten suchen'));
    await settleFileIo(
      tester,
      () => find.text('Zweites PDF · Seite 1').evaluate().isNotEmpty,
    );
    expect(find.text('Erstes PDF · Seite 2'), findsOneWidget);
    expect(find.text('Nicht ausgewählt · Seite 1'), findsNothing);
    await tester.tap(find.text('Erstes PDF · Seite 2'));
    await settleFileIo(
      tester,
      () => find.byType(EditorPage).evaluate().isNotEmpty,
    );
    final editor = tester.widget<EditorPage>(find.byType(EditorPage));
    expect(editor.initialPage, 1);
    expect(editor.initialQuery, 'algebra');
    expect(find.byTooltip('Suche schließen'), findsOneWidget);
    final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
    expect(pane.viewer.currentPage, 1);
    expect(pane.viewer.matchCount, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'continues after an unreadable selected document on a small display',
    (tester) async {
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory directory;
      late LocalNotebookRepository repository;
      late Notebook broken, valid;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'noter-search-errors-',
        );
        repository = LocalNotebookRepository(directory);
        broken = await repository.create('Fehlt', await textPdf(['Algebra']));
        valid = await repository.create('Lesbar', await textPdf(['Algebra']));
        await File('${directory.path}/${broken.id}.noter').delete();
      });
      addTearDown(() => directory.delete(recursive: true));
      await tester.pumpWidget(
        MaterialApp(
          home: PdfSearchPage(notes: [broken, valid], repository: repository),
        ),
      );
      await tester.tap(find.text('Alle auswählen'));
      await tester.enterText(find.byType(TextField), 'algebra');
      await tester.pump();
      await tester.tap(find.text('In 2 Dokumenten suchen'));
      await settleFileIo(
        tester,
        () => find.text('Lesbar · Seite 1').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Suche fehlgeschlagen'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Auswahl ändern'));
      await tester.pump();
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == true),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
