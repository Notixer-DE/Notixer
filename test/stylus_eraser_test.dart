import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/input/stylus_eraser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfEditingPreferences preferences;
  late PdfEditingController editing;
  late StylusEraser eraser;
  setUp(() async {
    preferences = PdfEditingPreferences(store: PdfMemoryPreferencesStore());
    await preferences.ready;
    editing = PdfEditingController(
      await createPaper('blank'),
      preferences: preferences,
    )..tool = PdfEditTool.highlight;
    eraser = StylusEraser(editing);
  });
  tearDown(() {
    eraser.reset();
    editing.dispose();
    preferences.dispose();
  });

  test(
    'side button erases from pointer-down and cancellation restores the highlighter',
    () {
      eraser.handle(
        const PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.stylus,
          buttons: kStylusContact | kPrimaryStylusButton,
        ),
        (_) {
          expect(editing.tool, PdfEditTool.eraser);
        },
      );
      eraser.handle(
        const PointerCancelEvent(pointer: 1, kind: PointerDeviceKind.stylus),
        (_) {
          expect(editing.tool, PdfEditTool.eraser);
        },
      );
      expect(editing.tool, PdfEditTool.highlight);
    },
  );

  test('switching pane while hovering with the button held keeps erasing', () {
    eraser.handle(
      const PointerHoverEvent(
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      ),
      (_) {},
    );
    eraser.setBaseTool(PdfEditTool.ink);
    expect(editing.tool, PdfEditTool.eraser);
    eraser.handle(
      const PointerDownEvent(
        pointer: 5,
        kind: PointerDeviceKind.stylus,
        buttons: kStylusContact | kPrimaryStylusButton,
      ),
      (_) {
        expect(editing.tool, PdfEditTool.eraser);
      },
    );
    eraser.handle(
      const PointerUpEvent(pointer: 5, kind: PointerDeviceKind.stylus),
      (_) {},
    );
    expect(editing.tool, PdfEditTool.ink);
  });

  test('mouse buttons and finger input do not enable the stylus eraser', () {
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      eraser.handle(
        PointerDownEvent(kind: kind, buttons: kSecondaryButton),
        (_) {},
      );
      expect(editing.tool, PdfEditTool.highlight);
    }
  });

  test(
    'mid-contact button changes finish the old segment with a unique new gesture ID',
    () {
      final events = <(Type, int, PdfEditTool?)>[];
      void forward(PointerEvent e) =>
          events.add((e.runtimeType, e.pointer, editing.tool));
      eraser.handle(
        const PointerDownEvent(pointer: 10, kind: PointerDeviceKind.stylus),
        forward,
      );
      eraser.handle(
        const PointerMoveEvent(
          pointer: 10,
          kind: PointerDeviceKind.stylus,
          buttons: kStylusContact | kSecondaryStylusButton,
        ),
        forward,
      );
      expect(events[1], (PointerUpEvent, 10, PdfEditTool.highlight));
      expect(events[2].$1, PointerDownEvent);
      expect(events[2].$2, isNot(10));
      expect(events[2].$3, PdfEditTool.eraser);
      eraser.handle(
        const PointerMoveEvent(
          pointer: 10,
          kind: PointerDeviceKind.stylus,
          buttons: kStylusContact,
        ),
        forward,
      );
      expect(events[3], (PointerUpEvent, events[2].$2, PdfEditTool.eraser));
      expect(events[4].$1, PointerDownEvent);
      expect(events[4].$2, isNot(events[2].$2));
      expect(events[4].$3, PdfEditTool.highlight);
      eraser.handle(
        const PointerUpEvent(pointer: 10, kind: PointerDeviceKind.stylus),
        forward,
      );
      expect(events.last, (
        PointerUpEvent,
        events[4].$2,
        PdfEditTool.highlight,
      ));
    },
  );

  test(
    'reset cancels an active segment and restores a previously selected eraser',
    () {
      editing.tool = PdfEditTool.eraser;
      final events = <PointerEvent>[];
      eraser.handle(
        const PointerDownEvent(
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          buttons: kStylusContact | kPrimaryStylusButton,
        ),
        events.add,
      );
      eraser.reset();
      expect(events.last, isA<PointerCancelEvent>());
      expect(events.last.pointer, 7);
      expect(editing.tool, PdfEditTool.eraser);
    },
  );
}
