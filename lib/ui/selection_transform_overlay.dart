import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';

/// A gesture is provisional until pointer-up; the host commits one undo step.
class SelectionTransform {
  const SelectionTransform({
    required this.origin,
    this.delta = Offset.zero,
    this.scaleX = 1,
    this.scaleY = 1,
    this.rotation = 0,
  });
  final Offset origin, delta;
  final double scaleX, scaleY, rotation;
  bool get isIdentity =>
      delta == Offset.zero && scaleX == 1 && scaleY == 1 && rotation == 0;
  Offset map(Offset point) {
    final p = point - origin;
    final x = p.dx * scaleX, y = p.dy * scaleY;
    return origin +
        delta +
        Offset(
          x * math.cos(rotation) - y * math.sin(rotation),
          x * math.sin(rotation) + y * math.cos(rotation),
        );
  }
}

class SelectionTransformOverlay extends StatefulWidget {
  const SelectionTransformOverlay({
    super.key,
    required this.bounds,
    required this.toLocal,
    required this.toPage,
    required this.onStart,
    required this.onUpdate,
    required this.onFinish,
    this.moveEnabled = true,
  });
  final Rect bounds;
  final bool moveEnabled;
  final Offset Function(Offset) toLocal, toPage;
  final VoidCallback onStart;
  final ValueChanged<SelectionTransform> onUpdate;
  final void Function(SelectionTransform transform, bool cancel) onFinish;
  @override
  State<SelectionTransformOverlay> createState() =>
      _SelectionTransformOverlayState();
}

class _SelectionTransformOverlayState extends State<SelectionTransformOverlay> {
  final _key = GlobalKey();
  final _focus = FocusNode(debugLabel: 'selection-transform');
  SelectionTransform? _value;
  Rect? _original;
  Offset? _start;
  Offset _origin = Offset.zero;
  bool _rotating = false;
  Offset? _handle;

  Offset _point(Offset global) {
    final box = _key.currentContext!.findRenderObject()! as RenderBox;
    return widget.toPage(box.globalToLocal(global));
  }

  void _begin(DragStartDetails details, Offset? handle, {bool rotate = false}) {
    _focus.requestFocus();
    _original = widget.bounds;
    _handle = handle;
    _rotating = rotate;
    _start = _point(details.globalPosition);
    final bounds = _original!;
    _origin = handle == null || rotate
        ? bounds.center
        : Offset(
            bounds.left + bounds.width * (1 - handle.dx) / 2,
            bounds.top + bounds.height * (1 - handle.dy) / 2,
          );
    _value = SelectionTransform(origin: _origin);
    widget.onStart();
  }

  void _update(DragUpdateDetails details) {
    if (_start == null) return;
    final p = _point(details.globalPosition);
    final h = _handle;
    final SelectionTransform value;
    if (_rotating) {
      final from = _start! - _origin, to = p - _origin;
      value = SelectionTransform(
        origin: _origin,
        rotation: math.atan2(to.dy, to.dx) - math.atan2(from.dy, from.dx),
      );
    } else if (h == null) {
      value = SelectionTransform(origin: _origin, delta: p - _start!);
    } else {
      final from = _start! - _origin, to = p - _origin;
      value = SelectionTransform(
        origin: _origin,
        scaleX: h.dx == 0 || from.dx.abs() < .001
            ? 1
            : (to.dx / from.dx).clamp(.05, 20),
        scaleY: h.dy == 0 || from.dy.abs() < .001
            ? 1
            : (to.dy / from.dy).clamp(.05, 20),
      );
    }
    setState(() => _value = value);
    widget.onUpdate(value);
  }

  void _finish(bool cancel) {
    final value = _value;
    if (value == null) return;
    _start = null;
    _original = null;
    _value = null;
    widget.onFinish(value, cancel);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Widget _target(
    String label,
    Widget child, {
    Offset? handle,
    bool rotate = false,
  }) => Semantics(
    button: true,
    label: label,
    child: MouseRegion(
      cursor: rotate
          ? SystemMouseCursors.grab
          : handle == null
          ? SystemMouseCursors.move
          : SystemMouseCursors.resizeUpLeftDownRight,
      child: Listener(
        // Flutter ends an accepted pan on a raw pointer cancellation.
        // Discard its preview before the recognizer can commit it.
        onPointerCancel: (_) => _finish(true),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _begin(d, handle, rotate: rotate),
          onPanUpdate: _update,
          onPanEnd: (_) => _finish(false),
          onPanCancel: () => _finish(true),
          child: child,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final bounds = _original ?? widget.bounds;
    final transform = _value ?? SelectionTransform(origin: bounds.center);
    Offset local(Offset p) => widget.toLocal(transform.map(p));
    final corners = [
      local(bounds.topLeft),
      local(bounds.topRight),
      local(bounds.bottomRight),
      local(bounds.bottomLeft),
    ];
    final screen = corners.fold(
      Rect.fromPoints(corners.first, corners.first),
      (rect, p) => rect.expandToInclude(Rect.fromPoints(p, p)),
    );
    // Screen-space rotation target remains a usable 44px touch target at any zoom.
    final rotatePoint = Offset(screen.center.dx, math.max(24, screen.top - 52));
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _value != null) {
          _finish(true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        key: _key,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _FramePainter(corners, rotatePoint)),
            ),
          ),
          if (widget.moveEnabled)
            Positioned.fromRect(
              rect: screen.deflate(math.min(12, screen.shortestSide / 4)),
              child: _target('Move selection', const SizedBox.expand()),
            ),
          for (final handle in const [
            Offset(-1, -1),
            Offset(0, -1),
            Offset(1, -1),
            Offset(-1, 0),
            Offset(1, 0),
            Offset(-1, 1),
            Offset(0, 1),
            Offset(1, 1),
          ])
            Positioned.fromRect(
              rect: Rect.fromCenter(
                center: local(
                  Offset(
                    bounds.left + bounds.width * (handle.dx + 1) / 2,
                    bounds.top + bounds.height * (handle.dy + 1) / 2,
                  ),
                ),
                width: 44,
                height: 44,
              ),
              child: _target(
                'Resize selection ${handle.dx.toInt()},${handle.dy.toInt()}',
                Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: const Color(0xff238b7e),
                        width: 2,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                handle: handle,
              ),
            ),
          Positioned.fromRect(
            rect: Rect.fromCenter(center: rotatePoint, width: 44, height: 44),
            child: _target(
              'Rotate selection',
              const Center(
                child: Icon(
                  Icons.rotate_right,
                  color: Color(0xff238b7e),
                  size: 22,
                ),
              ),
              rotate: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.corners, this.rotation);
  final List<Offset> corners;
  final Offset rotation;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff238b7e)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(Path()..addPolygon(corners, true), paint);
    final top = corners.reduce((a, b) => a.dy < b.dy ? a : b);
    canvas.drawLine(Offset(rotation.dx, top.dy), rotation, paint);
  }

  @override
  bool shouldRepaint(_FramePainter old) => true;
}
