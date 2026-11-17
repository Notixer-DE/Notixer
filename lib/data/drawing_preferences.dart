import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DrawingToolChoice {
  const DrawingToolChoice(this.tool, this.color, this.width, this.opacity);
  final String tool;
  final int color;
  final double width, opacity;
  Map<String, Object> toJson() => {
    'tool': tool,
    'color': color,
    'width': width,
    'opacity': opacity,
  };
  factory DrawingToolChoice.fromJson(Map<String, dynamic> json) {
    final choice = DrawingToolChoice(
      json['tool'] as String,
      json['color'] as int,
      (json['width'] as num).toDouble(),
      (json['opacity'] as num).toDouble(),
    );
    if (choice.color < 0 ||
        choice.color > 0xffffffff ||
        !choice.width.isFinite ||
        choice.width <= 0 ||
        choice.width > 1000 ||
        !choice.opacity.isFinite ||
        choice.opacity < 0 ||
        choice.opacity > 1) {
      throw const FormatException('Invalid tool state.');
    }
    return choice;
  }
  @override
  bool operator ==(Object other) =>
      other is DrawingToolChoice &&
      tool == other.tool &&
      color == other.color &&
      width == other.width &&
      opacity == other.opacity;
  @override
  int get hashCode => Object.hash(tool, color, width, opacity);
}

/// Device-local drawing policy, separate from notebook/sync contents.
class DrawingPreferences extends ChangeNotifier {
  DrawingPreferences(this.file);
  final File file;
  Map<String, dynamic> _values = {};
  Future<void>? _loading;
  bool _loaded = false;
  bool get isLoaded => _loaded;
  String? loadWarning;
  Future<void> _queue = Future.value();
  DrawingToolChoice? _pendingTool;
  DrawingToolChoice? get lastTool =>
      _pendingTool ??
      (_values['lastTool'] == null
          ? null
          : DrawingToolChoice.fromJson(
              Map<String, dynamic>.from(_values['lastTool'] as Map),
            ));
  void rememberTool(DrawingToolChoice choice) {
    if (choice != lastTool) _pendingTool = choice;
  }

  bool get wholeStrokeEraser => _values['wholeStrokeEraser'] == true;
  bool get straightStrokes => _values['straightStrokes'] == true;
  bool pressureSensitive(String tool) =>
      (_values['pressureSensitive'] as Map?)?[tool] != false;
  Future<void> load() => _loading ??= _load();
  Future<void> flush() async {
    while (true) {
      final queued = _queue;
      await queued;
      // Public preset continuations apply the tool immediately after their
      // policy write completes. Include those coalesced in-memory changes.
      await Future<void>.value();
      if (!identical(queued, _queue)) continue;
      final tool = _pendingTool;
      if (tool == null) return;
      await _set('lastTool', tool.toJson());
      if (_pendingTool == tool) _pendingTool = null;
    }
  }

  Future<void> _load() async {
    try {
      await _read();
    } on FormatException catch (e) {
      await _recover(e);
    } on TypeError catch (e) {
      await _recover(e);
    }
  }

  Future<void> _recover(Object error) async {
    // Keep the original bytes for recovery, but do not let a corrupt optional
    // device preference block the library or all subsequent tool writes.
    await file.copy('${file.path}.invalid');
    _values = {};
    loadWarning = 'Drawing preferences were reset: $error';
    _loaded = true;
    notifyListeners();
  }

  Future<void> _read() async {
    if (!await file.exists()) {
      _loaded = true;
      return;
    }
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['version'] != 1) {
      throw const FormatException('Unknown drawing preferences.');
    }
    _values = Map<String, dynamic>.from(json['values'] as Map);
    if (_values['wholeStrokeEraser'] != null &&
        _values['wholeStrokeEraser'] is! bool) {
      throw const FormatException('Invalid eraser mode.');
    }
    if (_values['straightStrokes'] != null &&
        _values['straightStrokes'] is! bool) {
      throw const FormatException('Invalid ruler mode.');
    }
    final pressure = _values['pressureSensitive'];
    if (pressure != null &&
        (pressure is! Map || pressure.values.any((v) => v is! bool))) {
      throw const FormatException('Invalid pressure setting.');
    }
    if (_values['lastTool'] != null) {
      DrawingToolChoice.fromJson(
        Map<String, dynamic>.from(_values['lastTool'] as Map),
      );
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setWholeStrokeEraser(bool value) =>
      _set('wholeStrokeEraser', value);
  Future<void> setStraightStrokes(bool value) => _set('straightStrokes', value);
  Future<void> toggleStraightStrokes() => _update(
    (next) => next['straightStrokes'] = next['straightStrokes'] != true,
  );
  Future<void> setPressureSensitive(String tool, bool value) {
    if (!['ink', 'highlight'].contains(tool)) {
      throw ArgumentError.value(tool, 'tool');
    }
    return _update(
      (next) => next['pressureSensitive'] = {
        ...?(next['pressureSensitive'] as Map?),
        tool: value,
      },
    );
  }

  Future<void> _set(String key, Object? value) =>
      _update((next) => next[key] = value);
  Future<void> _update(void Function(Map<String, dynamic>) change) {
    final result = _queue.then((_) async {
      await load();
      final next = {..._values};
      change(next);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'values': next}),
        flush: true,
      );
      await temporary.rename(file.path);
      _values = next;
      notifyListeners();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
