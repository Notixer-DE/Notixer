import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfPageGeometry;
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart' show PdfRect, PdfPage;
import '../data/ink.dart';
import 'pdf_thumbnail.dart';

/// Cached pressure ribbons: one filled path, not a draw call per sample.
/// Entries are reconstructible and bounded independently of document history.
class InkPathCache {
  static const budget = 16 * 1024 * 1024;
  final _entries = <InkStroke, Path>{};
  int _bytes = 0;
  int builds = 0;
  int debugVectorDraws = 0;
  int _rasterActive = 0;
  bool get debugRasterBusy =>
      _rasterActive > 0 || _rasterQueue.isNotEmpty || _rasterFrame;
  final _rasterQueue = Queue<(bool Function(), VoidCallback)>();
  bool _rasterFrame = false;
  void enqueueRaster(
    bool Function() wanted,
    VoidCallback work, {
    bool urgent = false,
  }) {
    if (urgent) {
      _rasterQueue.addFirst((wanted, work));
    } else {
      _rasterQueue.addLast((wanted, work));
    }
    _requestRasterFrame();
  }

  void _requestRasterFrame() {
    if (_rasterFrame) return;
    _rasterFrame = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _rasterFrame = false;
      final budget = Stopwatch()..start();
      while (_rasterQueue.isNotEmpty) {
        final (wanted, work) = _rasterQueue.removeFirst();
        if (wanted()) {
          work();
          if (budget.elapsedMicroseconds >= 3000) break;
        }
      }
      if (_rasterQueue.isNotEmpty) _requestRasterFrame();
    });
  }

  Path path(InkStroke stroke) {
    final hit = _entries.remove(stroke);
    if (hit != null) {
      _entries[stroke] = hit;
      return hit;
    }
    final path = inkRibbon(stroke);
    builds++;
    final cost = stroke.pointCount * 256 + 256;
    if (cost <= budget) {
      _entries[stroke] = path;
      _bytes += cost;
      while (_bytes > budget) {
        final old = _entries.keys.first;
        _entries.remove(old);
        _bytes -= old.pointCount * 256 + 256;
      }
    }
    return path;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
    _rasterQueue.clear();
  }
}

Path inkRibbon(InkStroke stroke) {
  final points = stroke.points;
  final n = stroke.pointCount;
  double radius(int i) => stroke.width * (.4 + 1.2 * points[i * 3 + 2]) / 2;
  Offset point(int i) => Offset(points[i * 3], points[i * 3 + 1]);
  final path = Path();
  // Each swept segment has the same winding, including reversals and loops.
  // One long outline can reverse its winding at a cusp and cancel itself.
  for (var i = 1; i < n; i++) {
    final a = point(i - 1), b = point(i);
    final tangent = b - a;
    final length = tangent.distance;
    if (length < 1e-6) continue;
    final normal = Offset(-tangent.dy, tangent.dx) / length;
    path.addPolygon([
      a - normal * radius(i - 1),
      b - normal * radius(i),
      b + normal * radius(i),
      a + normal * radius(i - 1),
    ], true);
  }
  for (var i = 0; i < n; i++) {
    // Chunk endpoints are joins too. Their circles share the same filled path
    // when composited, so round joins do not introduce darker alpha seams.
    path.addOval(Rect.fromCircle(center: point(i), radius: radius(i)));
  }
  return path;
}

/// Per-pane live tail. Once 64 samples are finished they move to the tiled
/// preview index. Only the remaining <=65 samples repaint at pointer frequency.
class LiveInk extends ChangeNotifier {
  LiveInk(this.controller);
  final InkController controller;
  final _samples = <double>[];
  final _chunks = <InkStroke>[];
  String? page, id;
  int color = 0xff000000, order = 0;
  double width = 2;
  bool _straight = false;
  Offset? _startDirection;
  bool get active => id != null;
  int get tailPoints => _samples.length ~/ 3;
  InkStroke? get tail => !active || _samples.isEmpty
      ? null
      : _stroke('$id-tail', Float32List.fromList(_samples));
  InkStroke _stroke(
    String key,
    Float32List points, {
    bool capEnd = true,
    Offset? endDirection,
  }) => InkStroke(
    id: key,
    page: page!,
    order: order + _chunks.length,
    color: color,
    width: width,
    points: points,
    group: id,
    capStart: _chunks.isEmpty,
    capEnd: capEnd,
    startDirection: _startDirection,
    endDirection: endDirection,
  );
  void begin(
    String page,
    int color,
    double width, {
    bool straight = false,
    double opacity = 1,
  }) {
    cancel();
    this.page = page;
    final alpha = ((color >> 24) & 0xff) * opacity.clamp(0.0, 1.0);
    this.color = (alpha.round() << 24) | (color & 0xffffff);
    this.width = width;
    _straight = straight;
    id = newInkId();
    order = controller.nextOrder;
  }

