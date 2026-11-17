import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'reading_positions.dart';
import 'drawing_preferences.dart';

class NoteFolder {
  const NoteFolder(this.id, this.name);
  final String id, name;
  Map<String, Object> toJson() => {'id': id, 'name': name};
}

class PenPreset {
  const PenPreset(
    this.name,
    this.tool,
    this.color,
    this.width,
    this.opacity, {
    this.pressureSensitive = true,
  });
  final String name, tool;
  final int color;
  final double width, opacity;
  final bool pressureSensitive;
  Map<String, Object> toJson() => {
    'name': name,
    'tool': tool,
    'color': color,
    'width': width,
    'opacity': opacity,
    'pressureSensitive': pressureSensitive,
  };
  factory PenPreset.fromJson(Map<String, dynamic> value) {
    final preset = PenPreset(
      value['name'] as String,
      value['tool'] as String,
      value['color'] as int,
      (value['width'] as num).toDouble(),
      (value['opacity'] as num).toDouble(),
      pressureSensitive: value['pressureSensitive'] as bool? ?? true,
    );
    if (!['ink', 'highlight'].contains(preset.tool) ||
        preset.name.trim().isEmpty ||
        preset.name.length > 24 ||
        preset.color < 0 ||
        preset.color > 0xffffffff ||
        !preset.width.isFinite ||
        !preset.opacity.isFinite ||
        preset.width <= 0 ||
        preset.width > 40 ||
        preset.opacity < 0.05 ||
        preset.opacity > 1) {
      throw const FormatException('Invalid pen preset.');
    }
    return preset;
  }
}

class LibraryCatalog extends ChangeNotifier {
  LibraryCatalog(this.file)
    : drawingPreferences = DrawingPreferences(
        File('${file.parent.path}/.drawing-preferences.json'),
      ),
      readingPositions = ReadingPositions(
        File('${file.parent.path}/.reading-positions.json'),
      );
  final File file;
  final ReadingPositions readingPositions;
  final DrawingPreferences drawingPreferences;
  List<NoteFolder> _folders = [];
  List<PenPreset> _presets = const [
    PenPreset('Writing', 'ink', 0xFF202020, 2, 1),
    PenPreset('Correction', 'ink', 0xFFBC2424, 2, 1),
    PenPreset('Highlight', 'highlight', 0xFFFFD740, 14, 0.35),
  ];
  List<NoteFolder> get folders => List.unmodifiable(_folders);
  List<PenPreset> get presets => List.unmodifiable(_presets);
  Future<void> _queue = Future.value();
  Future<void>? _loading;
  Future<void> flush() async {
    await _queue;
    await drawingPreferences.flush();
  }

  String? loadWarning;
  Future<void> load() => _loading ??= _loadSafely();
  Future<void> _loadSafely() async {
    try {
      await _load();
    } on FormatException catch (error) {
      await _recover(error);
    } on TypeError catch (error) {
      await _recover(error);
    }
  }

  Future<void> _recover(Object error) async {
    // Optional library metadata must not prevent opening intact documents.
    // Preserve the source before replacing the in-memory catalog defaults.
    await file.copy('${file.path}.invalid');
    _folders = [];
    loadWarning = 'Could not read the library catalog: $error';
  }

  Future<void> _load() async {
    await drawingPreferences.load();
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['version'] != 1) {
      throw const FormatException('Unsupported library catalog.');
    }
    final folders = (json['folders'] as List)
        .map((v) => NoteFolder(v['id'] as String, v['name'] as String))
        .toList();
    final presets = (json['presets'] as List)
        .map((v) => PenPreset.fromJson(Map<String, dynamic>.from(v)))
        .toList();
    _folders = folders;
    _presets = presets;
    notifyListeners();
  }

  String? folderName(String? id) {
    for (final folder in _folders) {
      if (folder.id == id) return folder.name;
    }
    return null;
  }

  Future<T> _change<T>(Future<T> Function() action) {
    final result = _queue.then((_) async {
      await load();
      return action();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _persist(
    List<NoteFolder> folders,
    List<PenPreset> presets,
  ) async {
    final snapshot = jsonEncode({
      'version': 1,
      'folders': folders.map((f) => f.toJson()).toList(),
      'presets': presets.map((p) => p.toJson()).toList(),
    });
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(snapshot, flush: true);
    await temporary.rename(file.path);
    _folders = folders;
    _presets = presets;
    notifyListeners();
  }

  Future<NoteFolder> ensureFolder(String name) => _change(() async {
    name = name.trim();
    if (name.isEmpty) {
      throw const FormatException('Please enter a folder name.');
    }
    for (final folder in _folders) {
      if (folder.name.toLowerCase() == name.toLowerCase()) return folder;
    }
    final folder = NoteFolder('${DateTime.now().microsecondsSinceEpoch}', name);
    await _persist([..._folders, folder], _presets);
    return folder;
  });
  Future<void> renameFolder(String id, String name) => _change(() async {
    name = name.trim();
    if (name.isEmpty ||
        _folders.any(
          (f) => f.id != id && f.name.toLowerCase() == name.toLowerCase(),
        )) {
      throw const FormatException(
        'The folder name is empty or already in use.',
      );
    }
    await _persist([
      for (final f in _folders) f.id == id ? NoteFolder(id, name) : f,
    ], _presets);
  });
  Future<void> removeFolder(String id) => _change(() async {
    await _persist(_folders.where((f) => f.id != id).toList(), _presets);
  });
  Future<void> setPreset(int index, PenPreset preset) => _change(() async {
    // Reuse the parser's validation for values entered by the app, too.
    PenPreset.fromJson(preset.toJson());
    final updated = List<PenPreset>.of(_presets);
    updated[index] = preset;
    await _persist(_folders, updated);
  });
}
