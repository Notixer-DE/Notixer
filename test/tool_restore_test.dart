import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/drawing_preferences.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'corrupt optional drawing preferences do not block future writes',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-corrupt-tool-');
      try {
        for (final corrupt in [
          '{broken',
          '{"version":1,"values":{"lastTool":false}}',
        ]) {
          final file = File('${root.path}/options.json');
          await file.writeAsString(corrupt);
          final preferences = DrawingPreferences(file);
          await preferences.load();
          expect(preferences.isLoaded, isTrue);
          expect(preferences.lastTool, isNull);
          expect(preferences.loadWarning, isNotNull);
          expect(await File('${file.path}.invalid').readAsString(), corrupt);
          await preferences.setStraightStrokes(true);
          final reopened = DrawingPreferences(file);
          await reopened.load();
          expect(reopened.straightStrokes, isTrue);
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'close flush includes a tool choice following a queued preset change',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-preset-flush-');
      try {
        final prefs = DrawingPreferences(File('${root.path}/options.json'));
        await prefs.load();
        const choice = DrawingToolChoice('ink', 0xff123456, 3, .8);
        final applying = prefs
            .setPressureSensitive('ink', false)
            .then((_) => prefs.rememberTool(choice));
        await prefs.flush();
        await applying;
        final reopened = DrawingPreferences(prefs.file);
        await reopened.load();
        expect(reopened.lastTool, choice);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  for (final tool in [
    PdfEditTool.highlight,
    PdfEditTool.freeText,
    PdfEditTool.eraser,
    null,
  ]) {
    test(
      'restores tool $tool and its exact active style after restart',
      () async {
        final root = await Directory.systemTemp.createTemp('noter-last-tool-');
        try {
          final repo = LocalNotebookRepository(root);
          final bytes = await createPaper('blank');
          final note = await repo.create('Tool', bytes);
          final session = DocumentSession(
            note,
            bytes,
            repo,
            preferencesStore: PdfMemoryPreferencesStore(),
          );
          await Future.wait([session.ready, session.toolReady]);
          session.eraser.setBaseTool(tool);
          session.preferences
            ..color = const Color(0xff2468b0)
            ..strokeWidth = 7
            ..opacity = .6;
          await session.save();
          await repo.flush();
          session.dispose();
          final reopened = LocalNotebookRepository(root);
          final base = await reopened.load(note.id);
          final restored = DocumentSession(
            note,
            base,
            reopened,
            preferencesStore: PdfMemoryPreferencesStore(),
          );
          await Future.wait([restored.ready, restored.toolReady]);
          expect(restored.editing.tool, tool);
          expect(restored.preferences.color.toARGB32(), 0xff2468b0);
          expect(restored.preferences.strokeWidth, 7);
          expect(restored.preferences.opacity, .6);
          expect(base, orderedEquals(bytes));
          restored.dispose();
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'temporary side-button erasing never replaces the saved basis',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'noter-temporary-tool-',
      );
      try {
        final repo = LocalNotebookRepository(root);
        final bytes = await createPaper('blank');
        final note = await repo.create('Basis', bytes);
        final session = DocumentSession(
          note,
          bytes,
          repo,
          preferencesStore: PdfMemoryPreferencesStore(),
        );
        await Future.wait([session.ready, session.toolReady]);
        session.eraser.setBaseTool(PdfEditTool.highlight);
        session.preferences
          ..color = const Color(0xffffd740)
          ..strokeWidth = 14
          ..opacity = .35;
        final expected = repo.catalog.drawingPreferences.lastTool;
        session.eraser.handle(
          const PointerHoverEvent(
            kind: PointerDeviceKind.stylus,
            buttons: kPrimaryStylusButton,
          ),
          (_) {},
        );
        expect(session.editing.tool, PdfEditTool.eraser);
        await session.save();
        await repo.flush();
        final reopened = DrawingPreferences(
          repo.catalog.drawingPreferences.file,
        );
        await reopened.load();
        expect(reopened.lastTool, expected);
        session.eraser.handle(
          const PointerHoverEvent(kind: PointerDeviceKind.stylus),
          (_) {},
        );
        expect(session.editing.tool, PdfEditTool.highlight);
        session.dispose();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets('pane activation, lasso and learning retain the restored basis', (
    tester,
  ) async {
    final fixture = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'noter-restored-pane-',
      );
      final repo = LocalNotebookRepository(root);
      final bytes = await createPaper('blank');
      final note = await repo.create('Basis', bytes);
      repo.catalog.drawingPreferences.rememberTool(
        const DrawingToolChoice('highlight', 0xffffd740, 14, .35),
      );
      await repo.flush();
      return (root, repo, bytes, note);
    });
    final (root, repo, bytes, note) = fixture!;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorPage(note: note, bytes: bytes, repository: repo),
      ),
    );
    final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
    for (
      var i = 0;
      i < 150 &&
          (!pane.widget.session.toolsReady || pane.pageForPersistence == null);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(pane.editing.tool, PdfEditTool.highlight);
    pane.activateTools();
    expect(pane.editing.tool, PdfEditTool.highlight);
    pane.toggleLasso();
    await tester.pumpAndSettle();
    expect(pane.editing.tool, PdfEditTool.select);
    pane.toggleLasso();
    await tester.pumpAndSettle();
    pane.toggleLearning();
    await tester.pumpAndSettle();
    var closed = false;
    final closing = FileGateway.beforeClose!().then((value) {
      closed = true;
      return value;
    });
    for (var i = 0; i < 150 && !closed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(closed, isTrue);
    expect(await closing, isTrue);
    final reopened = LibraryCatalog(repo.catalog.file);
    await tester.runAsync(reopened.load);
    expect(reopened.drawingPreferences.lastTool!.tool, 'highlight');
    expect(reopened.drawingPreferences.lastTool!.width, 14);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => root.delete(recursive: true));
    expect(tester.takeException(), isNull);
  });
}
