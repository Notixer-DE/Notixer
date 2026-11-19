import 'dart:async';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import '../input/stylus_eraser.dart';
import 'notebook.dart';
import 'learning.dart';
import 'tapes.dart';
import 'ink.dart';
import 'ink_pdf_controller.dart';
import 'drawing_preferences.dart';
import '../editor/operations.dart' show exportPdfBytes;

/// A document owns revisions and saves. Views only own their viewport.
class DocumentSession extends ChangeNotifier {
  DocumentSession(
    this.note,
    Uint8List bytes,
    this.repository, {
    PdfPreferencesStore? preferencesStore,
    this.autosaveDelay = const Duration(seconds: 2),
    this.checkpointInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    preferences = PdfEditingPreferences(store: preferencesStore)
      ..fingerDrawsInk = false;
    editing = InkPdfController(bytes, preferences: preferences)
      ..tool = PdfEditTool.ink;
    editing
      ..notebookUndo = undo
      ..notebookRedo = redo
      ..notebookCanUndo = (() => _undo.isNotEmpty)
      ..notebookCanRedo = (() => _redo.isNotEmpty)
      ..notebookTransaction = transaction
      ..inkController = (() => ink)
      ..inkSnapshot = (() => ink.snapshot());
    eraser = StylusEraser(editing);
    editing.addListener(_changed);
    final cached = repository is LocalNotebookRepository
        ? (repository as LocalNotebookRepository).cachedInk(note.id)
        : null;
    if (cached != null) {
      ink.dispose();
      ink = InkController(cached.$1)..onEdit = _inkChanged;
      _inkBase = cached.$2;
      _savedInk = cached.$3;
      _durableInk = ink.sequence;
      loadingInk = false;
      ready = Future.value();
    } else {
      ready = _loadInk();
    }
    final drawing = repository.catalog.drawingPreferences;
    if (drawing.isLoaded && drawing.lastTool == null) {
      // No saved choice to restore: retain the existing immediate default
      // startup path. The PDF preferences loader protects explicit UI edits.
      _lastTool = _toolChoice();
      _restoringTool = false;
      toolReady = Future.value();
    } else {
      toolReady = _restoreTool();
    }
    _checkpoint = Timer.periodic(checkpointInterval, (_) => _autosave());
    preferences.ready.then((_) {
      if (!_disposed) preferences.fingerDrawsInk = false;
    });
  }
  Notebook note;
  final NotebookRepository repository;
  final DateTime Function() _clock;
  late final PdfEditingPreferences preferences;
  late final InkPdfController editing;
  late final StylusEraser eraser;
  InkController ink = InkController(InkDocument(generation: newInkId()));
  late final Future<void> ready;
  late final Future<void> toolReady;
  bool temporaryTool = false, _restoringTool = true;
  DrawingToolChoice? _lastTool;
  PdfEditTool? get baseTool {
    final tool = _lastTool?.tool;
    if (tool == 'textSelection') return null;
    if (tool != null && _toolNames.contains(tool)) {
      return PdfEditTool.values.byName(tool);
    }
    return PdfEditTool.ink;
  }

  static const _toolNames = {
    'ink',
    'highlight',
    'eraser',
    'select',
    'freeText',
    'image',
  };

  Future<void> _restoreTool() async {
    try {
      await repository.catalog.drawingPreferences.load();
      await preferences.ready;
      if (_disposed) return;
      final choice = repository.catalog.drawingPreferences.lastTool;
      if (choice != null) {
        editing.tool = choice.tool == 'textSelection'
            ? null
            : _toolNames.contains(choice.tool)
            ? PdfEditTool.values.byName(choice.tool)
            : PdfEditTool.ink;
        preferences
          ..color = Color(choice.color)
          ..strokeWidth = choice.width
          ..opacity = choice.opacity;
      }
      _lastTool = _toolChoice();
    } catch (e) {
      error = 'Could not restore the tool: $e';
    } finally {
      _restoringTool = false;
      _notifyStatus();
    }
  }

  DrawingToolChoice _toolChoice() => DrawingToolChoice(
    editing.tool?.name ?? 'textSelection',
    preferences.color.toARGB32(),
    preferences.strokeWidth,
    preferences.opacity,
  );

  void recordToolChoice() {
    if (_disposed ||
        _restoringTool ||
        temporaryTool ||
        eraser.held ||
        (editing.tool != null && !_toolNames.contains(editing.tool!.name))) {
      return;
    }
    final choice = _toolChoice();
    if (choice == _lastTool) return;
    _lastTool = choice;
    // Coalesce style-slider changes in memory. Close/save's repository flush
    // persists the final choice, never one file write per pointer/style tick.
    repository.catalog.drawingPreferences.rememberTool(choice);
  }

  bool loadingInk = true, _inkLoadFailed = false, _replaying = false;
  int _savedInk = 0;
  int _durableInk = 0;
  String _inkBase = '';
  bool _journalFailed = false;
  final _undo = <List<InkEdit?>>[], _redo = <List<InkEdit?>>[];
  List<InkEdit?>? _transaction;
  int _historyBytes = 0;
  int _commandBytes(List<InkEdit?> command) =>
      command.fold(0, (total, edit) => total + (edit?.estimatedBytes ?? 64));

  /// A mixed PDF/ink user action is one chronological undo step.
  void transaction(VoidCallback action) {
    if (_transaction != null || _replaying) {
      action();
      return;
    }
    final command = <InkEdit?>[];
    _transaction = command;
    try {
      action();
    } finally {
      _transaction = null;
      if (command.isNotEmpty) _recordCommand(command);
    }
  }

  void _record(InkEdit? edit) {
    if (_transaction case final command?) {
      command.add(edit);
    } else {
      _recordCommand([edit]);
    }
  }

  void _recordCommand(List<InkEdit?> command) {
    _historyBytes -= _redo.fold<int>(0, (total, e) => total + _commandBytes(e));
    _redo.clear();
    _undo.add(command);
    _historyBytes += _commandBytes(command);
    while (_undo.length > 256 ||
        (_historyBytes > 16 * 1024 * 1024 && _undo.length > 1)) {
      _historyBytes -= _commandBytes(_undo.removeAt(0));
    }
  }

  Future<void> _loadInk() async {
    try {
      if (repository case final LocalNotebookRepository local) {
        final (document, base, saved) = await local.openInk(note.id);
        if (_disposed) return;
        ink.dispose();
        ink = InkController(document);
        _inkBase = base;
        _savedInk = saved;
        _durableInk = ink.sequence;
      }
      ink.onEdit = _inkChanged;
    } catch (e) {
      _inkLoadFailed = true;
      error = 'Could not load handwriting: $e';
    } finally {
      loadingInk = false;
      _notifyStatus();
    }
  }

  void _inkChanged(InkEdit edit) {
    if (!_replaying) {
      _record(edit);
    }
    final sequence = ink.sequence;
    if (repository case final LocalNotebookRepository local) {
      if (_saved != editing.revisionId || _journalFailed) {
        // A newly inserted/replaced PDF page must be durable with its ink.
        // A journal referring to a not-yet-saved page cannot recover after a
        // crash. The save drain also catches strokes arriving during this
        // exceptional base-PDF checkpoint; ordinary ink stays journal-only.
        unawaited(save());
      } else {
        // The repository serializes appends and blocks N + 1 after a failed N.
        // Recover with an atomic full checkpoint instead of leaving a gap.
        unawaited(
          local
              .appendInk(note.id, _inkBase, ink.generation, sequence, edit)
              .then((_) {
                if (sequence == _durableInk + 1) _durableInk = sequence;
                _notifyStatus();
              })
              .catchError((Object e) {
                _journalFailed = true;
                error = 'Could not save the ink journal: $e';
                _notifyStatus();
                unawaited(save());
              }),
        );
      }
    }
    _timer?.cancel();
    _timer = Timer(autosaveDelay, _autosave);
    editing.inkChanged();
    _notifyStatus();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final command = _undo.removeLast();
    _replaying = true;
    try {
      for (final edit in command.reversed) {
        if (edit == null) {
          editing.undoPdf();
        } else {
          ink.apply(edit.inverse);
        }
      }
      _redo.add(command);
    } finally {
      _replaying = false;
      editing.inkChanged();
    }
  }

  void redo() {
    if (_redo.isEmpty) return;
    final command = _redo.removeLast();
    _replaying = true;
    try {
      for (final edit in command) {
        if (edit == null) {
          editing.redoPdf();
        } else {
          ink.apply(edit);
        }
      }
      _undo.add(command);
    } finally {
      _replaying = false;
      editing.inkChanged();
    }
  }

  Future<Uint8List> exportSnapshot({
    bool? withTapes,
    bool withoutInk = false,
  }) async {
    await ready;
    if (_inkLoadFailed && !withoutInk) throw StateError(error!);
    editing.finishInk();
    final bytes = Uint8List.fromList(editing.bytes);
    final snapshot = withoutInk
        ? InkDocument(generation: newInkId())
        : ink.snapshot();
    return Isolate.run(() {
      final merged = pdfWithInk(bytes, snapshot);
      if (withTapes == null) return merged;
      return exportPdfBytes(merged, withTapes: withTapes);
    }, debugName: 'noter:export-ink');
  }

  int _saved = 0, _observed = 0;
  int _learningRevision = 0, _savedLearning = 0, _tapesRevision = -1;
  List<TapeTarget> _tapes = const [];
  List<TapeTarget> get tapes {
    if (_tapesRevision != editing.revisionId) {
      _tapes = findTapes(editing.document);
      _tapesRevision = editing.revisionId;
    }
    return _tapes;
  }

  List<TapeTarget> get dueTapes => tapes.where((tape) {
    final schedule = note.learning.schedule(tape.id);
    return schedule == null || schedule.isDue(_clock());
  }).toList();

  /// Learning is not PDF undo state. Deletion hides a task; undoing deletion
  /// restores its existing progress rather than deleting assessments.
  Future<bool> rateTape(String id, ReviewRating rating) {
    if (!tapes.any((tape) => tape.id == id)) {
      throw StateError('This study cover no longer exists.');
    }
    note = note.copy(
      learning: note.learning.assess(
        id,
        rating,
        id: LocalNotebookRepository.newId(),
        at: _clock(),
      ),
    );
    _learningRevision++;
    notifyListeners();
    return save();
  }

  final Duration autosaveDelay, checkpointInterval;
  Timer? _timer, _checkpoint;
  (bool, bool, String?, bool, String, bool)? _lastStatus;
  Future<bool>? _saving;
  String? error;
  bool _disposed = false;
  bool get saving => _saving != null;
  bool get toolsReady => !_restoringTool;
  bool get inkJournalCurrent => _durableInk == ink.sequence;
  bool get inkReady => !loadingInk && !_inkLoadFailed;
  bool get inkLoadFailed => _inkLoadFailed;
  bool get dirty =>
      _saved != editing.revisionId ||
      _savedInk != ink.sequence ||
      _savedLearning != _learningRevision ||
      editing.hasPendingInk;
  String get saveStatus => error != null
      ? 'Not saved'
      : saving
      ? 'Saving …'
      : dirty
      ? 'Unsaved changes'
      : 'Saved locally';
  void _notifyStatus() {
    if (_disposed) return;
    final status = (
      dirty,
      saving,
      error,
      preferences.fingerDrawsInk,
      note.title,
      _restoringTool,
    );
    if (status == _lastStatus) return;
    _lastStatus = status;
    notifyListeners();
  }

  void _changed() {
    recordToolChoice();
    final revisionChanged = editing.revisionId != _observed;
    if (revisionChanged || editing.hasPendingInk) {
      _observed = editing.revisionId;
      _timer?.cancel();
      _timer = Timer(autosaveDelay, _autosave);
    }
    if (revisionChanged && !_replaying) {
      transaction(() {
        _record(null);
        if (inkReady) {
          final pages = {
            for (var p = 0; p < editing.document.pageCount; p++)
              inkPageId(editing.document, p),
          };
          final orphaned = [
            for (final stroke in ink.index.strokes)
              if (!pages.contains(stroke.page)) stroke,
          ];
          if (orphaned.isNotEmpty) ink.apply(InkEdit(remove: orphaned));
        }
      });
    }
    _notifyStatus();
  }

  void _autosave() {
    if (_disposed ||
        _saving != null ||
        (!dirty && ink.sequence - _savedInk < 256)) {
      return;
    }
    if (eraser.contactActive || editing.isEditingText) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 250), _autosave);
      return;
    }
    // Ink is already durable in the append-only journal. Compact occasionally,
    // not a whole PDF/archive for every handwriting pause.
    if (repository is LocalNotebookRepository &&
        _saved == editing.revisionId &&
        _savedLearning == _learningRevision &&
        error == null &&
        ink.sequence - _savedInk < 256) {
      return;
    }
    save();
  }

  Future<bool> save() {
    _timer?.cancel();
    if (loadingInk) return ready.then((_) => save());
    if (_inkLoadFailed) return Future.value(false);
    if (_saving == null &&
        !dirty &&
        _savedInk == ink.sequence &&
        error == null &&
        !editing.isEditingText) {
      return Future.value(true);
    }
    if (editing.isEditingText) {
      FocusManager.instance.primaryFocus?.unfocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    editing.finishInk();
    _timer?.cancel();
    if (_saving != null) return _saving!;
    final future = _drain();
    _saving = future;
    _notifyStatus();
    return future;
  }

  Future<bool> _drain() async {
    await Future<void>.value();
    try {
      while (_saved != editing.revisionId ||
          _savedInk != ink.sequence ||
          _savedLearning != _learningRevision) {
        final revision = editing.revisionId;
        final learningRevision = _learningRevision;
        final inkRevision = ink.sequence;
        final store = repository;
        final snapshot = ink.snapshot();
        final Notebook saved;
        if (store is LocalNotebookRepository) {
          saved = _saved == revision
              ? await store.checkpointInk(note, snapshot)
              : await store.saveWithInk(note, editing.bytes, snapshot);
        } else {
          final bytes = TransferableTypedData.fromList([editing.bytes]);
          final merged = await Isolate.run(
            () => pdfWithInk(bytes.materialize().asUint8List(), snapshot),
            debugName: 'noter:save-export',
          );
          saved = await store.save(note, merged);
        }
        // An assessment from another pane can arrive during disk I/O.
        note = saved.copy(learning: note.learning);
        _saved = revision;
        _savedLearning = learningRevision;
        _savedInk = inkRevision;
        _durableInk = inkRevision;
      }
      _journalFailed = false;
      error = null;
      return true;
    } catch (e) {
      error = 'Could not save: $e';
      return false;
    } finally {
      _saving = null;
      _notifyStatus();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _checkpoint?.cancel();
    editing.removeListener(_changed);
    eraser.reset();
    ink.dispose();
    editing.dispose();
    preferences.dispose();
    super.dispose();
  }
}
