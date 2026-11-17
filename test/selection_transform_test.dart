import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/editor/operations.dart';
import 'package:pdf_document/pdf_document.dart'
    show PdfRect, PdfAnnotationEditing;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/ink.dart';
import 'package:noter/ui/selection_transform_overlay.dart';

void main() {
  test('anisotropic ink transforms preserve pressure and a fixed anchor', () {
    final stroke = InkStroke(
      id: 'test',
      page: '1:0',
      order: 0,
      color: 0xff123456,
      width: 2,
      points: Float32List.fromList([10, 20, .25, 30, 40, .75]),
    );
    final moved = stroke.transform(
      origin: const Offset(10, 20),
      scaleX: 2,
      scaleY: 3,
      rotation: math.pi / 2,
      delta: const Offset(5, 6),
    );
    expect(moved.points[0], closeTo(15, .001));
    expect(moved.points[1], closeTo(26, .001));
    expect(moved.points[3], closeTo(-45, .001));
    expect(moved.points[4], closeTo(66, .001));
    expect([moved.points[2], moved.points[5]], [.25, .75]);
    expect(stroke.points[3], 30);
    expect(() => stroke.transform(scaleX: double.nan), throwsArgumentError);
  });

  test('mixed PDF and ink resizing uses one shared fixed anchor', () async {
    final editing = PdfEditingController(
      await createPaper('blank'),
      preferences: PdfEditingPreferences(store: PdfMemoryPreferencesStore()),
    );
    addTearDown(() {
      editing.preferences.dispose();
      editing.dispose();
    });
    editing.apply((e) => e.addSquare(0, const PdfRect(40, 60, 80, 100)));
    editing.selectAnnotation(0, 0);
    final stroke = InkStroke(
      id: 'ink',
      page: inkPageId(editing.document, 0),
      order: 0,
      color: 0xff000000,
      width: 2,
      points: Float32List.fromList([10, 20, .5, 30, 40, .5]),
    );
    final ink = InkController(
      InkDocument(generation: 'mixed', strokes: [stroke]),
    );
    addTearDown(ink.dispose);
    ink.select([stroke.id]);
    transformNotebookSelection(
      editing,
      ink,
      anchor: const Offset(10, 20),
      scaleX: 2,
      scaleY: 3,
      delta: const Offset(5, 6),
    );
    final rect = editing.document.page(0).annotations.single.rect;
    expect(rect.left, closeTo(75, .01));
    expect(rect.bottom, closeTo(146, .01));
    expect(rect.width, closeTo(80, .01));
    expect(rect.height, closeTo(120, .01));
    final points = ink.index.strokes.single.points;
    expect(points[0], closeTo(15, .01));
    expect(points[1], closeTo(26, .01));
  });

  testWidgets(
    'selection grips resize, rotate, move and cancel without early commits',
    (tester) async {
      SelectionTransform? preview, committed;
      var starts = 0, cancels = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: SelectionTransformOverlay(
                bounds: const Rect.fromLTWH(100, 100, 200, 120),
                toLocal: (p) => p,
                toPage: (p) => p,
                onStart: () => starts++,
                onUpdate: (v) => preview = v,
                onFinish: (v, cancel) {
                  if (cancel) {
                    cancels++;
                  } else {
                    committed = v;
                  }
                },
              ),
            ),
          ),
        ),
      );
      Finder handle(String label) => find.bySemanticsLabel(label);
      final right = handle('Resize selection 1,0');
      final gesture = await tester.startGesture(tester.getCenter(right));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(preview!.scaleX, closeTo(1.5, .01));
      expect(preview!.scaleY, 1);
      expect(preview!.map(const Offset(100, 160)), const Offset(100, 160));
      expect(committed, isNull);
      await gesture.up();
      await tester.pump();
      expect(committed!.scaleX, closeTo(1.5, .01));
      committed = null;
      final rotation = await tester.startGesture(
        tester.getCenter(handle('Rotate selection')),
      );
      await rotation.moveBy(const Offset(100, 92));
      await tester.pump();
      expect(preview!.rotation.abs(), greaterThan(.1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancels, 1);
      expect(committed, isNull);
      await rotation.up();
      await tester.pump();
      final move = await tester.startGesture(
        tester.getCenter(handle('Move selection')),
      );
      await move.moveBy(const Offset(30, 40));
      await tester.pump();
      expect(preview!.delta, const Offset(30, 40));
      await move.up();
      await tester.pump();
      expect(committed!.delta, const Offset(30, 40));
      expect(starts, 3);
    },
  );
}
