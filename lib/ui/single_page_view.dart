import 'dart:math' as math;
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../editor/navigation.dart';

/// A viewport policy over the original PDF, not a one-page document copy.
/// Annotation slots, page references and the ink coordinate space stay intact.
class SinglePageView extends StatefulWidget {
  const SinglePageView({
    super.key,
    required this.viewer,
    required this.editing,
    required this.child,
    required this.canSwipe,
    required this.background,
  });

  final NavigationViewerController viewer;
  final PdfEditingController editing;
  final Widget child;
  final bool Function() canSwipe;
  final Color background;

  @override
  State<SinglePageView> createState() => _SinglePageViewState();
}

class _SinglePageViewState extends State<SinglePageView> {
  final _viewportKey = GlobalKey();
  final _touches = <int>{};
  Offset? _start;
  Duration _started = Duration.zero;
  bool _multiTouch = false, _queued = false, _fitting = false;
  int _generation = 0, _revision = -1;
  Object? _searchResult;
  Object? _structure;
  Size? _size;
  double _fitZoom = 1;
  NavigationViewerController get viewer => widget.viewer;

  Rect? get _viewport {
    final box = _viewportKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  Rect? get _page {
    final index = viewer.currentPage;
    if (index < 0 || index >= widget.editing.document.pageCount) return null;
    return viewer.globalRectOf(
      index,
      widget.editing.document.page(index).cropBox,
    );
  }

  @override
  void initState() {
    super.initState();
    _revision = widget.editing.revisionId;
    _structure = _pageStructure();
    viewer.pinnedPage = viewer.currentPage;
    viewer.pageJump = _jump;
    viewer.capturePageViewport = (native) {
      final viewport = _viewport;
      final page = _page;
      return viewport == null || page == null || page.isEmpty
          ? native
          : PdfViewport(
              page: viewer.currentPage,
              top: (viewport.top - page.top) / page.height,
              left: (viewport.left - page.left) / page.width,
              zoom: native.zoom,
            );
    };
    viewer.viewportChanges.addListener(_schedule);
    viewer.addListener(_searchChanged);
    widget.editing.addListener(_documentChanged);
    _schedule();
  }

  void _searchChanged() {
    final index = viewer.currentMatch;
    final result = index >= 0 && index < viewer.searchResults.length
        ? viewer.searchResults[index]
        : null;
    if (identical(_searchResult, result)) return;
    _searchResult = result;
    if (result != null) _jump(result.match.pageIndex);
  }

  Object _pageStructure() {
    final document = widget.editing.document;
    final page = document.page(
      viewer.currentPage.clamp(0, document.pageCount - 1),
    );
    final ref = document.cos.referenceTo(page.dict);
    return (
      document.pageCount,
      ref?.objectNumber,
      ref?.generation,
      page.cropBox.width,
      page.cropBox.height,
      page.rotation,
    );
  }

  void _documentChanged() {
    if (_revision == widget.editing.revisionId) return;
    _revision = widget.editing.revisionId;
    final structure = _pageStructure();
    if (_structure != structure) {
      _structure = structure;
      _jump(viewer.currentPage);
    } else {
      _schedule();
    }
  }

  Future<void> _jump(int page) async {
    final generation = ++_generation;
    viewer.pinnedPage = page.clamp(0, widget.editing.document.pageCount - 1);
    _structure = _pageStructure();
    _fitting = true;
    // Let the new viewer/viewport size attach before fitting mixed page sizes.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return;
    final viewport = _viewport;
    final rect = _page;
    if (viewport == null || rect == null || rect.isEmpty) {
      _fitting = false;
      return;
    }
    _fitZoom =
        viewer.zoom *
        math.min(
          math.max(1, viewport.width - 16) / rect.width,
          math.max(1, viewport.height - 16) / rect.height,
        );
    viewer.setZoom(_fitZoom);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return;
    await viewer.jumpWithoutHistory(viewer.currentPage);
    if (!mounted || generation != _generation) return;
    _fitting = false;
    _schedule();
  }

  void _schedule() {
    if (_queued || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || _fitting) return;
      _constrain();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // A small page is centered; a zoomed page may pan but never expose its
  // neighbours. Corrections are in viewport pixels, independent of PDF units.
  static double _correction(double a, double b, double start, double end) {
    if (b - a <= end - start) return (start + end - a - b) / 2;
    if (a > start) return start - a;
    if (b < end) return end - b;
    return 0;
  }

  void _constrain() {
    final viewport = _viewport;
    final rect = _page;
    if (viewport == null || rect == null) return;
    _fitZoom =
        viewer.zoom *
        math.min(
          math.max(1, viewport.width - 16) / rect.width,
          math.max(1, viewport.height - 16) / rect.height,
        );
    if (viewer.zoom < _fitZoom - .001) {
      viewer.setZoom(_fitZoom);
      _schedule();
      return;
    }
    final dx = _correction(
      rect.left,
      rect.right,
      viewport.left,
      viewport.right,
    );
    final dy = _correction(
      rect.top,
      rect.bottom,
      viewport.top,
      viewport.bottom,
    );
    final sync = viewer.viewSync;
    if (sync != null && (dx.abs() > .25 || dy.abs() > .25)) {
      final transform = sync.transform.clone();
      final scale = transform.getMaxScaleOnAxis();
      // Move the list before translating its clipped viewport. Translating
      // alone can move a lazy page outside the list's painted window.
      final requestedScroll = math.max(0.0, sync.scrollPixels - dy / scale);
      viewer.applyViewSync(
        PdfViewSync(
          scrollPixels: requestedScroll,
          layoutZoom: sync.layoutZoom,
          transform: transform,
        ),
      );
      final actualScroll = viewer.viewSync?.scrollPixels ?? sync.scrollPixels;
      transform.storage[12] += dx;
      transform.storage[13] += dy + (actualScroll - sync.scrollPixels) * scale;
      viewer.applyViewSync(
        PdfViewSync(
          scrollPixels: actualScroll,
          layoutZoom: sync.layoutZoom,
          transform: transform,
        ),
      );
    }
  }

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      _start = null;
      return;
    }
    _touches.add(event.pointer);
    if (_touches.length == 1) {
      _start = widget.canSwipe() && viewer.zoom <= _fitZoom * 1.02
          ? event.position
          : null;
      _started = event.timeStamp;
      _multiTouch = false;
    } else {
      _multiTouch = true;
    }
  }

