import 'dart:convert';
import 'dart:io';

import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/reading_positions.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:pdf/widgets.dart' as pw;

import 'sync_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  late LocalNotebookRepository repository;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-reading-positions-');
    file = File('${root.path}/.reading-positions.json');
    repository = LocalNotebookRepository(root);
  });
  tearDown(() async {
    FileGateway.beforeClose = null;
    await root.delete(recursive: true);
  });

  test(
    'positions survive restart, preserve other documents and clamp',
    () async {
      final positions = ReadingPositions(file);
      await positions.save({'a': 7, 'b': 2});
      await positions.save({'b': 4});
      final reopened = ReadingPositions(file);
      await reopened.load();
      expect(reopened.pageFor('a', 10), 7);
      expect(reopened.pageFor('b', 10), 4);
      expect(reopened.pageFor('a', 3), 2);
      expect(reopened.pageFor('unknown', 3), 0);
      expect(reopened.pageFor('a', 0), 0);
    },
  );

  test('missing and malformed preferences do not block opening', () async {
    for (final content in [
      '{broken',
      '[]',
      '{"version":2,"pages":{"a":5}}',
      '{"version":1,"pages":{"a":-1,"b":"2","c":3}}',
    ]) {
      await file.writeAsString(content);
      final positions = ReadingPositions(file);
      await positions.load();
      expect(positions.pageFor('a', 10), 0);
      expect(positions.pageFor('b', 10), 0);
      await positions.save({'a': 1});
      expect(jsonDecode(await file.readAsString())['pages']['a'], 1);
    }
  });

  test('queued updates do not lose another document position', () async {
    final positions = ReadingPositions(file);
    await Future.wait([
      positions.save({'a': 1}),
      positions.save({'b': 2}),
      positions.save({'a': 3}),
    ]);
    final reopened = ReadingPositions(file);
    await reopened.load();
    expect(reopened.pageFor('a', 10), 3);
    expect(reopened.pageFor('b', 10), 2);
  });

  Future<Notebook> createPdf(LocalNotebookRepository repository) async {
    final document = pw.Document();
    for (var i = 0; i < 4; i++) {
      document.addPage(pw.Page(build: (_) => pw.Text('Page $i')));
    }
    final bytes = await document.save();
    final note = await repository.create('Reading', bytes);
    return note;
  }

  Future<void> settleIo(
    WidgetTester tester,
    bool Function() ready, {
    bool settle = true,
  }) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (ready()) {
        if (settle) await tester.pumpAndSettle();
        return;
      }
    }
    fail('Reading position did not restore.');
  }

  Future<void> saveBeforeClose(WidgetTester tester) async {
    bool? saved;
    final saving = FileGateway.beforeClose!().then((value) => saved = value);
    await settleIo(tester, () => saved != null);
    await saving;
    expect(saved, true);
  }

  testWidgets(
    'close and restart restore page without changing synced content',
    (tester) async {
      final note = (await tester.runAsync(() => createPdf(repository)))!;
      var bytes = (await tester.runAsync(() => repository.load(note.id)))!;
      final remote = MemoryRemote();
      await tester.runAsync(() => NotebookSync(repository, remote).run());
      final archive = (await tester.runAsync(
        () => File('${root.path}/${note.id}.noter').readAsBytes(),
      ))!;

      Future<EditorPaneState> open({int? initialPage}) async {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: EditorPage(
              note: note,
              bytes: bytes,
              repository: repository,
              initialPage: initialPage,
            ),
          ),
        );
        await settleIo(tester, () {
          final elements = find.byType(EditorPane).evaluate();
          return elements.isNotEmpty &&
              (tester.state<EditorPaneState>(
                    find.byType(EditorPane),
                  )).pageForPersistence !=
                  null;
        });
        return tester.state<EditorPaneState>(find.byType(EditorPane));
      }

      final first = await open();
      first.viewer.restoreViewport(const PdfViewport(page: 2));
      await tester.pumpAndSettle();
      expect(first.viewer.currentPage, 2);
      await saveBeforeClose(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // New repository/catalog instance simulates a process restart.
      repository = (await tester.runAsync(() async {
        final reopened = LocalNotebookRepository(root);
        await reopened.catalog.load();
        return reopened;
      }))!;
      final second = await open();
      expect(second.viewer.currentPage, 2);
      expect(second.widget.session.dirty, false);
      expect(
        await tester.runAsync(
          () => File('${root.path}/${note.id}.noter').readAsBytes(),
        ),
        archive,
      );
      final report = await tester.runAsync(
        () => NotebookSync(repository, remote).run(),
      );
      expect(report!.uploaded, 0);
      await tester.pumpWidget(const SizedBox.shrink());

      // Explicit destinations (including page zero) override the stored page.
      expect((await open(initialPage: 0)).viewer.currentPage, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect((await open(initialPage: 99)).viewer.currentPage, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      // Simulate a replacement/deletion of pages while the editor is closed.
      final shorter = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Only remaining page')));
      bytes = (await tester.runAsync(shorter.save))!;
      await tester.runAsync(() => repository.save(note, bytes));
      expect((await open()).viewer.currentPage, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('split views keep independent pages and active view wins', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final note = (await tester.runAsync(() => createPdf(repository)))!;
    final bytes = (await tester.runAsync(() => repository.load(note.id)))!;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorPage(note: note, bytes: bytes, repository: repository),
      ),
    );
    await settleIo(
      tester,
      () =>
          find.byType(EditorPane).evaluate().isNotEmpty &&
          tester
                  .state<EditorPaneState>(find.byType(EditorPane))
                  .pageForPersistence !=
              null,
    );
    await tester.tap(find.byTooltip('Tools and export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open second view'));
    await settleIo(
      tester,
      () => find.text('Open the same note again').evaluate().isNotEmpty,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Open the same note again'));
    await settleIo(
      tester,
      () =>
          find.byType(EditorPane).evaluate().length == 2 &&
          tester
              .stateList<EditorPaneState>(find.byType(EditorPane))
              .every((p) => p.pageForPersistence != null),
    );
    final panes = tester
        .stateList<EditorPaneState>(find.byType(EditorPane))
        .toList();
    panes[0].viewer.restoreViewport(const PdfViewport(page: 1));
    panes[1].viewer.restoreViewport(const PdfViewport(page: 3));
    await tester.pumpAndSettle();
    expect(panes[0].viewer.currentPage, 1);
    expect(panes[1].viewer.currentPage, 3);
    await saveBeforeClose(tester);
    final reopened = ReadingPositions(file);
    await tester.runAsync(reopened.load);
    expect(reopened.pageFor(note.id, 4), 3);
    panes[0].widget.onActivate();
    await tester.pumpAndSettle();
    await saveBeforeClose(tester);
    final leftActive = ReadingPositions(file);
    await tester.runAsync(leftActive.load);
    expect(leftActive.pageFor(note.id, 4), 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
