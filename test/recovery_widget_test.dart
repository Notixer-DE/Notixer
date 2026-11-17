import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/recovery_page.dart';
import 'widget_test.dart' show settleFileIo;

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook note;
  setUp(() async {
    PdfViewer.debugAutoRenderWorkerEnabled = false;
    directory = await Directory.systemTemp.createTemp('noter-recovery-ui-');
    repository = LocalNotebookRepository(directory);
    note = await repository.create('Lecture', await createPaper('lined'));
  });
  tearDown(() async {
    PdfViewer.debugAutoRenderWorkerEnabled = true;
    await directory.delete(recursive: true);
  });

  testWidgets(
    'library exposes trash, permanent deletion requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoterApp(repository: repository));
      await settleFileIo(
        tester,
        () => find
            .text('1 note · Most recently modified first')
            .evaluate()
            .isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Note actions'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Note actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settleFileIo(
        tester,
        () => find
            .text('0 notes · Most recently modified first')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byTooltip('Library actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trash'));
      await settleFileIo(
        tester,
        () => find.text('Lecture').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Trash actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Delete permanently?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Lecture'), findsOneWidget);
      expect(await tester.runAsync(() => repository.recovery()), hasLength(1));
      await tester.tap(find.byTooltip('Trash actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
      await settleFileIo(
        tester,
        () => find.text('The trash is empty.').evaluate().isNotEmpty,
      );
      expect(await tester.runAsync(() => repository.recovery()), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history preview is read-only and restore returns an independent copy',
    (tester) async {
      final original = await tester.runAsync(() => repository.load(note.id));
      await tester.runAsync(() async {
        await repository.save(
          note.copy(title: 'Aktuell'),
          await createPaper('grid', pages: 2),
        );
      });
      Notebook? restored;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [DartPdfEditorLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  restored = await Navigator.of(context).push<Notebook>(
                    MaterialPageRoute(
                      builder: (_) =>
                          RecoveryPage(repository: repository, note: note),
                    ),
                  );
                },
                child: const Text('Open history'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open history'));
      await settleFileIo(
        tester,
        () => find.byType(ListTile).evaluate().isNotEmpty,
      );
      await tester.tap(find.byType(ListTile));
      await settleFileIo(
        tester,
        () => find.byType(PdfViewer).evaluate().isNotEmpty,
      );
      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      expect(viewer.editing, isNull);
      expect(viewer.interactiveForms, isFalse);
      expect(viewer.contextMenuEnabled, isFalse);
      await tester.tap(find.text('Restore as a new note'));
      await settleFileIo(tester, () => restored != null);
      expect(restored!.id, isNot(note.id));
      expect(
        await tester.runAsync(() => repository.load(restored!.id)),
        original,
      );
      expect(
        (await tester.runAsync(
          () => repository.list(),
        ))!.firstWhere((n) => n.id == note.id).title,
        'Aktuell',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
