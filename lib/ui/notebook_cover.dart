import 'package:flutter/material.dart';
import 'noter_theme.dart';

/// A paper-type cover, not a document thumbnail. The library stays metadata-only:
/// no PDF needs to be opened or rendered while scrolling through notebooks.
class NotebookCover extends StatelessWidget {
  const NotebookCover({super.key, required this.paper, this.height = 136});

  final String paper;
  final double height;

  String get label => switch (paper) {
    'pdf' => 'PDF',
    'lined' => 'Ruled',
    'grid' => 'Grid',
    _ => 'Blank',
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Paper type: $label',
      child: ExcludeSemantics(
        child: Container(
          height: height,
          color: NoterTheme.workspace,
          child: Stack(
            children: [
              Center(
                child: Container(
                  width: 100,
                  height: 116,
                  margin: const EdgeInsets.only(top: 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: NoterTheme.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: paper == 'pdf'
                      ? const Icon(
                          Icons.picture_as_pdf_outlined,
                          color: NoterTheme.accent,
                          size: 36,
                        )
                      : CustomPaint(painter: _PaperPainter(paper)),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaperPainter extends CustomPainter {
  const _PaperPainter(this.paper);
  final String paper;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = NoterTheme.border
      ..strokeWidth = .7;
    if (paper == 'lined' || paper == 'grid') {
      for (double y = 16; y < size.height; y += 10) {
        canvas.drawLine(Offset(10, y), Offset(size.width - 10, y), paint);
      }
    }
    if (paper == 'grid') {
      for (double x = 10; x <= size.width - 10; x += 10) {
        canvas.drawLine(Offset(x, 6), Offset(x, size.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPainter oldDelegate) =>
      oldDelegate.paper != paper;
}
