import 'dart:io';
import 'dart:typed_data';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/selection_transform_overlay.dart';

void main() {
  testWidgets(
    'direct ink selection movement is live, durable and one undo step',
    (tester) async {
      final fixture = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'noter-selection-pane-',
        );
        final repo = LocalNotebookRepository(directory);
        final bytes = await createPaper('blank');
        final note = await repo.create('Selection', bytes);
        final session = DocumentSession(
          note,
          bytes,
          repo,
          preferencesStore: PdfMemoryPreferencesStore(),
          autosaveDelay: const Duration(days: 1),
          checkpointInterval: const Duration(days: 1),
        );
        await Future.wait([session.ready, session.toolReady]);
        return (directory, repo, session);
      });
      final (directory, repo, session) = fixture!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorPane(
              session: session,
              active: true,
              split: false,
              onActivate: () {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      final original = InkStroke(
        id: 'selected',
        page: inkPageId(session.editing.document, 0),
        order: 0,
        color: 0xff123456,
        width: 3,
        points: Float32List.fromList([100, 650, .5, 200, 680, .5]),
      );
      session.ink.apply(InkEdit(add: [original]));
      session.editing.tool = PdfEditTool.select;
      session.ink.select([original.id]);
      await tester.pumpAndSettle();
      expect(find.byType(SelectionTransformOverlay), findsOneWidget);
      final move = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Move selection')),
      );
      await move.moveBy(const Offset(40, 20));
      await tester.pump();
      expect(session.ink.hidden, contains(original.id));
      expect(session.ink.preview[original.id], isNotNull);
      expect(
        session.ink.index[original.id]!.points,
        orderedEquals(original.points),
      );
      await move.up();
      await tester.pump();
      expect(session.ink.hidden, isEmpty);
      expect(
        session.ink.index[original.id]!.points[0],
        isNot(original.points[0]),
      );
      final moved = session.ink.index[original.id]!.points.toList();
      session.undo();
      await tester.pump();
      expect(
        session.ink.index[original.id]!.points,
        orderedEquals(original.points),
      );
      session.redo();
      await tester.pump();
      expect(session.ink.index[original.id]!.points, orderedEquals(moved));
      var saved = false;
      session.save().then((value) => saved = value);
      for (var i = 0; i < 200 && !saved; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(saved, isTrue);
      InkDocument? reopened;
      repo.openInk(session.note.id).then((value) => reopened = value.$1);
      for (var i = 0; i < 200 && reopened == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(reopened, isNotNull);
      expect(reopened!.strokes.single.points, orderedEquals(moved));
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}