  void add(double x, double y, double pressure) {
    if (!active) return;
    if (!x.isFinite ||
        !y.isFinite ||
        !pressure.isFinite ||
        x.abs() > 1e7 ||
        y.abs() > 1e7) {
      return;
    }
    if (_samples.length >= 6 &&
        (Offset(x, y) -
                    Offset(
                      _samples[_samples.length - 3],
                      _samples[_samples.length - 2],
                    ))
                .distance <
            .05 &&
        (pressure - _samples.last).abs() < .01) {
      return;
    }
    if (_straight && _samples.isNotEmpty) {
      final dx = x - _samples[0], dy = y - _samples[1];
      _samples.length = 3;
      _samples.addAll(
        dx.abs() >= dy.abs()
            ? [x, _samples[1], pressure]
            : [_samples[0], y, pressure],
      );
      notifyListeners();
      return;
    }
    _samples.addAll([x, y, pressure]);
    if (tailPoints > 65) {
      final end = 64 * 3;
      final key = '$id-${_chunks.length}';
      final direction = Offset(
        _samples[end] - _samples[end - 6],
        _samples[end + 1] - _samples[end - 5],
      );
      final chunk = _stroke(
        key,
        Float32List.fromList(_samples.sublist(0, end)),
        capEnd: false,
        endDirection: direction,
      );
      // Translucent chunks and the tail must be composited together. Otherwise
      // their shared boundary darkens while the stroke is still being drawn.
      if (color >> 24 == 255) controller.showPreview(chunk);
      _chunks.add(chunk);
      _samples.removeRange(0, end - 3);
      _startDirection = direction;
    }
    notifyListeners();
  }

  void finish() {
    try {
      if (active && _samples.isNotEmpty) {
        final stroke = _stroke(
          '$id-${_chunks.length}',
          Float32List.fromList(_samples),
        );
        controller.apply(InkEdit(add: [..._chunks, stroke]));
      }
    } finally {
      cancel();
    }
  }

