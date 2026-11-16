import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Runs before the viewer receives pointer events, including its first down.
/// An outer Listener would run after the page's own Listener and miss that down.
class NoterBinding extends WidgetsFlutterBinding {
  static PointerDeviceKind? eventKind;

  static StylusEraser? Function(PointerEvent)? resolveEraser;
  static bool Function(PointerEvent)? interceptEvent;
  final Map<int, StylusEraser> _owners = {};
  final Set<int> _stylusContacts = {};
  final _touchReplay = CapturedTouchReplay();
  static int? replayTouchPointer;

  void _route(PointerEvent event, void Function(PointerEvent) forward) =>
      _touchReplay.route(
        event,
        intercept: (event) {
          replayTouchPointer = null;
          return interceptEvent?.call(event) == true;
        },
        forward: forward,
        replayPointer: () => replayTouchPointer,
        stylusActive: stylusContactActive,
      );

  static bool get stylusContactActive {
    final binding = WidgetsBinding.instance;
    return binding is NoterBinding && binding._stylusContacts.isNotEmpty;
  }

  static void unregister(StylusEraser eraser) {
    final binding = WidgetsBinding.instance;
    if (binding is NoterBinding) {
      binding._owners.removeWhere((pointer, value) {
        if (!identical(value, eraser)) return false;
        binding._stylusContacts.remove(pointer);
        return true;
      });
    }
    eraser.reset();
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (locked) {
      super.handlePointerEvent(event);
      return;
    }
    eventKind = event.kind;
    if ((event is PointerDownEvent || event is PointerHoverEvent) &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      _stylusContacts.add(event.pointer);
    }
    final resolved = event is PointerDownEvent || event is PointerHoverEvent
        ? resolveEraser?.call(event)
        : null;
    if (event is PointerHoverEvent) {
      final previous = _owners[event.pointer];
      if (previous != null && !identical(previous, resolved)) {
        previous.reset();
        _owners.remove(event.pointer);
      }
      if (resolved != null) _owners[event.pointer] = resolved;
    }
    final eraser = _owners[event.pointer] ?? resolved;
    if (event is PointerDownEvent && eraser != null) {
      _owners[event.pointer] = eraser;
    }
    try {
      if (eraser == null) {
        _route(event, super.handlePointerEvent);
      } else {
        eraser.handle(event, (forwarded) {
          _route(forwarded, super.handlePointerEvent);
        });
      }
    } finally {
      if (event is PointerUpEvent ||
          event is PointerCancelEvent ||
          event is PointerRemovedEvent ||
          event is PointerExitEvent) {
        if (event is PointerExitEvent) eraser?.reset();
        _owners.remove(event.pointer);
        _stylusContacts.remove(event.pointer);
      }
    }
  }
}

/// Momentary eraser: the side button never replaces the user's chosen tool.
class StylusEraser {
  StylusEraser(this.editing);
  final PdfEditingController editing;
  final Map<int, int> _contacts = {};
  final Map<int, PointerEvent> _lastEvents = {};
  static int _nextSegment = -1000000;
  void Function(PointerEvent)? _forward;
  bool _held = false;
  bool get held => _held;
  bool get contactActive => _contacts.isNotEmpty;
  PdfEditTool? _previousTool;

  void setBaseTool(PdfEditTool? tool) {
    if (_held) {
      _previousTool = tool;
      editing.tool = PdfEditTool.eraser;
    } else {
      editing.tool = tool;
    }
  }

  void _setHeld(bool held) {
    if (_held == held) return;
    _held = held;
    if (held) {
      _previousTool = editing.tool;
      // Make a just-finished stroke available to the eraser immediately.
      editing.finishInk();
      editing.tool = PdfEditTool.eraser;
    } else {
      // Respect a tool the user explicitly selected in the meantime.
      if (editing.tool == PdfEditTool.eraser) editing.tool = _previousTool;
      _previousTool = null;
    }
  }