  void _up(PointerEvent event) {
    if (!_touches.remove(event.pointer)) return;
    final start = _start;
    if (event is PointerUpEvent &&
        _touches.isEmpty &&
        !_multiTouch &&
        start != null &&
        widget.canSwipe() &&
        !viewer.hasSelection &&
        event.timeStamp - _started < const Duration(milliseconds: 650)) {
      final delta = event.position - start;
      if (delta.dx.abs() > 56 && delta.dx.abs() > delta.dy.abs() * 1.8) {
        final target = viewer.currentPage + (delta.dx < 0 ? 1 : -1);
        if (target >= 0 && target < widget.editing.document.pageCount) {
          // Native input still receives Up, ending its gesture before the jump.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) viewer.jumpToPage(target);
          });
        }
      }
    }
    if (_touches.isEmpty) _start = null;
  }

  @override
  void dispose() {
    ++_generation;
    viewer.viewportChanges.removeListener(_schedule);
    viewer.removeListener(_searchChanged);
    widget.editing.removeListener(_documentChanged);
    viewer.pageJump = null;
    viewer.capturePageViewport = null;
    viewer.pinnedPage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_size != constraints.biggest) {
        _size = constraints.biggest;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jump(viewer.currentPage);
        });
      }
      return Listener(
        key: _viewportKey,
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            CustomPaint(
              painter: _PageMask(
                () {
                  final viewport = _viewport;
                  final page = _page;
                  return viewport == null || page == null
                      ? Rect.zero
                      : page.shift(-viewport.topLeft);
                },
                widget.background,
                viewer.viewportChanges,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PageMask extends CustomPainter {
  _PageMask(this.pageRect, this.background, Listenable changes)
    : super(repaint: changes);
  final Rect Function() pageRect;
  final Color background;
  // This overlay only hides neighbouring PDF pages visually. It must not
  // consume touch input in the margins: a finger should still be able to
  // start panning the document there, even in single-page mode.
  @override
  bool? hitTest(Offset position) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final page = pageRect();
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(page.intersect(Offset.zero & size));
    canvas.drawPath(path, Paint()..color = background);
  }

  @override
  bool shouldRepaint(_PageMask oldDelegate) =>
      pageRect != oldDelegate.pageRect || background != oldDelegate.background;
}
