import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pdf_document/pdf_document.dart';

String newInkId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${math.Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

/// Page indices change on reorder/delete. Indirect references survive those
/// edits and undo; a copied page has a new reference and a separate identity.
String inkPageId(PdfDocument document, int page) {
  final ref = document.cos.referenceTo(document.page(page).dict);
  if (ref == null) {
    throw StateError('The PDF page has no stable identity.');
  }
  return '${ref.objectNumber}:${ref.generation}';
}

class InkStroke {
  InkStroke({
    required this.id,
    required this.page,
    required this.order,
    required this.color,
    required this.width,
    required Float32List points,
    String? group,
    this.capStart = true,
    this.capEnd = true,
    this.startDirection,
    this.endDirection,
  }) : group = group ?? id,
       points = Float32List.fromList(points).asUnmodifiableView() {
    if (id.isEmpty ||
        this.group.isEmpty ||
        this.group.length > 150 ||
        id.length > 150 ||
        !RegExp(r'^\d+:\d+$').hasMatch(page) ||
        order < 0 ||
        color < 0 ||
        color > 0xffffffff ||
        !width.isFinite ||
        width <= 0 ||
        width > 1000 ||
        points.isEmpty ||
        points.length % 3 != 0 ||
        points.length > 3 * InkDocument.maxPoints) {
      throw const FormatException('Invalid ink stroke.');
    }
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (var i = 0; i < points.length; i += 3) {
      final x = points[i], y = points[i + 1], p = points[i + 2];
      if (!x.isFinite ||
          !y.isFinite ||
          x.abs() > 1e7 ||
          y.abs() > 1e7 ||
          !p.isFinite ||
          p < 0 ||
          p > 1) {
        throw const FormatException('Invalid ink point.');
      }
      left = math.min(left, x);
      top = math.min(top, y);
      right = math.max(right, x);
      bottom = math.max(bottom, y);
    }
    bounds = Rect.fromLTRB(left, top, right, bottom).inflate(width);
  }

  final String id, page;
  final String group;
  final bool capStart, capEnd;
  final Offset? startDirection, endDirection;
  final int order, color;
  final double width;

  /// Packed x, y, normalized pressure. No object per sample.
  final Float32List points;
  late final Rect bounds;
  int get pointCount => points.length ~/ 3;

  InkStroke transform({
    String? id,
    String? page,
    int? order,
    String? group,
    int? color,
    double? width,
    Offset origin = Offset.zero,
    double scale = 1,
    double scaleX = 1,
    double scaleY = 1,
    double rotation = 0,
    Offset delta = Offset.zero,
  }) {
    if (![scale, scaleX, scaleY].every((v) => v.isFinite && v > 0) ||
        !rotation.isFinite ||
        !origin.dx.isFinite ||
        !origin.dy.isFinite ||
        !delta.dx.isFinite ||
        !delta.dy.isFinite) {
      throw ArgumentError('Invalid ink transformation.');
    }
    final moved = Float32List(points.length);
    final cosine = math.cos(rotation), sine = math.sin(rotation);
    for (var i = 0; i < points.length; i += 3) {
      final x = (points[i] - origin.dx) * scale * scaleX;
      final y = (points[i + 1] - origin.dy) * scale * scaleY;
      moved[i] = origin.dx + x * cosine - y * sine + delta.dx;
      moved[i + 1] = origin.dy + x * sine + y * cosine + delta.dy;
      moved[i + 2] = points[i + 2];
    }
    Offset? direction(Offset? value) {
      if (value == null) return null;
      final x = value.dx * scaleX;
      final y = value.dy * scaleY;
      final direction = Offset(x * cosine - y * sine, x * sine + y * cosine);
      return direction / direction.distance;
    }

    return InkStroke(
      id: id ?? this.id,
      page: page ?? this.page,
      order: order ?? this.order,
      group: group ?? this.group,
      capStart: capStart,
      capEnd: capEnd,
      startDirection: direction(startDirection),
      endDirection: direction(endDirection),
      color: color ?? this.color,
      width: (width ?? this.width) * scale * math.sqrt(scaleX * scaleY),
      points: moved,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'page': page,
    'order': order,
    'color': color,
    'width': width,
    'points': points.toList(),
    if (group != id) 'group': group,
    if (!capStart) 'capStart': false,
    if (!capEnd) 'capEnd': false,
    if (startDirection != null)
      'startDirection': [startDirection!.dx, startDirection!.dy],
    if (endDirection != null)
      'endDirection': [endDirection!.dx, endDirection!.dy],
  };

  factory InkStroke.fromJson(Map<String, dynamic> json) => InkStroke(
    id: json['id'] as String,
    page: json['page'] as String,
    order: json['order'] as int,
    color: json['color'] as int,
    width: (json['width'] as num).toDouble(),
    points: Float32List.fromList(
      (json['points'] as List).map((p) => (p as num).toDouble()).toList(),
    ),
    group: json['group'] as String?,
    capStart: json['capStart'] as bool? ?? true,
    capEnd: json['capEnd'] as bool? ?? true,
    startDirection: _inkDirection(json['startDirection']),
    endDirection: _inkDirection(json['endDirection']),
  );
}

Offset? _inkDirection(dynamic value) {
  if (value == null) return null;
  final list = value as List;
  if (list.length != 2) {
    throw const FormatException('Invalid stroke direction.');
  }
  final direction = Offset(
    (list[0] as num).toDouble(),
    (list[1] as num).toDouble(),
  );
  if (!direction.isFinite ||
      direction.dx.abs() > 1e7 ||
      direction.dy.abs() > 1e7) {
    throw const FormatException('Invalid stroke direction.');
  }
  return direction;
}

class InkDocument {
  InkDocument({
    required this.generation,
    this.sequence = 0,
    Iterable<InkStroke> strokes = const [],
  }) : strokes = List.unmodifiable(strokes);
  final String generation;
  final int sequence;
  final List<InkStroke> strokes;
  static const maxBytes = 64 * 1024 * 1024;
  static const maxPoints = 2000000;
  static const maxStrokes = 100000;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'generation': generation,
        'sequence': sequence,
        'strokes': [for (final s in strokes) s.toJson()],
      }),
    ),
  );

  factory InkDocument.decode(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException(
        'The ink layer is too large (maximum 64 MB).',
      );
    }
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['version'] != 1 ||
          json['generation'] is! String ||
          (json['generation'] as String).isEmpty ||
          (json['generation'] as String).length > 150 ||
          json['sequence'] is! int ||
          (json['sequence'] as int) < 0) {
        throw const FormatException('Unknown ink layer.');
      }
      final raw = json['strokes'] as List;
      if (raw.length > maxStrokes) {
        throw const FormatException('Too many strokes.');
      }
      final strokes = <InkStroke>[];
      final ids = <String>{};
      var points = 0;
      for (final entry in raw) {
        final s = InkStroke.fromJson(entry as Map<String, dynamic>);
        points += s.pointCount;
        if (!ids.add(s.id) || points > maxPoints) {
          throw const FormatException('Invalid ink layer.');
        }
        strokes.add(s);
      }
      return InkDocument(
        generation: json['generation'] as String,
        sequence: json['sequence'] as int,
        strokes: strokes,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Corrupted ink layer.');
    }
  }
}

