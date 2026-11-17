import 'dart:io';
import 'dart:ui' show Color;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/editor/ink_gestures.dart';
import 'package:noter/editor/pdf_stroke_eraser.dart';
import 'package:noter/ui/editor_toolbar.dart';
import 'package:noter/ui/ink_layer.dart';

void main() {
  late Directory root;
  late LocalNotebookRepository repo;
  late DocumentSession session;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noter-stroke-eraser-');
    repo = LocalNotebookRepository(root);
    final bytes = await createPaper('blank');
    final note = await repo.create('Striche', bytes);
    session = DocumentSession(
      note,
      bytes,
      repo,
      preferencesStore: PdfMemoryPreferencesStore(),
      autosaveDelay: const Duration(days: 1),
      checkpointInterval: const Duration(days: 1),
    );
    await session.ready;
    await session.toolReady;
  });
  tearDown(() async {
    session.dispose();
    await repo.flush();
    await root.delete(recursive: true);
  });

  test('whole eraser removes a physical gesture across every cached chunk', () {
    final page = inkPageId(session.editing.document, 0);
    final live = LiveInk(session.ink);
    for (final y in [100.0, 200.0]) {
      live.begin(page, 0xff123456, 2);
      for (var i = 0; i < 300; i++) {
        live.add(20 + i * .5, y, .5);
      }
      live.finish();
    }
    final before = session.ink.index.strokes.toList();
    final group = before.first.group;
    expect(before.where((s) => s.group == group).length, greaterThan(1));
    final erase = InkEraserGesture(session.ink, page, 4, wholeStroke: true)
      ..add(const Offset(90, 100));
    erase.finish();
    expect(session.ink.index.strokes.every((s) => s.group != group), isTrue);
    expect(session.ink.index.strokes, isNotEmpty);
    session.editing.undo();
    expect(
      session.ink.index.strokes.map((s) => s.id),
      unorderedEquals(before.map((s) => s.id)),
    );
    session.editing.redo();
    expect(session.ink.index.strokes.every((s) => s.group != group), isTrue);
    final cancel = InkEraserGesture(session.ink, page, 4, wholeStroke: true)
      ..add(const Offset(90, 200));
    cancel.finish(cancel: true);
    expect(session.ink.hidden, isEmpty);
    expect(session.ink.index.strokes, isNotEmpty);
    live.dispose();
  });

  test(
    'legacy grouped PDF ink loses only the touched physical stroke with undo',
    () {
      session.preferences
        ..color = const Color(0xff123456)
        ..opacity = .75
        ..strokeWidth = 3;
      session.editing.addInkStroke(
        0,
        [(20, 100), (90, 100), (160, 100)],
        pressures: [.2, .6, .8],
      );
      session.editing.addInkStroke(
        0,
        [(20, 200), (90, 200), (160, 200)],
        pressures: [.3, .5, .7],
      );
      session.editing.finishInk();
      final before = session.editing.document.page(0).annotations.single;
      expect(before.inkList, hasLength(2));
      final erase = PdfWholeStrokeEraser(session.editing, 0, 4)
        ..add(const Offset(90, 100));
      erase.finish();
      final after = session.editing.document.page(0).annotations.single;
      expect(after.inkList, hasLength(1));
      expect(after.inkList!.single, before.inkList!.last);
      expect(after.color, before.color);
      expect(after.borderWidth, before.borderWidth);
      expect(after.appearanceOpacity, closeTo(before.appearanceOpacity, .001));
      session.editing.undo();
      expect(
        session.editing.document.page(0).annotations.single.inkList,
        hasLength(2),
      );
      session.editing.redo();
      expect(
        session.editing.document.page(0).annotations.single.inkList,
        hasLength(1),
      );
    },
  );

  testWidgets('eraser mode is configurable and survives a catalog restart', (
    tester,
  ) async {
    final drawing = repo.catalog.drawingPreferences;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorToolbar(
            session: session,
            catalog: repo.catalog,
            onTextSelection: () {},
            onTool: (_) {},
            onLasso: () {},
            onTape: () {},
            onImage: () {},
            onPreset: (_) {},
            onEditPreset: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Tool settings'));
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('whole-stroke-eraser')),
    );
    expect(toggle.value, isFalse);
    await tester.runAsync(() async {
      toggle.onChanged!(true);
      await drawing.flush();
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('whole-stroke-eraser')),
          )
          .value,
      isTrue,
    );
    final reopened = LibraryCatalog(repo.catalog.file);
    await tester.runAsync(reopened.load);
    expect(reopened.drawingPreferences.wholeStrokeEraser, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
