import 'dart:convert';
import 'dart:io';

/// Portable UI choices, independent of window dimensions and device identity.
class DisplayPreferences {
  DisplayPreferences(this.file);
  final File file;
  Map<String, dynamic> _values = {};
  Future<void>? _loading;
  Future<void> _queue = Future.value();
  Future<void> load() => _loading ??= _read();
  Future<void> _read() async {
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map;
    if (json['version'] != 1 || json['values'] is! Map) {
      throw const FormatException('Invalid display preferences.');
    }
    _values = Map<String, dynamic>.from(json['values'] as Map);
  }

  Future<void> reload() async {
    await _queue;
    _loading = null;
    _values = {};
    await load();
  }

  bool flag(String key, bool fallback) =>
      _values[key] is bool ? _values[key] as bool : fallback;
  double zoom(String key) =>
      _values[key] is num ? (_values[key] as num).toDouble().clamp(.7, 2.5) : 1;
  Future<void> set(String key, Object value) {
    final result = _queue.then((_) async {
      await load();
      if (_values[key] == value) return;
      final next = {..._values, key: value};
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'values': next}),
        flush: true,
      );
      await temporary.rename(file.path);
      _values = next;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> flush() => _queue;
}
