import 'dart:convert';
import 'dart:io';

/// Portable view state, stored separately from notebook archives and synced
/// as individual preference records. A damaged/missing preference file must never prevent PDF access.
class ReadingPositions {
  ReadingPositions(this.file);
  final File file;
  final Map<String, int> _pages = {};
  final Map<String, double> _markdown = {};
  Future<void>? _loading;
  bool _loaded = false;
  Future<void>? _queue;

  Future<void> _enqueue(Future<void> Function() action) {
    final previous = _queue;
    final result = previous == null ? action() : previous.then((_) => action());
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queue = settled;
    settled.then((_) {
      if (identical(_queue, settled)) _queue = null;
    });
    return result;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'pages': Map<String, int>.of(_pages),
    'markdown': Map<String, double>.of(_markdown),
  };
  Future<void> reload() async {
    await flush();
    _pages.clear();
    _markdown.clear();
    _loaded = false;
    _loading = null;
    await load();
  }

  Future<void> load() => _loaded ? Future.value() : (_loading ??= _load());

  Future<void> _load() async {
    try {
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map;
      if (json['version'] != 1 || json['pages'] is! Map) return;
      for (final entry in (json['pages'] as Map).entries) {
        if (entry.key is String && entry.value is int && entry.value >= 0) {
          _pages[entry.key as String] = entry.value as int;
        }
      }
      if (json['markdown'] is Map) {
        for (final entry in (json['markdown'] as Map).entries) {
          final value = entry.value;
          if (entry.key is String &&
              value is num &&
              value.isFinite &&
              value >= 0) {
            _markdown[entry.key as String] = value.toDouble();
          }
        }
      }
    } on FormatException {
      // View preferences are disposable; document data is not.
    } on IOException {
      // Opening a document remains possible with unavailable preferences.
    } on TypeError {
      // Treat structurally invalid JSON like an absent preference file.
    } finally {
      _loaded = true;
    }
  }

  int pageFor(String id, int pageCount) =>
      (_pages[id] ?? 0).clamp(0, pageCount > 0 ? pageCount - 1 : 0);

  double markdownOffset(String id) => _markdown[id] ?? 0;

  Future<void> saveMarkdown(String id, double offset) {
    if (!offset.isFinite || offset < 0) return Future.value();
    return _enqueue(() async {
      await load();
      if (_markdown[id] == offset) return;
      final next = {..._markdown, id: offset};
      await _write(_pages, next);
      _markdown
        ..clear()
        ..addAll(next);
    });
  }

  Future<void> _write(
    Map<String, int> pages,
    Map<String, double> markdown,
  ) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'pages': pages, 'markdown': markdown}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  /// Callers resolve duplicate views before saving: the active pane wins.
  Future<void> save(Map<String, int> pages) {
    final snapshot = Map<String, int>.from(pages);
    return _enqueue(() async {
      await load();
      final updated = {..._pages, ...snapshot};
      if (updated.length == _pages.length &&
          updated.entries.every((e) => _pages[e.key] == e.value)) {
        return;
      }
      await _write(updated, _markdown);
      _pages
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> flush() => _queue ?? Future.value();
}
