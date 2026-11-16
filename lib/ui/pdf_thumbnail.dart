import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageView;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf_document/pdf_document.dart' show PdfPage;

/// Standalone page views need the visibility updates that PdfViewer normally
/// supplies. A sliver can lay out a thumbnail offscreen and then scroll it into
/// view without rebuilding it; its initial, skipped render must be woken then.
class PdfThumbnail extends StatefulWidget {
  const PdfThumbnail({super.key, required this.page});
  final PdfPage page;

  @override
  State<PdfThumbnail> createState() => _PdfThumbnailState();
}

class _PdfThumbnailState extends State<PdfThumbnail> {
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  Animation<double>? _routeAnimation;
  bool _visible = false, _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    final position = scrollable?.position;
    if (_position != position) {
      _position?.removeListener(_scheduleVisibility);
      _position = position;
      _position?.addListener(_scheduleVisibility);
    }
    _scrollable = scrollable;
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeListener(_scheduleVisibility);
      _routeAnimation = animation;
      _routeAnimation?.addListener(_scheduleVisibility);
    }
    // Register for window changes as well as scroll and route movement.
    MediaQuery.sizeOf(context);
    _scheduleVisibility();
  }

  void _scheduleVisibility() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      // Keyed children may temporarily have no sliver position during reorder.
      RenderObject? ancestor = box;
      while (ancestor != null) {
        final data = ancestor.parentData;
        if (data is SliverMultiBoxAdaptorParentData &&
            data.layoutOffset == null) {
          return;
        }
        ancestor = ancestor.parent;
      }
      var viewport = Offset.zero & MediaQuery.sizeOf(context);
      final scrollBox = _scrollable?.context.findRenderObject();
      if (scrollBox is RenderBox && scrollBox.attached && scrollBox.hasSize) {
        viewport = viewport.intersect(
          MatrixUtils.transformRect(
            scrollBox.getTransformTo(null),
            Offset.zero & scrollBox.size,
          ),
        );
      }
      final bounds = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      final visible = !viewport.isEmpty && bounds.overlaps(viewport);
      if (visible != _visible) setState(() => _visible = visible);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleVisibility);
    _routeAnimation?.removeListener(_scheduleVisibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _scheduleVisibility();
      return PdfPageView(page: widget.page, onScreen: _visible);
    },
  );
}
