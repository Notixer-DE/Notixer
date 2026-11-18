import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/ui/markdown_zoom_surface.dart';

void main() {
  testWidgets(
    'reading zoom supports shortcuts and pinch without consuming scroll',
    (tester) async {
      double zoom = 1;
      final scroll = ScrollController();
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MarkdownZoomSurface(
                enabled: true,
                zoom: zoom,
                onChanged: (value) => update(() => zoom = value),
                child: ListView(
                  controller: scroll,
                  children: const [SizedBox(height: 3000)],
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(zoom, closeTo(1.1, .001));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(zoom, 1);
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      final first = await tester.startGesture(
        const Offset(250, 250),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(350, 250),
        pointer: 2,
      );
      await first.moveTo(const Offset(200, 250));
      await second.moveTo(const Offset(400, 250));
      await tester.pump();
      expect(zoom, closeTo(2, .001));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