/// A small journal record, also the inverse needed by undo. Immutable strokes
/// are shared with history; ordinary drawing never copies the document.
class InkEdit {
  InkEdit({
    Iterable<InkStroke> add = const [],
    Iterable<InkStroke> remove = const [],
  }) : add = List.unmodifiable(add),
       remove = List.unmodifiable(remove);
  final List<InkStroke> add, remove;
  late final int estimatedBytes = [
    ...add,
    ...remove,
  ].fold<int>(64, (bytes, s) => bytes + s.points.lengthInBytes + 192);
  InkEdit get inverse => InkEdit(add: remove, remove: add);
  Map<String, Object> toJson() => {
    'add': [for (final s in add) s.toJson()],
    'remove': [for (final s in remove) s.id],
  };
}

/// Spatial index with a bounded insertion cost even for page-spanning strokes.
class InkIndex {
  static const cellSize = 128.0;
  final _strokes = <String, InkStroke>{};
  final _cells = <String, Map<(int, int), Set<String>>>{};
  final _large = <String, Set<String>>{};
  final _groups = <String, Set<String>>{};
  Iterable<InkStroke> get strokes => _strokes.values;
  InkStroke? operator [](String id) => _strokes[id];
  Iterable<InkStroke> group(String id) =>
      (_groups[id] ?? const <String>{}).map((id) => _strokes[id]!);

  static Iterable<(int, int)> cells(Rect bounds) sync* {
    for (
      var y = (bounds.top / cellSize).floor();
      y <= (bounds.bottom / cellSize).floor();
      y++
    ) {
      for (
        var x = (bounds.left / cellSize).floor();
        x <= (bounds.right / cellSize).floor();
        x++
      ) {
        yield (x, y);
      }
    }
  }

