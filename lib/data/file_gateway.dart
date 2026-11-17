import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class FileGateway {
  static Future<bool> Function()? beforeClose;
  static Future<bool> Function()? workspaceBeforeClose;
  static Future<bool> Function()? fallbackBeforeClose;
  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'prepareClose') {
        return prepareClose();
      }
      throw MissingPluginException();
    });
  }

  static Future<bool> prepareClose() async {
    final workspace = workspaceBeforeClose;
    if (workspace != null && !await workspace()) return false;
    final active = beforeClose ?? fallbackBeforeClose;
    return identical(active, workspace) ? true : await active?.call() ?? true;
  }

  static const _channel = MethodChannel('de.noter/files');
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
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'PDF, Notixer or Markdown',
        extensions: ['pdf', 'noter', 'md', 'zip'],
        mimeTypes: [
          'application/pdf',
          'application/zip',
          'application/octet-stream',
          'text/markdown',
          'text/plain',
        ],
      ),
    ],
  );
}
