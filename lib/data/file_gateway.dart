import 'dart:io';
import 'dart:async';

import 'knowledge.dart';
import 'notebook.dart';
import 'media.dart';
import 'media_gateway.dart';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class FileGateway {
  static Future<void> Function(Notebook, {String? anchor})? openDocument;
  static Future<KnowledgeTask?> Function(KnowledgeTask)? changeKnowledgeTask;
  static Future<void> Function()? refreshOpenDocuments;
  static Map<String, String> Function()? openMarkdownSources;
  static Future<void> Function(
    String linkId,
    bool done, {
    String? excludeNoteId,
  })?
  syncLinkedTask;
  static final sharedText = ValueNotifier<String?>(null);
  static Future<bool> Function()? beforeClose;
  static Future<bool> Function()? workspaceBeforeClose;
  static Future<bool> Function()? fallbackBeforeClose;
  static void initialize() {
    MediaGateway.initialize();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') {
        sharedText.value = call.arguments as String?;
        return true;
      }
      if (call.method == 'prepareClose') {
        try {
          return await prepareClose();
        } catch (error) {
          debugPrint('Could not save open files before closing: $error');
          return false;
        }
      }
      throw MissingPluginException();
    });
    if (Platform.isAndroid) {
      unawaited(
        _channel
            .invokeMethod<String>('getSharedText')
            .then((value) {
              if (value != null) sharedText.value = value;
            })
            .catchError((Object _) {}),
      );
    }
  }

  static Future<bool> prepareClose() async {
    final workspace = workspaceBeforeClose;
    if (workspace != null && !await workspace()) return false;
    final active = beforeClose ?? fallbackBeforeClose;
    return identical(active, workspace) ? true : await active?.call() ?? true;
  }

  static const _channel = MethodChannel('de.noter/files');

  static String exportName(String title, String extension) {
    final safeTitle = title
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_')
        .trim();
    final suffix = '.$extension';
    if (safeTitle.toLowerCase().endsWith(suffix)) return safeTitle;
    return '${safeTitle.isEmpty ? 'Notixer' : safeTitle}$suffix';
  }

  Future<bool> save(String name, Uint8List bytes, String mime) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('save', {
            'name': name,
            'bytes': bytes,
            'mime': mime,
          }) ??
          false;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await XFile.fromData(
      bytes,
      name: name,
      mimeType: mime,
    ).saveTo(location.path);
    return true;
  }

  Future<Uint8List?> pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg'],
          mimeTypes: ['image/png', 'image/jpeg'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('The image is too large (maximum 32 MB).');
    }
    return file.readAsBytes();
  }

  Future<XFile?> pick() => openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: 'Notes and media',
        extensions: [
          'pdf',
          'noter',
          'md',
          'zip',
          ...MediaFormat.formats.map((f) => f.extension),
        ],
        mimeTypes: [
          'application/pdf',
          'application/zip',
          'application/octet-stream',
          'text/markdown',
          'text/plain',
          ...MediaFormat.formats.map((f) => f.mime),
        ],
      ),
    ],
  );
}
