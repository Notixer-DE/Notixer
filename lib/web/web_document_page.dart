import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../data/ink.dart';
import '../data/media.dart';
import '../data/notebook.dart';
import 'browser_library.dart';
import 'web_library.dart';
import 'web_note_archive.dart';

class WebDocumentPage extends StatefulWidget {
  const WebDocumentPage({super.key, required this.note, required this.library});

  final WebNote note;
  final WebLibrary library;

  @override
  State<WebDocumentPage> createState() => _WebDocumentPageState();
}

class _WebDocumentPageState extends State<WebDocumentPage> {
  late WebNote _current = widget.note;
  late final (Notebook, Uint8List, InkDocument?) _file =
      LocalNotebookRepository.decodeWithInk(
        base64Decode(_current.nativeArchive!),
      );
  late final _hasInk = _file.$3?.strokes.isNotEmpty ?? false;
  late final _viewBytes = _hasInk ? pdfWithInk(_file.$2, _file.$3!) : _file.$2;
  bool _busy = false;
  bool _dirty = false;
  bool _leaving = false;
  int _editVersion = 0;
  String? _mediaUrl;
  bool _playbackFailed = false;

  @override
  void dispose() {
    final url = _mediaUrl;
    if (url != null) web.URL.revokeObjectURL(url);
    super.dispose();
  }

  Widget _player(MediaFormat format) {
    if (_playbackFailed) {
      return const Center(
        child: Text('Playback is unavailable. Save the file to your device.'),
      );
    }
    final url = _mediaUrl ??= web.URL.createObjectURL(
      web.Blob([_file.$2.toJS].toJS, web.BlobPropertyBag(type: format.mime)),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 600),
        child: HtmlElementView.fromTagName(
          tagName: format.kind,
          onElementCreated: (element) {
            final media = element as web.HTMLMediaElement;
            media
              ..controls = true
              ..preload = 'metadata'
              ..src = url
              ..style.width = '100%'
              ..style.height = '100%';
            media.addEventListener(
              'error',
              ((web.Event _) {
                if (mounted) setState(() => _playbackFailed = true);
              }).toJS,
            );
          },
        ),
      ),
    );
  }

  Future<void> _save(Uint8List bytes) async {
    if (_busy) return;
    final version = _editVersion;
    setState(() => _busy = true);
    try {
      validatePdf(bytes);
      final note = _file.$1.copy(
        title: _current.title,
        folderName: _current.folder,
        clearFolder: _current.folder == null,
        tags: _current.tags,
        modified: DateTime.now(),
      );
      final updated = webNoteFromArchive(
        LocalNotebookRepository.encode(note, bytes, ink: _file.$3),
      );
      await widget.library.write(updated, previous: _current);
      if (!mounted) return;
      setState(() {
        _current = updated;
        _dirty = _editVersion != version;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved locally.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _leaving) return;
    if (_dirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard unsaved PDF changes?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    if (!mounted) return;
    setState(() => _leaving = true);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final format = _file.$1.mediaFormat;
    return PopScope(
      canPop: _leaving || (!_busy && !_dirty),
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_current.title),
          leading: BackButton(onPressed: _leave),
          actions: [
            IconButton(
              tooltip: 'Save file to device',
              onPressed: () {
                final payload = format == null
                    ? (_hasInk
                          ? _viewBytes
                          : LocalNotebookRepository.decode(
                              base64Decode(_current.nativeArchive!),
                            ).$2)
                    : _file.$2;
                downloadBrowserBytes(
                  '${_current.title}.${format?.extension ?? 'pdf'}',
                  payload,
                  format?.mime ?? 'application/pdf',
                );
              },
              icon: const Icon(Icons.download),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_hasInk)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Viewing native handwriting. Edit this notebook in the installed app.',
                ),
              ),
            Expanded(
              child: format != null
                  ? (format.mime.startsWith('image/')
                        ? InteractiveViewer(
                            child: Center(child: Image.memory(_file.$2)),
                          )
                        : _player(format))
                  : _hasInk
                  ? PdfReader(bytes: _viewBytes)
                  : PdfEditorView(
                      bytes: _viewBytes,
                      documentId: _file.$1.id,
                      autoRenderWorker: false,
                      onDocumentChanged: (_) {
                        _editVersion++;
                        if (!_dirty && mounted) setState(() => _dirty = true);
                      },
                      onSave: _save,
                      onSaveAs: (bytes) => downloadBrowserBytes(
                        '${_current.title}.pdf',
                        bytes,
                        'application/pdf',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
