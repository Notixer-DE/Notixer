import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';

/// Anchor text actions to the selected glyphs, clamped inside this pane. The
/// overlay never changes page layout and follows scrolling/zoom independently.
class NoterTextSelectionOverlay extends StatefulWidget {
  const NoterTextSelectionOverlay({
    super.key,
    required this.viewer,
    required this.editing,
  });
  final PdfViewerController viewer;
  final PdfEditingController editing;
  @override
  State<NoterTextSelectionOverlay> createState() =>
      _NoterTextSelectionOverlayState();
}

class _NoterTextSelectionOverlayState extends State<NoterTextSelectionOverlay> {
  final _bounds = GlobalKey();
  @override
  Widget build(BuildContext context) => SizedBox.expand(
    key: _bounds,
    child: LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<Rect?>(
        valueListenable: widget.viewer.selectionGlobalRect,
        builder: (context, rect, _) {
          if (rect == null) return const SizedBox.shrink();
          final box = _bounds.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return const SizedBox.shrink();
          final local = rect.shift(-box.localToGlobal(Offset.zero));
          final width = (constraints.maxWidth - 16).clamp(0.0, 548.0);
          final height = NoterTheme.desktopControls(context) ? 44.0 : 56.0;
          final maximumTop = (constraints.maxHeight - height - 8).clamp(
            0.0,
            double.infinity,
          );
          final below = local.bottom + 12;
          final top = (below <= maximumTop ? below : local.top - height - 12)
              .clamp(0.0, maximumTop);
          final left = (local.center.dx - width / 2).clamp(
            8.0,
            (constraints.maxWidth - width - 8).clamp(8.0, double.infinity),
          );
          return Stack(
            children: [
              Positioned(
                top: top,
                left: left,
                width: width,
                height: height,
                child: NoterTextSelectionToolbar(
                  viewer: widget.viewer,
                  editing: widget.editing,
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Retain native selection handles and annotation menus, but replace the
/// package's touch-only text chip with our shared mouse/touch palette.
class NoterTextSelectionPresenter extends PdfEditorPresenter {
  const NoterTextSelectionPresenter();

  @override
  Widget actionBar(BuildContext context, PdfActionBarRequest request) =>
      request.kind == PdfActionBarKind.textSelection
      ? const SizedBox.shrink()
      : super.actionBar(context, request);
}

/// Actions operate on PDF glyph rectangles, never on a freehand stroke.
/// Kept over the viewport so selecting text does not shift the document.
class NoterTextSelectionToolbar extends StatelessWidget {
  const NoterTextSelectionToolbar({
    super.key,
    required this.viewer,
    required this.editing,
  });

  final PdfViewerController viewer;
  final PdfEditingController editing;

  void _mark(PdfMarkupKind kind, Color color) {
    // Capture before the document mutation clears the viewer's selection.
    final quads = {
      for (final page in viewer.selectionPages)
        page: viewer.selectionRectsOn(page),
    };
    if (quads.values.every((rects) => rects.isEmpty)) return;
    final previousColor = editing.color;
    final previousOpacity = editing.preferences.opacity;
    try {
      editing.color = color;
      editing.preferences.opacity = kind == PdfMarkupKind.highlight ? .35 : 1;
      editing.addMarkup(kind, quads);
    } finally {
      // A text-markup choice must not recolor the user's pen or favorites.
      editing.color = previousColor;
      editing.preferences.opacity = previousOpacity;
    }
    viewer.clearSelection();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([viewer, editing]),
    builder: (context, _) {
      if (!viewer.hasSelection ||
          (editing.tool != null && editing.tool != PdfEditTool.select)) {
        return const SizedBox.shrink();
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          key: const ValueKey('noter-text-selection-toolbar'),
          elevation: 2,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: const BorderSide(color: NoterTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: WorkspaceToolbar(
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (kind, label, icon) in const [
                          (PdfMarkupKind.highlight, 'Markieren', Icons.title),
                          (
                            PdfMarkupKind.underline,
                            'Unterstreichen',
                            Icons.format_underlined,
                          ),
                          (
                            PdfMarkupKind.strikeOut,
                            'Durchstreichen',
                            Icons.format_strikethrough,
                          ),
                        ]) ...[
                          for (final (color, name) in const [
                            (NoterTheme.markupPink, 'Rosa'),
                            (NoterTheme.markupYellow, 'Gelb'),
                            (NoterTheme.markupBlue, 'Blau'),
                            (NoterTheme.markupGreen, 'Grün'),
                            (Color(0xFF169FB8), 'Türkis'),
                          ])
                            IconButton(
                              tooltip: '$label · $name',
                              onPressed: () => _mark(kind, color),
                              icon: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: .8),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: NoterTheme.border),
                                ),
                                child: Icon(
                                  icon,
                                  color: NoterTheme.ink,
                                  size: 17,
                                ),
                              ),
                            ),
                          const SizedBox(
                            height: 24,
                            child: VerticalDivider(width: 1),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Text kopieren',
                  onPressed: viewer.copySelection,
                  icon: const Icon(Icons.copy, size: 20),
                ),
                IconButton(
                  tooltip: 'Textauswahl aufheben',
                  onPressed: viewer.clearSelection,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
