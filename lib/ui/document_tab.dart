import 'package:flutter/gestures.dart';
import '../data/document_session.dart';
import 'package:flutter/foundation.dart';
import '../data/notebook.dart';
import '../data/knowledge.dart';
import '../data/keyboard_shortcuts.dart';
import '../input/stylus_eraser.dart';

typedef OpenNotebookTab =
    Future<void> Function(Notebook note, {String? anchor});

/// The workspace owns tab lifetime; editors keep their own document state.
class DocumentTabController extends ChangeNotifier {
  DocumentTabController(this.title, {this.shortcuts});
  String title;
  final KeyboardShortcuts? shortcuts;
  bool dirty = false;
  Object? _owner;
  bool _disposed = false;
  Future<bool> Function()? _save;
  VoidCallback? _pause;
  StylusEraser? Function(PointerEvent)? resolveEraser;
  bool Function(PointerEvent)? interceptEvent;
  Future<void> Function(String)? revealAnchor;
  Future<void> Function(KnowledgeTask)? completeTask;
  Future<void> Function()? refreshMetadata;
  ShortcutAction? Function(AppShortcut)? commandFor;

  void attach(
    Object owner, {
    required Future<bool> Function() save,
    StylusEraser? Function(PointerEvent)? eraser,
    bool Function(PointerEvent)? input,
    Future<void> Function(String)? anchor,
    VoidCallback? pause,
  }) {
    _pause = pause;
    _owner = owner;
    _save = save;
    resolveEraser = eraser;
    interceptEvent = input;
    revealAnchor = anchor;
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _pause = null;
    _owner = null;
    _save = null;
    resolveEraser = null;
    interceptEvent = null;
    revealAnchor = null;
    completeTask = null;
    refreshMetadata = null;
    commandFor = null;
  }

  void deactivate() => _pause?.call();
  Future<bool> save() async => await _save?.call() ?? true;
  void update(String value, bool unsaved) {
    if (_disposed || (title == value && dirty == unsaved)) return;
    title = value;
    dirty = unsaved;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    _save = null;
    _pause = null;
    resolveEraser = null;
    interceptEvent = null;
    revealAnchor = null;
    completeTask = null;
    refreshMetadata = null;
    commandFor = null;
    super.dispose();
  }
}

class LibraryWorkspaceController {
  Future<void> Function()? refresh;
  Future<void> Function()? syncQuickTodos;
  Map<AppShortcut, ShortcutAction> commands = const {};
}

/// One PDF session per notebook, including panes opened from another tab.
class WorkspacePdfSessions {
  WorkspacePdfSessions(this.repository);
  final NotebookRepository repository;
  final _sessions = <String, (DocumentSession, int)>{};
  bool contains(String id) => _sessions.containsKey(id);
  DocumentSession acquire(Notebook note, Uint8List bytes) {
    final existing = _sessions[note.id];
    final session = existing?.$1 ?? DocumentSession(note, bytes, repository);
    _sessions[note.id] = (session, (existing?.$2 ?? 0) + 1);
    return session;
  }

  void release(DocumentSession session) {
    final entry = _sessions[session.note.id];
    if (entry == null || !identical(entry.$1, session)) return;
    if (entry.$2 > 1) {
      _sessions[session.note.id] = (session, entry.$2 - 1);
    } else {
      _sessions.remove(session.note.id);
      session.dispose();
    }
  }

  void dispose() {
    for (final entry in _sessions.values) {
      entry.$1.dispose();
    }
    _sessions.clear();
  }
}