  bool _isLarge(Rect r) =>
      ((r.width / cellSize).ceil() + 1) * ((r.height / cellSize).ceil() + 1) >
      64;

  void add(InkStroke stroke) {
    remove(stroke.id);
    _strokes[stroke.id] = stroke;
    (_groups[stroke.group] ??= {}).add(stroke.id);
    if (_isLarge(stroke.bounds)) {
      (_large[stroke.page] ??= {}).add(stroke.id);
    } else {
      final page = _cells[stroke.page] ??= {};
      for (final cell in cells(stroke.bounds)) {
        (page[cell] ??= {}).add(stroke.id);
      }
    }
  }

  InkStroke? remove(String id) {
    final stroke = _strokes.remove(id);
    if (stroke == null) return null;
    final group = _groups[stroke.group];
    group?.remove(id);
    if (group?.isEmpty == true) _groups.remove(stroke.group);
    if (_isLarge(stroke.bounds)) {
      _large[stroke.page]?.remove(id);
    } else {
      for (final cell in cells(stroke.bounds)) {
        final bucket = _cells[stroke.page]?[cell];
        bucket?.remove(id);
        if (bucket?.isEmpty == true) _cells[stroke.page]?.remove(cell);
      }
    }
    return stroke;
  }

  List<InkStroke> query(String page, Rect bounds) {
    final ids = <String>{...?_large[page]};
    // A whole-page query must not enumerate millions of empty grid cells.
    if (_isLarge(bounds)) {
      for (final bucket in _cells[page]?.values ?? <Set<String>>[]) {
        ids.addAll(bucket);
      }
    } else {
      for (final cell in cells(bounds)) {
        ids.addAll(_cells[page]?[cell] ?? const {});
      }
    }
    return [
      for (final id in ids)
        if (_strokes[id] case final s? when s.bounds.overlaps(bounds)) s,
    ]..sort((a, b) => a.order.compareTo(b.order));
  }
}

class InkController extends ChangeNotifier {
  InkController(InkDocument document)
    : generation = document.generation,
      sequence = document.sequence {
    for (final s in document.strokes) {
      index.add(s);
      _points += s.pointCount;
      nextOrder = math.max(nextOrder, s.order + 1);
    }
  }
  final String generation;
  int sequence, nextOrder = 0;
  int _points = 0;
  final index = InkIndex();
  final preview = InkIndex();
  final hidden = <String>{};
  final selected = <String>{};
  final _pages = <String, ValueNotifier<int>>{};
  final _tiles = <(String, int, int), int>{};
  final _pageEpochs = <String, int>{};
  void Function(InkEdit)? onEdit;
  ValueListenable<int> pageChanges(String page) =>
      _pages.putIfAbsent(page, () => ValueNotifier(0));
  int tileRevision(String page, int x, int y) =>
      ((_pageEpochs[page] ?? 0) << 32) + (_tiles[(page, x, y)] ?? 0);
  int areaRevision(String page, Rect bounds) {
    if ((bounds.width / InkIndex.cellSize + 2) *
            (bounds.height / InkIndex.cellSize + 2) >
        256) {
      return _pages[page]?.value ?? 0;
    }
    var revision = (_pageEpochs[page] ?? 0) << 32;
    for (final c in InkIndex.cells(bounds)) {
      revision += _tiles[(page, c.$1, c.$2)] ?? 0;
    }
    return revision;
  }

  InkDocument snapshot() => InkDocument(
    generation: generation,
    sequence: sequence,
    strokes: index.strokes,
  );

  void _invalidate(Iterable<InkStroke> strokes) {
    final pages = <String>{};
    for (final s in strokes) {
      pages.add(s.page);
      // Clamp to page-sized work for malicious/unusually large bounds.
      if ((s.bounds.width / InkIndex.cellSize + 2) *
              (s.bounds.height / InkIndex.cellSize + 2) >
          256) {
        _pageEpochs[s.page] = (_pageEpochs[s.page] ?? 0) + 1;
      } else {
        for (final c in InkIndex.cells(s.bounds)) {
          final key = (s.page, c.$1, c.$2);
          _tiles[key] = (_tiles[key] ?? 0) + 1;
        }
      }
    }
    for (final page in pages) {
      final notifier = _pages[page];
      if (notifier != null) notifier.value++;
    }
  }

