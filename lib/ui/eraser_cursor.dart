import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef EraserContact = ({Offset center, double radius});

/// Only this overlay repaints on pointer moves, not the PDF or editor chrome.
class EraserCursorPainter extends CustomPainter {
  EraserCursorPainter(this.contact) : super(repaint: contact);
  final ValueListenable<EraserContact?> contact;

  @override
  void paint(Canvas canvas, Size size) {
    final value = contact.value;
    if (value == null) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white;
    canvas.drawCircle(value.center, value.radius, paint);
    paint
      ..strokeWidth = 1
      ..color = const Color(0xff333333);
    canvas.drawCircle(value.center, value.radius, paint);
  }

  @override
  bool shouldRepaint(EraserCursorPainter oldDelegate) =>
      contact != oldDelegate.contact;
}