  void cancel() {
    controller.clearPreview(_chunks.map((s) => s.id));
    _chunks.clear();
    _samples.clear();
    _startDirection = null;
    id = null;
    _straight = false;
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

void _pageTransform(Canvas canvas, PdfPageGeometry geometry) {
  final o = geometry.toViewOffset(0, 0),
      x = geometry.toViewOffset(1, 0),
      y = geometry.toViewOffset(0, 1);
  canvas.transform(
    Float64List.fromList([
      x.dx - o.dx,
      x.dy - o.dy,
      0,
      0,
      y.dx - o.dx,
      y.dy - o.dy,
      0,
      0,
      0,
      0,
      1,
      0,
      o.dx,
      o.dy,
      0,
      1,
    ]),
  );
}

class InkLayer extends StatelessWidget {
  const InkLayer({
    super.key,
    required this.controller,
    required this.page,
    required this.geometry,
    required this.visible,
    required this.cache,
    this.live,
    this.rasterScale = 1,
    this.continuous = false,
  });
  final InkController controller;
  final String page;
  final PdfPageGeometry geometry;

  /// Normalized, view-space region (including the outer viewer transform).
  final Rect visible;
  final InkPathCache cache;
  final LiveInk? live;

  /// Scale applied outside the PDF page layout (pinch zoom).
  final double rasterScale;

  /// Paint the visible ink together when independently clipped tiles would
  /// meet at fractional viewport coordinates.
  final bool continuous;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ListenableBuilder(
      listenable: controller.pageChanges(page),
      builder: (context, _) {
        if (!geometry.scale.isFinite ||
            geometry.scale <= 0 ||
            !geometry.viewSize.isFinite) {
          return const SizedBox.shrink();
        }
        final viewRect = Rect.fromLTRB(
          visible.left * geometry.viewSize.width,
          visible.top * geometry.viewSize.height,
          visible.right * geometry.viewSize.width,
          visible.bottom * geometry.viewSize.height,
        );
        final region = geometry.toPageRect(viewRect);
        final bounds = Rect.fromLTRB(
          region.left,
          region.bottom,
          region.right,
          region.top,
        );
        if (bounds.isEmpty || !bounds.isFinite) return const SizedBox.shrink();
        final overlay = live == null
            ? const SizedBox.shrink()
            : Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _LivePainter(live!, geometry, page, cache),
                  ),
                ),
              );
        if (continuous) {
          return Stack(
            children: [
              Positioned.fromRect(
                rect: viewRect,
                child: _InkTile(
                  controller: controller,
                  page: page,
                  bounds: bounds,
                  geometry: geometry,
                  origin: viewRect.topLeft,
                  viewSize: viewRect.size,
                  cache: cache,
                  pixelRatio: MediaQuery.devicePixelRatioOf(context),
                  vectorOnly: true,
                ),
              ),
              if (live != null) overlay,
            ],
          );
        }
        final viewportLevel =
            (math.log(
                      math.max(bounds.width, bounds.height) /
                          (InkIndex.cellSize * 8),
                    ) /
                    math.ln2)
                .ceil();
        final pixelLevel =
            (math.log(
                      256 /
                          (geometry.scale *
                              rasterScale *
                              MediaQuery.devicePixelRatioOf(context) *
                              InkIndex.cellSize),
                    ) /
                    math.ln2)
                .floor();
        final level = math.max(viewportLevel, pixelLevel);
        final tileSize = InkIndex.cellSize * math.pow(2, level);
        // At most 32 MiB of owned tile images per visible page, independent of
        // zoom/DPR. The stroke model remains vector data.
        final ratio = math.min(
          MediaQuery.devicePixelRatioOf(context) * rasterScale,
          math.sqrt(
            32 *
                1024 *
                1024 /
                (4 * 81 * math.pow(tileSize * geometry.scale, 2)),
          ),
        );
        return Stack(
          children: [
            for (
              var y = (bounds.top / tileSize).floor();
              y <= (bounds.bottom / tileSize).floor();
              y++
            )
              for (
                var x = (bounds.left / tileSize).floor();
                x <= (bounds.right / tileSize).floor();
                x++
              )
                _tile(
                  x,
                  y,
                  tileSize,
                  level,
                  ratio,
                  MediaQuery.devicePixelRatioOf(context) * rasterScale,
                  ratio <
                      MediaQuery.devicePixelRatioOf(context) *
                          rasterScale *
                          .99,
                ),
            if (live != null) overlay,
          ],
        );
      },
    ),
  );

  Widget _tile(
    int x,
    int y,
    double tileSize,
    int level,
    double pixelRatio,
    double gridScale,
    bool vectorOnly,
  ) {
    final bounds = Rect.fromLTWH(
      x * tileSize,
      y * tileSize,
      tileSize,
      tileSize,
    );
    final view = geometry.toViewRect(
      PdfRect(bounds.left, bounds.top, bounds.right, bounds.bottom),
    );
    // Adjacent tiles must own exactly the same device-pixel boundary.
    double snap(double value) => (value * gridScale).round() / gridScale;
    final rect = Rect.fromLTRB(
      snap(view.left),
      snap(view.top),
      snap(view.right),
      snap(view.bottom),
    );
    if (rect.isEmpty) return const SizedBox.shrink();
    return Positioned.fromRect(
      key: ValueKey((page, x, y, level)),
      rect: rect,
      child: _InkTile(
        controller: controller,
        page: page,
        bounds: bounds,
        geometry: geometry,
        origin: rect.topLeft,
        viewSize: rect.size,
        cache: cache,
        pixelRatio: pixelRatio,
        vectorOnly: vectorOnly,
      ),
    );
  }
}

class _InkTile extends StatefulWidget {
  const _InkTile({
    required this.controller,
    required this.page,
    required this.bounds,
    required this.geometry,
    required this.origin,
    required this.viewSize,
    required this.cache,
    required this.pixelRatio,
    required this.vectorOnly,
  });
  final InkController controller;
  final String page;
  final Rect bounds;
  final PdfPageGeometry geometry;
  final Offset origin;
  final Size viewSize;
  final InkPathCache cache;
  final double pixelRatio;
  final bool vectorOnly;
  @override
  State<_InkTile> createState() => _InkTileState();
}

