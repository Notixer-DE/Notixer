import 'package:flutter/gestures.dart';

bool isStylus(PointerEvent event) =>
    event.kind == PointerDeviceKind.stylus ||
    event.kind == PointerDeviceKind.invertedStylus;

bool usesStylusEraser(PointerEvent event) =>
    isStylus(event) &&
    (event.kind == PointerDeviceKind.invertedStylus ||
        event.buttons & (kPrimaryStylusButton | kSecondaryStylusButton) != 0);

double drawingPressure(PointerEvent event, {required bool sensitive}) {
  if (!sensitive || !isStylus(event)) return .5;
  final range = event.pressureMax - event.pressureMin;
  return range > 0
      ? ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0)
      : .5;
}
