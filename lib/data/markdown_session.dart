import 'dart:async';

import 'package:flutter/foundation.dart';

import 'markdown_document.dart';
import 'notebook.dart';

/// The editor keeps the latest source even when a write fails. A close/navigation
/// waits for *all* edits, including edits made during an in-flight save.
class MarkdownSession extends ChangeNotifier {
  MarkdownSession(this.note, this.document, this.repository);
  Notebook note;
  MarkdownDocument document;
  final NotebookRepository repository;
  Timer? _timer;
  Future<bool>? _saving;
  int _revision = 0, _saved = 0;
  bool _disposed = false;
  String? error;
  bool get dirty => _saved != _revision;
  bool get saving => _saving != null;
  String get status => error != null
      ? 'Not saved'
      : saving
      ? 'Saving …'
      : dirty
      ? 'Unsaved changes'
      : 'Saved locally';

  void update(MarkdownDocument value) {
    document = value;
    _changed();
  }

  void rename(String title) {
    note = note.copy(title: title);
    _changed();
  }

  void organize(Notebook metadata) {
    note = note.copy(
      folderId: metadata.folderId,
      folderName: metadata.folderName,
      clearFolder: metadata.folderId == null,
      tags: metadata.tags,
    );
    _changed();
  }

  void _changed() {
    _revision++;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 600), save);
    notifyListeners();
  }

  Future<bool> save() {
    _timer?.cancel();
    if (_saving != null) return _saving!;
    final result = _write();
    _saving = result;
    if (!_disposed) notifyListeners();
    return result.whenComplete(() {
      _saving = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<bool> _write() async {
    try {
      do {
        while (dirty) {
          final revision = _revision;
          final snapshot = note;
          final bytes = await encodeMarkdownAsync(document);
          final saved = await repository.save(snapshot, bytes);
          // Preserve a rename made while this snapshot was being written.
          note = note.copy(modified: saved.modified);
          _saved = revision;
        }
        await repository.flush();
      } while (dirty);
      error = null;
      return true;
    } catch (e) {
      error = 'Could not save: $e';
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
