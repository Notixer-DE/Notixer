import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
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
      'Lecture',
      await createPaper('lined'),
      paper: 'lined',
    );
  });
  tearDown(() => directory.delete(recursive: true));
  testWidgets('a library PDF can be saved directly to a device file', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    final messenger = tester.binding.defaultBinaryMessenger;
    final destination = File('${directory.path}/exported.pdf');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], 'Lecture.pdf');
      return destination.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(NoterApp(repository: repository));
    await settleFileIo(
      tester,
      () => find.byTooltip('Note actions').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save file to device'));
    await settleFileIo(
      tester,
      () => find.text('File saved.').evaluate().isNotEmpty,
    );
    expect(
      await tester.runAsync(() => destination.readAsBytes()),
      await tester.runAsync(
        () async => repository.load((await repository.list()).single.id),
      ),
    );
  });
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
            .text('1 note · Most recently modified first')
            .evaluate()
            .isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Lecture'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Lecture'), findsOneWidget);
      await Scrollable.ensureVisible(tester.element(find.byType(TextField)));
      await tester.enterText(find.byType(TextField), 'unbekannt');
      await tester.pumpAndSettle();
      expect(find.text('No matching notes found.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(Card).first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Note actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Mathsmatics');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settleFileIo(
        tester,
        () => find.text('Mathsmatics').evaluate().isNotEmpty,
      );
      expect(find.text('Mathsmatics'), findsOneWidget);
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
    testWidgets(
      'library cards and actions fit ${scenario.name}',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.runAsync(() async {
          final note = (await repository.list()).single;
          final folder = await repository.catalog.ensureFolder('Studies');
          await repository.save(
            note.copy(
              title: 'Lecture with a very long title spanning multiple lines',
              folderId: folder.id,
              tags: ['Mathsmatics', 'Exam preparation'],
            ),
            await repository.load(note.id),
          );
        });
        await tester.pumpWidget(NoterApp(repository: repository));
        await settleFileIo(
          tester,
          () => find
              .text('1 note · Most recently modified first')
              .evaluate()
              .isNotEmpty,
        );
        expect(find.text('New note'), findsOneWidget);
        expect(find.text('Import file'), findsOneWidget);
        expect(find.byTooltip('Library actions'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(
          Theme.of(tester.element(find.byType(TextField))).colorScheme.primary,
          NoterTheme.accent,
        );
        // Previews remain available in an explicitly chosen grid; the default
        // library now uses compact file rows.
        await tester.tap(find.byTooltip('Grid view'));
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
        expect(find.text('Ruled'), findsOneWidget);
        expect(
          find.text('Studies · #Mathsmatics · #Exam preparation'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Note actions'));
        await tester.pumpAndSettle();
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Folders and tags'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        scenario.name == 'desktop'
            ? TargetPlatform.linux
            : TargetPlatform.android,
      ),
    );
  }

  testWidgets('select mixed notes, move them and trash them together', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (text, pdf, pdfBytes, folder) = (await tester.runAsync(() async {
      final folder = await repository.catalog.ensureFolder('Archive');
      final text = await repository.create(
        'Batch text',
        MarkdownDocument('# Keep this text\n').encode(),
        paper: 'markdown',
      );
      final tagged = await repository.save(
        text.copy(tags: ['Reference']),
        await repository.load(text.id),
      );
      final pdfBytes = await createPaper('blank');
      final pdf = await repository.create('Batch PDF', pdfBytes, paper: 'pdf');
      return (tagged, pdf, pdfBytes, folder);
    }))!;
    await tester.pumpWidget(NoterApp(repository: repository));
    await settleFileIo(
      tester,
      () => find.text('Batch PDF').evaluate().isNotEmpty,
    );

    await tester.longPress(find.text('Batch PDF'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Batch text'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Move selected notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await settleFileIo(
      tester,
      () => find.byTooltip('Select notes').evaluate().isNotEmpty,
    );
    final moved = (await tester.runAsync(repository.list))!;
    expect(
      moved.where((note) => note.folderId == folder.id).map((note) => note.id),
      unorderedEquals([text.id, pdf.id]),
    );
    expect(moved.singleWhere((note) => note.id == text.id).tags, ['Reference']);
    expect(await tester.runAsync(() => repository.load(pdf.id)), pdfBytes);

    await tester.enterText(find.byType(TextField), 'Batch');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Grid view'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all visible notes'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(
      tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
      everyElement(isTrue),
    );
    await tester.tap(find.byTooltip('Move selected notes to trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Move selected notes to trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settleFileIo(
      tester,
      () => find.text('No matching notes found.').evaluate().isNotEmpty,
    );

    final trash = (await tester.runAsync(repository.recovery))!;
    expect(
      trash.map((entry) => entry.note.id),
      unorderedEquals([text.id, pdf.id]),
    );
    expect(await tester.runAsync(repository.list), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'folder and tag filters combine with search',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final note = (await repository.list()).single;
        final folder = await repository.catalog.ensureFolder('Studies');
        await repository.catalog.ensureFolder('Arbeit');
        await repository.save(
          note.copy(folderId: folder.id, tags: ['Mathsmatics']),
          await repository.load(note.id),
        );
      });
      await tester.pumpWidget(NoterApp(repository: repository));
      await settleFileIo(
        tester,
        () => find
            .text('1 note · Most recently modified first')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.text('Studies').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('#Mathsmatics'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Lecture');
      await tester.pumpAndSettle();
      expect(
        find.text('1 note · Most recently modified first'),
        findsOneWidget,
      );
      await tester.tap(find.text('Arbeit').first);
      await tester.pumpAndSettle();
      expect(
        find.text('0 notes · Most recently modified first'),
        findsOneWidget,
      );
      expect(find.text('No matching notes found.'), findsOneWidget);
      final tagFilter = find.widgetWithText(InputChip, '#Mathsmatics');
      expect(tagFilter, findsOneWidget);
      await tester.tap(
        find.descendant(
          of: tagFilter,
          matching: find.byTooltip('Clear tag filter'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tagFilter, findsNothing);
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
        final folder = await repository.catalog.ensureFolder('Studies');
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
            .text('2 notes · Most recently modified first')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Your space for thoughts.'), findsNothing);
      expect(find.byType(SliverGrid), findsNothing);
      await tester.tap(find.byTooltip('Grid view'));
      await tester.pumpAndSettle();
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      await tester.tap(find.byTooltip('Show folders'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Studies'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(
        find.text('1 note · Most recently modified first'),
        findsOneWidget,
      );
      await tester.tap(find.text('PDFs'));
      await tester.pumpAndSettle();
      expect(
        find.text('0 notes · Most recently modified first'),
        findsOneWidget,
      );
      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      expect(
        find.text('2 notes · Most recently modified first'),
        findsOneWidget,
      );
      expect(find.text('Import file'), findsOneWidget);
      await tester.tap(find.byTooltip('Library actions'));
      await tester.pumpAndSettle();
      expect(find.text('Search PDFs'), findsOneWidget);
      expect(find.text('Manage folders'), findsNothing);
      expect(find.text('Quick capture'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
