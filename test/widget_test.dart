import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/notebook_preview.dart';
import 'package:noter/ui/noter_theme.dart';

Future<void> settleFileIo(WidgetTester tester, bool Function() ready) async {
  // Real file completions need the real event loop between fake-clock frames.
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (ready() &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      // Another asynchronous initialization stage can start on the next frame.
      // Do not enter pumpAndSettle here: its fake-clock loop would starve real
      // file completions while an indeterminate progress indicator is ticking.
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame &&
          ready() &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
    }
  }
  fail('The library did not finish its file operation.');
}

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-ui-');
    repository = LocalNotebookRepository(directory);
    await repository.create(
      'Vorlesung',
      await createPaper('lined'),
      paper: 'lined',
    );
  });
  tearDown(() => directory.delete(recursive: true));
  testWidgets(
    'library creates, finds and renames a local note on a small display',
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
        find.text('Vorlesung'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Vorlesung'), findsOneWidget);
      await Scrollable.ensureVisible(tester.element(find.byType(TextField)));
      await tester.enterText(find.byType(TextField), 'unbekannt');
      await tester.pumpAndSettle();
      expect(find.text('Keine passende Notiz gefunden.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(Card).first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Notizaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Umbenennen'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Mathematik');
      await tester.pump();
      await tester.tap(find.text('Speichern'));
      await settleFileIo(
        tester,
        () => find.text('Mathematik').evaluate().isNotEmpty,
      );
      expect(find.text('Mathematik'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final scenario in [
    (name: 'phone', size: const Size(375, 812), scale: 1.0),
    (name: 'landscape', size: const Size(812, 375), scale: 1.0),
    (name: 'tablet', size: const Size(800, 1000), scale: 1.0),
    (name: 'desktop', size: const Size(1100, 800), scale: 1.0),
    (name: 'large text', size: const Size(375, 812), scale: 2.0),
  ]) {
    testWidgets('library cards and actions fit ${scenario.name}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.runAsync(() async {
        final note = (await repository.list()).single;
        final folder = await repository.catalog.ensureFolder('Studium');
        await repository.save(
          note.copy(
            title: 'Vorlesung mit einem sehr langen Titel für mehrere Zeilen',
            folderId: folder.id,
            tags: ['Mathematik', 'Prüfungsvorbereitung'],
          ),
          await repository.load(note.id),
        );
      });
      await tester.pumpWidget(NoterApp(repository: repository));
      await settleFileIo(
        tester,
        () => find
            .text('1 Notiz · Zuletzt geändert zuerst')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        scenario.size.width < 600
            ? find.byTooltip('Neue Notiz')
            : find.text('Neue Notiz'),
        findsOneWidget,
      );
      expect(
        scenario.size.width < 600
            ? find.byTooltip('Bibliotheksaktionen')
            : find.text('Datei importieren'),
        findsOneWidget,
      );
      expect(
        Theme.of(tester.element(find.byType(TextField))).colorScheme.primary,
        NoterTheme.accent,
      );
      // Previews remain available in an explicitly chosen grid; the default
      // library now uses compact file rows.
      if (scenario.size.width < 600) {
        await tester.tap(find.byTooltip('Bibliotheksaktionen'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rasteransicht'));
      } else {
        await tester.tap(find.byTooltip('Rasteransicht'));
      }
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(NotebookPreview),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byType(Card).first),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      expect(find.text('Liniert'), findsOneWidget);
      expect(
        find.text('Studium · #Mathematik · #Prüfungsvorbereitung'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Notizaktionen'));
      await tester.pumpAndSettle();
      expect(find.text('Umbenennen'), findsOneWidget);
      expect(find.text('Ordner und Tags'), findsOneWidget);
      expect(find.text('Löschen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'folder and tag filters combine with search',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final note = (await repository.list()).single;
        final folder = await repository.catalog.ensureFolder('Studium');
        await repository.catalog.ensureFolder('Arbeit');
        await repository.save(
          note.copy(folderId: folder.id, tags: ['Mathematik']),
          await repository.load(note.id),
        );
      });
      await tester.pumpWidget(NoterApp(repository: repository));
      await settleFileIo(
        tester,
        () => find
            .text('1 Notiz · Zuletzt geändert zuerst')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.text('Studium').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('#Mathematik'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Vorlesung');
      await tester.pumpAndSettle();
      expect(find.text('1 Notiz · Zuletzt geändert zuerst'), findsOneWidget);
      await tester.tap(find.text('Arbeit').first);
      await tester.pumpAndSettle();
      expect(find.text('0 Notizen · Zuletzt geändert zuerst'), findsOneWidget);
      expect(find.text('Keine passende Notiz gefunden.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'phone offers an explicit two-column grid and drawer filters combine with PDF type',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final note = (await repository.list()).single;
        final folder = await repository.catalog.ensureFolder('Studium');
        await repository.save(
          note.copy(folderId: folder.id),
          await repository.load(note.id),
        );
        await repository.create('PDF-Unterlagen', await createPaper('blank'));
      });
      await tester.pumpWidget(NoterApp(repository: repository));
      await settleFileIo(
        tester,
        () => find
            .text('2 Notizen · Zuletzt geändert zuerst')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Dein Platz für Gedanken.'), findsNothing);
      expect(find.byType(SliverGrid), findsNothing);
      await tester.tap(find.byTooltip('Bibliotheksaktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rasteransicht'));
      await tester.pumpAndSettle();
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      await tester.tap(find.byType(NavigationDestination).at(1));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Studium'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.text('1 Notiz · Zuletzt geändert zuerst'), findsOneWidget);
      await tester.tap(find.text('PDFs'));
      await tester.pumpAndSettle();
      expect(find.text('0 Notizen · Zuletzt geändert zuerst'), findsOneWidget);
      await tester.tap(find.text('Filter zurücksetzen'));
      await tester.pumpAndSettle();
      expect(find.text('2 Notizen · Zuletzt geändert zuerst'), findsOneWidget);
      await tester.tap(find.byTooltip('Bibliotheksaktionen'));
      await tester.pumpAndSettle();
      expect(find.text('Datei importieren'), findsOneWidget);
      expect(find.text('In PDFs suchen'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
