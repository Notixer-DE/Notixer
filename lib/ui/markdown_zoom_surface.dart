import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Raw touch tracking preserves the reader's normal one-finger scroll gestures.
class MarkdownZoomSurface extends StatefulWidget {
  const MarkdownZoomSurface({
    super.key,
    required this.enabled,
    required this.zoom,
    required this.onChanged,
    required this.child,
  });
  final bool enabled;
  final double zoom;
  final ValueChanged<double> onChanged;
  final Widget child;

  @override
  State<MarkdownZoomSurface> createState() => _MarkdownZoomSurfaceState();
}

class _MarkdownZoomSurfaceState extends State<MarkdownZoomSurface> {
  final _points = <int, Offset>{};
  double? _distance;
  double _startZoom = 1;

  void _update(PointerEvent event) {
    if (!widget.enabled || event.kind != PointerDeviceKind.touch) return;
    _points[event.pointer] = event.position;
    if (_points.length != 2) {
      _distance = null;
      return;
    }
    final points = _points.values.toList();
    final distance = (points[0] - points[1]).distance;
    if (_distance == null) {
      _distance = distance;
      _startZoom = widget.zoom;
    } else if (_distance! > 0) {
      widget.onChanged((_startZoom * distance / _distance!).clamp(.7, 2.5));
    }
  }

  void _remove(PointerEvent event) {
    _points.remove(event.pointer);
    _distance = null;
  }

  @override
  void didUpdateWidget(MarkdownZoomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _points.clear();
      _distance = null;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      final keyboard = HardwareKeyboard.instance;
      if (!widget.enabled ||
          keyboard.isAltPressed ||
          !(keyboard.isControlPressed || keyboard.isMetaPressed)) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      final increase = [
        LogicalKeyboardKey.equal,
        LogicalKeyboardKey.add,
        LogicalKeyboardKey.numpadAdd,
      ].contains(key);
      final decrease = [
        LogicalKeyboardKey.minus,
        LogicalKeyboardKey.numpadSubtract,
      ].contains(key);
      final reset = [
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.numpad0,
      ].contains(key);
      if (!increase && !decrease && !reset) return KeyEventResult.ignored;
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        widget.onChanged(
          reset ? 1 : (widget.zoom + (increase ? .1 : -.1)).clamp(.7, 2.5),
        );
      }
      return KeyEventResult.handled;
    },
    child: Listener(
      onPointerDown: _update,
      onPointerMove: _update,
      onPointerUp: _remove,
      onPointerCancel: _remove,
      child: widget.child,
    ),
  );
}