  void apply(InkEdit edit) {
    if (edit.add.map((s) => s.id).toSet().length != edit.add.length) {
      throw const FormatException('Duplicate stroke identity.');
    }
    var count = index.strokes.length;
    var points = _points;
    final removed = {for (final s in edit.remove) s.id};
    for (final id in removed) {
      final old = index[id];
      if (old != null) {
        count--;
        points -= old.pointCount;
      }
    }
    for (final s in edit.add) {
      final old = removed.contains(s.id) ? null : index[s.id];
      if (old != null) {
        points -= old.pointCount;
      } else {
        count++;
      }
      points += s.pointCount;
    }
    if (count > InkDocument.maxStrokes || points > InkDocument.maxPoints) {
      throw StateError('The ink layer is full. Please create a new note.');
    }
    _points = points;
    for (final s in edit.remove) {
      index.remove(s.id);
      selected.remove(s.id);
    }
    for (final s in edit.add) {
      index.add(s);
      nextOrder = math.max(nextOrder, s.order + 1);
    }
    sequence++;
    _invalidate([...edit.remove, ...edit.add]);
    onEdit?.call(edit);
    notifyListeners();
  }

  void showPreview(InkStroke stroke) {
    preview.add(stroke);
    _invalidate([stroke]);
  }

  void hide(InkStroke stroke, bool value) {
    if (value) {
      hidden.add(stroke.id);
    } else {
      hidden.remove(stroke.id);
    }
    _invalidate([stroke]);
  }

  void clearPreview(Iterable<String> ids) {
    final removed = [for (final id in ids) ?preview.remove(id)];
    _invalidate(removed);
  }

  void select(Iterable<String> ids) {
    final next = ids.toSet();
    if (setEquals(selected, next)) return;
    selected
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void deleteSelection() {
    final remove = [for (final id in selected) ?index[id]];
    if (remove.isNotEmpty) apply(InkEdit(remove: remove));
  }

  void transformSelection({
    double scale = 1,
    double rotation = 0,
    Offset delta = Offset.zero,
    Offset? origin,
  }) {
    final old = [for (final id in selected) ?index[id]];
    if (old.isEmpty) return;
    final bounds = old
        .map((s) => s.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final changed = [
      for (final s in old)
        s.transform(
          origin: origin ?? bounds.center,
          scale: scale,
          rotation: rotation,
          delta: delta,
        ),
    ];
    apply(InkEdit(add: changed, remove: old));
    select(changed.map((s) => s.id));
  }

  bool restyleSelection({
    int? color,
    double? width,
    double? opacity,
    double? scale,
  }) {
    if (color == null && width == null && opacity == null && scale == null) {
      return false;
    }
    final old = [for (final id in selected) ?index[id]];
    if (old.isEmpty) return false;
    final bounds = old
        .map((s) => s.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final changed = [
      for (final s in old)
        s.transform(
          origin: bounds.center,
          scale: scale ?? 1,
          color:
              ((opacity == null
                      ? s.color >> 24
                      : (opacity.clamp(0.0, 1.0) * 255).round()) <<
                  24) |
              ((color ?? s.color) & 0xffffff),
          width: width,
        ),
    ];
    apply(InkEdit(add: changed, remove: old));
    select(changed.map((s) => s.id));
    return true;
  }

  @override
  void dispose() {
    for (final page in _pages.values) {
      page.dispose();
    }
    super.dispose();
  }
}

/// Explicit interchange only. Interactive writes never enter the PDF editor.
Uint8List pdfWithInk(Uint8List bytes, InkDocument ink) {
  if (ink.strokes.isEmpty) return bytes;
  final document = PdfDocument.open(bytes);
  final pages = {
    for (var p = 0; p < document.pageCount; p++) inkPageId(document, p): p,
  };
  final editor = PdfEditor(document);
  final groups = <(String, String, int, double), List<InkStroke>>{};
  for (final s in ink.strokes) {
    (groups[(s.page, s.group, s.color, s.width)] ??= []).add(s);
  }
  final ordered = groups.values.toList()
    ..sort((a, b) => a.first.order.compareTo(b.first.order));
  for (final strokes in ordered) {
    final s = strokes.first;
    final page = pages[s.page];
    if (page == null) continue;
    editor.addInk(
      page,
      [
        for (final part in strokes)
          [
            for (var i = 0; i < part.points.length; i += 3)
              (part.points[i], part.points[i + 1]),
          ],
      ],
      pressures: [
        for (final part in strokes)
          [for (var i = 2; i < part.points.length; i += 3) part.points[i]],
      ],
      color: s.color & 0xffffff,
      opacity: (s.color >> 24) / 255,
      strokeWidth: s.width,
      name: 'noter-ink-${s.group}',
    );
  }
  return editor.hasChanges ? editor.save() : bytes;
}