  void reset() {
    final contacts = Map.of(_contacts);
    _contacts.clear();
    for (final contact in contacts.entries) {
      final last = _lastEvents[contact.key]!;
      _forward?.call(
        PointerCancelEvent(
          viewId: last.viewId,
          timeStamp: last.timeStamp,
          pointer: contact.value,
          device: last.device,
          kind: last.kind,
          position: last.position,
        ),
      );
    }
    _lastEvents.clear();
    _setHeld(false);
  }

  void handle(PointerEvent event, void Function(PointerEvent) forward) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      forward(event);
      return;
    }
    _forward = forward;
    final routedPointer = _contacts[event.pointer] ?? event.pointer;
    if (_contacts.containsKey(event.pointer)) {
      _lastEvents[event.pointer] = event;
    }
    if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerRemovedEvent) {
      // Finish the eraser gesture before restoring the previous tool/style.
      try {
        forward(event.copyWith(pointer: routedPointer));
      } finally {
        _contacts.remove(event.pointer);
        _lastEvents.remove(event.pointer);
        _setHeld(false);
      }
      return;
    }
    final held =
        event.kind == PointerDeviceKind.invertedStylus ||
        event.buttons & (kPrimaryStylusButton | kSecondaryStylusButton) != 0;
    if (event is PointerMoveEvent &&
        _contacts.containsKey(event.pointer) &&
        held != _held) {
      // The PDF viewer latches drawing/erasing at pointer-down. Split a
      // continuous contact into two strokes at the button transition so the
      // old segment commits with its original style and the new one erases
      // (or draws) immediately. Keep device, position, time and pressure.
      forward(
        PointerUpEvent(
          viewId: event.viewId,
          timeStamp: event.timeStamp,
          pointer: routedPointer,
          device: event.device,
          kind: event.kind,
          position: event.position,
        ),
      );
      _setHeld(held);
      // A fresh logical pointer lets gesture recognizers finish resolving the
      // old arena asynchronously without reusing a still-closed arena.
      final segment = _nextSegment--;
      _contacts[event.pointer] = segment;
      forward(
        PointerDownEvent(
          viewId: event.viewId,
          timeStamp: event.timeStamp,
          pointer: segment,
          device: event.device,
          kind: event.kind,
          position: event.position,
          buttons: event.buttons,
          pressure: event.pressure,
          pressureMin: event.pressureMin,
          pressureMax: event.pressureMax,
          distanceMax: event.distanceMax,
          orientation: event.orientation,
          tilt: event.tilt,
        ),
      );
      return;
    }
    if (event is PointerDownEvent || event is PointerHoverEvent) {
      _setHeld(held);
    }
    if (event is PointerDownEvent) {
      _contacts[event.pointer] = event.pointer;
      _lastEvents[event.pointer] = event;
    }
    forward(event.copyWith(pointer: routedPointer));
  }
}

/// Returns a captured first contact to the viewer only when its owning pane
/// explicitly yields it for a pinch. A touch outside that pane cannot replay it.
class CapturedTouchReplay {
  PointerDownEvent? _down;
  Offset? _position;
  void route(
    PointerEvent event, {
    required bool Function(PointerEvent) intercept,
    required void Function(PointerEvent) forward,
    required int? Function() replayPointer,
    bool stylusActive = false,
  }) {
    final handled = intercept(event);
    if (event is PointerDownEvent && event.kind == PointerDeviceKind.touch) {
      final first = _down;
      if (first != null &&
          replayPointer() == first.pointer &&
          !handled &&
          !stylusActive) {
        _down = null;
        forward(
          first.copyWith(
            position: _position ?? first.position,
            timeStamp: event.timeStamp,
          ),
        );
        _position = null;
      } else if (handled && !stylusActive) {
        if (_down == null) {
          _down = event;
          _position = event.position;
        }
      }
    }
    if (event.pointer == _down?.pointer && event is PointerMoveEvent) {
      _position = event.position;
    }
    if (event.pointer == _down?.pointer &&
        (event is PointerUpEvent ||
            event is PointerCancelEvent ||
            event is PointerRemovedEvent)) {
      _down = null;
      _position = null;
    }
    if (!handled) forward(event);
  }
}
