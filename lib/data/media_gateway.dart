import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'media.dart';

class ImportedMedia {
  const ImportedMedia(this.name, this.bytes, this.format, {this.temporaryPath});
  final String name;
  final Uint8List bytes;
  final MediaFormat format;
  final String? temporaryPath;
  Future<void> release() async {
    if (temporaryPath == null) return;
    final file = File(temporaryPath!);
    if (await file.exists()) await file.delete();
  }
}

class MediaGateway {
  static const channel = MethodChannel('de.noter/media');
  static final recoveredCapture = ValueNotifier<String?>(null);
  static void initialize() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'captureRecovered') {
        recoveredCapture.value = call.arguments as String?;
        return;
      }
      throw MissingPluginException();
    });
  }

  static bool get canCapture => Platform.isAndroid;
  static Future<ImportedMedia> read(
    XFile file, {
    int limit = MediaFormat.maxBytes,
  }) async {
    final format = MediaFormat.of(p.extension(file.name));
    if (format == null) {
      throw const FormatException('Unsupported media format.');
    }
    if (await file.length() > limit) {
      throw FormatException(
        'The attachment is too large (maximum ${limit ~/ (1024 * 1024)} MB).',
      );
    }
    final bytes = await file.readAsBytes();
    format.validate(bytes);
    return ImportedMedia(file.name, bytes, format);
  }

  static Future<ImportedMedia?> pick({
    bool imagesOnly = false,
    int limit = MediaFormat.maxBytes,
  }) async {
    final formats = MediaFormat.formats
        .where((f) => !imagesOnly || f.kind == 'image')
        .toList();
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: imagesOnly ? 'Images' : 'Images, video and audio',
          extensions: formats.map((f) => f.extension).toList(),
          mimeTypes: formats.map((f) => f.mime).toSet().toList(),
        ),
      ],
    );
    return file == null ? null : read(file, limit: limit);
  }

  static Future<List<String>> pendingCaptures() async =>
      await channel.invokeListMethod<String>('pendingCaptures') ?? const [];
  static Future<void> discardCapture(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  static Future<ImportedMedia?> capture({
    bool video = false,
    int limit = MediaFormat.maxBytes,
  }) async {
    final path = await channel.invokeMethod<String>('capture', {
      'video': video,
    });
    return path == null ? null : consumeCapture(path, limit: limit);
  }

  static Future<ImportedMedia> consumeCapture(
    String path, {
    int limit = MediaFormat.maxBytes,
  }) async {
    try {
      final media = await read(XFile(path), limit: limit);
      return ImportedMedia(
        media.name,
        media.bytes,
        media.format,
        temporaryPath: path,
      );
    } catch (_) {
      final file = File(path);
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  static Future<String> playbackFile(
    Uint8List bytes,
    MediaFormat format,
  ) async {
    final directory = Directory(
      p.join((await getTemporaryDirectory()).path, 'media-playback'),
    );
    await directory.create(recursive: true);
    final digest = await Isolate.run(() => sha256.convert(bytes).toString());
    final file = File(p.join(directory.path, '$digest.${format.extension}'));
    await for (final entry in directory.list()) {
      if (entry is File &&
          entry.path != file.path &&
          DateTime.now().difference(await entry.lastModified()).inDays >= 2) {
        await entry.delete();
      }
    }
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }
}
