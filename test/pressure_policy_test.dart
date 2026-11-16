import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/drawing_preferences.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';

void main() {
  test(
    'pressure policies and presets persist independently with old preset defaults',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-pressure-');
      try {
        final catalog = LibraryCatalog(File('${root.path}/catalog.json'));
        await catalog.load();
        await Future.wait([
          catalog.drawingPreferences.setPressureSensitive('ink', false),
          catalog.drawingPreferences.setPressureSensitive('highlight', true),
        ]);
        await catalog.setPreset(
          0,
          const PenPreset(
            'Fix',
            'ink',
            0xff123456,
            3,
            1,
            pressureSensitive: false,
          ),
        );
        final reopened = LibraryCatalog(catalog.file);
        await reopened.load();
        expect(reopened.drawingPreferences.pressureSensitive('ink'), isFalse);
        expect(
          reopened.drawingPreferences.pressureSensitive('highlight'),
          isTrue,
        );
        expect(reopened.presets.first.pressureSensitive, isFalse);
        expect(
          PenPreset.fromJson({
            'name': 'Alt',
            'tool': 'ink',
            'color': 0xff000000,
            'width': 2,
            'opacity': 1,
          }).pressureSensitive,
          isTrue,
        );
        final fresh = DrawingPreferences(File('${root.path}/missing.json'));
        await fresh.load();
        expect(fresh.pressureSensitive('ink'), isTrue);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'fixed and variable pressure survive gestures, encoding and PDF export for pen and marker',
    (tester) async {
      final fixture = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'noter-pressure-ui-',
        );
        final repo = LocalNotebookRepository(root);
        final bytes = await createPaper('blank');
        return (root, repo, bytes, await repo.create('Druck', bytes));
      });
      final (root, repo, bytes, note) = fixture!;
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(note: note, bytes: bytes, repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      final session = pane.widget.session;
      final bounds = pane.viewer.globalRectOf(
        0,
        pane.editing.document.page(0).cropBox,
      )!;
      var pointer = 100;
      for (final tool in [PdfEditTool.ink, PdfEditTool.highlight]) {
        for (final sensitive in [true, false]) {
          final name = tool == PdfEditTool.ink ? 'ink' : 'highlight';
          await tester.runAsync(
            () => repo.catalog.drawingPreferences.setPressureSensitive(
              name,
              sensitive,
            ),
          );
          await tester.runAsync(
            () =>
                repo.catalog.drawingPreferences.setStraightStrokes(!sensitive),
          );
          session.eraser.setBaseTool(tool);
          final previous = session.ink.index.strokes.map((s) => s.id).toSet();
          final start =
              bounds.topLeft +
              Offset(bounds.width * .2, bounds.height * .3 + pointer - 100);
          void feed(PointerEvent e) =>
              session.eraser.handle(e, pane.handleCustomInput);
          feed(
            PointerDownEvent(
              pointer: pointer,
              kind: PointerDeviceKind.stylus,
              position: start,
              pressure: .1,
              pressureMin: 0,
              pressureMax: 1,
            ),
          );
          for (var i = 1; i < 90; i++) {
            feed(
              PointerMoveEvent(
                pointer: pointer,
                kind: PointerDeviceKind.stylus,
                position: start + Offset(i * .5, 0),
                pressure: .1 + i / 110,
                pressureMin: 0,
                pressureMax: 1,
              ),
            );
          }
          feed(
            PointerUpEvent(
              pointer: pointer++,
              kind: PointerDeviceKind.stylus,
              position: start + const Offset(44.5, 0),
            ),
          );
          await tester.pump();
          final added = session.ink.index.strokes
              .where((s) => !previous.contains(s.id))
              .toList();
          expect(added, isNotEmpty);
          if (!sensitive) {
            expect(added, hasLength(1));
            expect(added.single.pointCount, 2);
          }
          final pressures = [
            for (final s in added)
              for (var i = 2; i < s.points.length; i += 3) s.points[i],
          ];
          if (sensitive) {
            expect(
              pressures.toSet().length,
              greaterThan(2),
              reason: '$name sensitive=$sensitive',
            );
          } else {
            expect(pressures.every((p) => p == .5), isTrue);
          }
        }
      }
      final snapshot = InkDocument.decode(session.ink.snapshot().encode());
      expect(snapshot.strokes, isNotEmpty);
      expect(pane.editing.revisionId, 0);
      expect(
        PdfDocument.open(pdfWithInk(bytes, snapshot)).page(0).annotations,
        hasLength(4),
      );
      for (var i = 0; i < 150 && !session.inkJournalCurrent; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.inkJournalCurrent, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() => root.delete(recursive: true));
      expect(tester.takeException(), isNull);
    },
  );
}
