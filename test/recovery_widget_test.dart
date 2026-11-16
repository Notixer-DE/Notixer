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
    note = await repository.create('Vorlesung', await createPaper('lined'));
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
            .text('1 Notiz · Zuletzt geändert zuerst')
            .evaluate()
            .isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Notizaktionen'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Notizaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
      await settleFileIo(
        tester,
        () => find
            .text('0 Notizen · Zuletzt geändert zuerst')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byTooltip('Bibliotheksaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Papierkorb'));
      await settleFileIo(
        tester,
        () => find.text('Vorlesung').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Papierkorbaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pumpAndSettle();
      expect(find.text('Endgültig löschen?'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(find.text('Vorlesung'), findsOneWidget);
      expect(await tester.runAsync(() => repository.recovery()), hasLength(1));
      await tester.tap(find.byTooltip('Papierkorbaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Endgültig löschen'));
      await settleFileIo(
        tester,
        () => find.text('Der Papierkorb ist leer.').evaluate().isNotEmpty,
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
                child: const Text('Historie öffnen'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Historie öffnen'));
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
      await tester.tap(find.text('Als neue Notiz wiederherstellen'));
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