class _InkTileState extends State<_InkTile> {
  int? _revision;
  List<InkStroke> _strokes = [];
  final _pending = <InkStroke>[];
  ui.Image? _image;
  int _epoch = 0;
  bool _rendering = false, _scheduled = false, _failed = false;

  void _releaseImage() {
    final old = _image;
    _image = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void didUpdateWidget(_InkTile old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller ||
        old.bounds != widget.bounds ||
        old.origin != widget.origin ||
        old.viewSize != widget.viewSize ||
        old.geometry.viewSize != widget.geometry.viewSize ||
        old.geometry.rotation != widget.geometry.rotation ||
        old.geometry.cropBox != widget.geometry.cropBox ||
        (old.pixelRatio - widget.pixelRatio).abs() > .01) {
      _epoch++;
      _revision = null;
      _releaseImage();
      _pending.clear();
      _strokes = [];
      _failed = false;
    }
  }

  void _scheduleRaster() {
    if (widget.vectorOnly ||
        _scheduled ||
        _rendering ||
        _failed ||
        _pending.isEmpty) {
      return;
    }
    _scheduled = true;
    widget.cache.enqueueRaster(() => mounted, () {
      _scheduled = false;
      if (mounted) _rasterize();
    }, urgent: _image != null);
  }

  Future<void> _rasterize() async {
    if (widget.vectorOnly || _rendering || _pending.isEmpty) return;
    _rendering = true;
    widget.cache._rasterActive++;
    final rasterCache = widget.cache;
    final epoch = _epoch;
    var count = math.min(64, _pending.length);
    // Never split one translucent physical stroke across raster batches.
    while (count < _pending.length &&
        _pending[count - 1].group == _pending[count].group &&
        _pending[count - 1].color == _pending[count].color) {
      count++;
    }
    final batch = _pending.take(count).toList();
    final held = _image?.clone();
    final size = widget.viewSize;
    final width = math.max(1, (size.width * widget.pixelRatio).round());
    final height = math.max(1, (size.height * widget.pixelRatio).round());
    // Keep a one-pixel gutter so bilinear sampling at an internal tile edge
    // reads neighbouring ink instead of transparent pixels outside the image.
    final scaleX = width / size.width, scaleY = height / size.height;
    final gutter = Offset(1 / scaleX, 1 / scaleY);
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    try {
      final canvas = Canvas(recorder)
        ..scale(scaleX, scaleY)
        ..translate(gutter.dx, gutter.dy);
      if (held != null) {
        canvas.drawImageRect(
          held,
          Rect.fromLTWH(0, 0, held.width.toDouble(), held.height.toDouble()),
          Rect.fromLTWH(
            -gutter.dx,
            -gutter.dy,
            size.width + 2 * gutter.dx,
            size.height + 2 * gutter.dy,
          ),
          Paint(),
        );
      }
      _paintTileStrokes(
        canvas,
        widget.geometry,
        widget.origin,
        widget.cache,
        batch,
      );
      picture = recorder.endRecording();
      final image = await picture.toImage(width + 2, height + 2);
      if (!mounted || epoch != _epoch) {
        image.dispose();
        return;
      }
      final painted = batch.toSet();
      setState(() {
        _releaseImage();
        _image = image;
        _pending.removeWhere(painted.contains);
      });
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _failed = true;
        });
      }
    } finally {
      picture?.dispose();
      held?.dispose();
      _rendering = false;
      rasterCache._rasterActive--;
      if (mounted) _scheduleRaster();
    }
  }

  @override
  Widget build(BuildContext context) {
    final queryBounds = widget.bounds.inflate(
      2 / (widget.geometry.scale * widget.pixelRatio),
    );
    final revision = widget.controller.areaRevision(widget.page, queryBounds);
    if (_revision != revision) {
      _revision = revision;
      final unique = <String, InkStroke>{
        for (final s in [
          ...widget.controller.index
              .query(widget.page, queryBounds)
              .where((s) => !widget.controller.hidden.contains(s.id)),
          ...widget.controller.preview.query(widget.page, queryBounds),
        ])
          s.id: s,
      };
      final next = unique.values.toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      final append =
          next.length >= _strokes.length &&
          Iterable<int>.generate(
            _strokes.length,
          ).every((i) => identical(next[i], _strokes[i]));
      if (append) {
        final added = next.skip(_strokes.length).toList();
        _pending.addAll(added);
      } else {
        _epoch++;
        _releaseImage();
        _pending
          ..clear()
          ..addAll(next);
      }
      _strokes = next;
    }
    if (!widget.vectorOnly) _scheduleRaster();
    return RepaintBoundary(
      child: ClipRect(
        child: CustomPaint(
          painter: _TilePainter(
            widget.vectorOnly ? List.of(_strokes) : List.of(_pending),
            widget.geometry,
            widget.origin,
            widget.cache,
            revision,
            widget.vectorOnly ? null : _image,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _epoch++;
    _image?.dispose();
    super.dispose();
  }
}

void _paintTileStrokes(
  Canvas canvas,
  PdfPageGeometry geometry,
  Offset origin,
  InkPathCache cache,
  List<InkStroke> strokes,
) {
  assert(() {
    cache.debugVectorDraws += strokes.length;
    return true;
  }());
  canvas.save();
  canvas.translate(-origin.dx, -origin.dy);
  _pageTransform(canvas, geometry);
  for (var i = 0; i < strokes.length;) {
    final first = strokes[i++];
    final path = Path()..addPath(cache.path(first), Offset.zero);
    while (i < strokes.length &&
        strokes[i].group == first.group &&
        strokes[i].color == first.color) {
      path.addPath(cache.path(strokes[i++]), Offset.zero);
    }
    canvas.drawPath(path, Paint()..color = Color(first.color));
  }
  canvas.restore();
}

class _TilePainter extends CustomPainter {
  _TilePainter(
    this.strokes,
    this.geometry,
    this.origin,
    this.cache,
    this.revision,
    this.image,
  );
  final List<InkStroke> strokes;
  final PdfPageGeometry geometry;
  final Offset origin;
  final InkPathCache cache;
  final int revision;
  final ui.Image? image;
  @override
  void paint(Canvas canvas, Size size) {
    if (image != null) {
      canvas.drawImageRect(
        image!,
        Rect.fromLTWH(1, 1, image!.width - 2.0, image!.height - 2.0),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    _paintTileStrokes(canvas, geometry, origin, cache, strokes);
  }

  @override
  bool shouldRepaint(_TilePainter old) =>
      old.revision != revision ||
      old.image != image ||
      old.strokes.length != strokes.length ||
      old.geometry.viewSize != geometry.viewSize ||
      old.geometry.cropBox != geometry.cropBox ||
      old.geometry.rotation != geometry.rotation ||
      old.origin != origin;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.live, this.geometry, this.page, this.cache)
    : super(repaint: live);
  final LiveInk live;
  final InkPathCache cache;
  final PdfPageGeometry geometry;
  final String page;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = live.tail;
    if (stroke == null || stroke.page != page) return;
    _pageTransform(canvas, geometry);
    final path = Path();
    if (stroke.color >> 24 != 255) {
      for (final chunk in live._chunks) {
        path.addPath(cache.path(chunk), Offset.zero);
      }
    }
    path.addPath(inkRibbon(stroke), Offset.zero);
    canvas.drawPath(path, Paint()..color = Color(stroke.color));
  }

  @override
  bool shouldRepaint(_LivePainter old) =>
      old.geometry != geometry || old.live != live;
}

/// Thumbnails and the writing loupe use the same stroke model/cache as the
/// canvas; no PDF snapshot is generated to update a preview.
class InkPagePreview extends StatelessWidget {
  const InkPagePreview({
    super.key,
    required this.page,
    required this.pageId,
    required this.controller,
    required this.cache,
  });
  final PdfPage page;
  final String pageId;
  final InkController controller;
  final InkPathCache cache;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AspectRatio(
      aspectRatio: page.rotation % 180 == 0
          ? page.cropBox.width / page.cropBox.height
          : page.cropBox.height / page.cropBox.width,
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          fit: StackFit.expand,
          children: [
            PdfThumbnail(page: page),
            InkLayer(
              controller: controller,
              page: pageId,
              cache: cache,
              geometry: PdfPageGeometry(
                cropBox: page.cropBox,
                rotation: page.rotation,
                viewSize: c.biggest,
              ),
              visible: const Rect.fromLTWH(0, 0, 1, 1),
            ),
          ],
        ),
      ),
    ),
  );
}
