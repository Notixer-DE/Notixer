import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef ShortcutAction = FutureOr<void> Function();

enum ShortcutSection {
  navigation('Navigation and tabs'),
  library('Files and sync'),
  document('Documents'),
  pdf('PDF editor'),
  pdfTools('PDF tools'),
  markdown('Markdown editor'),
  media('Media'),
  knowledge('Tasks, journal and search');

  const ShortcutSection(this.label);
  final String label;
}

enum AppShortcut {
  knowledgeSearch(
    ShortcutSection.navigation,
    'Open global search',
    LogicalKeyboardKey.keyK,
  ),
  importFile(
    ShortcutSection.navigation,
    'Open file picker',
    LogicalKeyboardKey.keyI,
    shift: true,
  ),
  settings(
    ShortcutSection.navigation,
    'Open settings',
    LogicalKeyboardKey.comma,
  ),
  showLibrary(
    ShortcutSection.navigation,
    'Back to library',
    LogicalKeyboardKey.keyL,
  ),
  nextTab(
    ShortcutSection.navigation,
    'Next document tab',
    LogicalKeyboardKey.tab,
  ),
  previousTab(
    ShortcutSection.navigation,
    'Previous document tab',
    LogicalKeyboardKey.tab,
    shift: true,
  ),
  closeTab(
    ShortcutSection.navigation,
    'Close document tab',
    LogicalKeyboardKey.keyW,
  ),
  toggleTabs(
    ShortcutSection.navigation,
    'Toggle document tabs',
    LogicalKeyboardKey.keyT,
    alt: true,
  ),

  newNote(ShortcutSection.library, 'Create a file', LogicalKeyboardKey.keyN),
  quickTodo(
    ShortcutSection.library,
    'Add to-do',
    LogicalKeyboardKey.keyN,
    alt: true,
  ),
  searchLibrary(
    ShortcutSection.library,
    'Search file titles',
    LogicalKeyboardKey.keyF,
  ),
  graph(
    ShortcutSection.library,
    'Open the library graph',
    LogicalKeyboardKey.keyG,
    shift: true,
  ),
  study(
    ShortcutSection.library,
    'Open study',
    LogicalKeyboardKey.keyU,
    alt: true,
  ),
  templates(
    ShortcutSection.library,
    'Open the template library',
    LogicalKeyboardKey.keyQ,
    alt: true,
  ),
  syncSettings(
    ShortcutSection.library,
    'Open sync settings',
    LogicalKeyboardKey.keyS,
    alt: true,
  ),
  syncNow(
    ShortcutSection.library,
    'Sync now',
    LogicalKeyboardKey.keyR,
    alt: true,
  ),

  save(ShortcutSection.document, 'Save document', LogicalKeyboardKey.keyS),
  export(
    ShortcutSection.document,
    'Export document',
    LogicalKeyboardKey.keyE,
    shift: true,
  ),
  undo(ShortcutSection.document, 'Undo', LogicalKeyboardKey.keyZ),
  redo(ShortcutSection.document, 'Redo', LogicalKeyboardKey.keyZ, shift: true),
  zoomIn(ShortcutSection.document, 'Zoom in', LogicalKeyboardKey.equal),
  zoomOut(ShortcutSection.document, 'Zoom out', LogicalKeyboardKey.minus),
  resetZoom(ShortcutSection.document, 'Reset zoom', LogicalKeyboardKey.digit0),
  outline(
    ShortcutSection.document,
    'Open document navigation',
    LogicalKeyboardKey.keyO,
    alt: true,
  ),
  toolbars(
    ShortcutSection.document,
    'Toggle editor toolbars',
    LogicalKeyboardKey.keyH,
    shift: true,
  ),

  pdfSearch(
    ShortcutSection.pdf,
    'Search in the open PDF',
    LogicalKeyboardKey.keyF,
    alt: true,
  ),
  pdfPages(
    ShortcutSection.pdf,
    'Manage PDF pages',
    LogicalKeyboardKey.keyP,
    alt: true,
  ),
  pdfAddPage(
    ShortcutSection.pdf,
    'Add a PDF page',
    LogicalKeyboardKey.keyN,
    shift: true,
  ),
  pdfNextPage(
    ShortcutSection.pdf,
    'Next PDF page',
    LogicalKeyboardKey.pageDown,
  ),
  pdfPreviousPage(
    ShortcutSection.pdf,
    'Previous PDF page',
    LogicalKeyboardKey.pageUp,
  ),
  pdfPen(ShortcutSection.pdfTools, 'Pen', LogicalKeyboardKey.keyD, alt: true),
  pdfHighlighter(
    ShortcutSection.pdfTools,
    'Highlighter',
    LogicalKeyboardKey.keyH,
    alt: true,
  ),
  pdfEraser(
    ShortcutSection.pdfTools,
    'Eraser',
    LogicalKeyboardKey.keyE,
    alt: true,
  ),
  pdfLasso(
    ShortcutSection.pdfTools,
    'Lasso selection',
    LogicalKeyboardKey.keyG,
    alt: true,
  ),
  pdfSelect(
    ShortcutSection.pdfTools,
    'Select',
    LogicalKeyboardKey.keyA,
    alt: true,
  ),
  pdfSelectText(
    ShortcutSection.pdfTools,
    'Select text',
    LogicalKeyboardKey.keyC,
    alt: true,
  ),
  pdfInsertText(
    ShortcutSection.pdfTools,
    'Insert text',
    LogicalKeyboardKey.keyT,
    alt: true,
    shift: true,
  ),

  markdownPreview(
    ShortcutSection.markdown,
    'Switch between Read and Edit',
    LogicalKeyboardKey.keyM,
    alt: true,
  ),
  markdownBold(ShortcutSection.markdown, 'Bold', LogicalKeyboardKey.keyB),
  markdownItalic(ShortcutSection.markdown, 'Italic', LogicalKeyboardKey.keyI),
  markdownChecklist(
    ShortcutSection.markdown,
    'Insert a checklist item',
    LogicalKeyboardKey.keyL,
    shift: true,
  ),
  markdownLink(
    ShortcutSection.markdown,
    'Insert a link',
    LogicalKeyboardKey.keyL,
    alt: true,
  ),

  mediaPlay(
    ShortcutSection.media,
    'Play or pause media',
    LogicalKeyboardKey.space,
    shift: true,
  ),

  knowledgeSubmit(
    ShortcutSection.knowledge,
    'Run the search',
    LogicalKeyboardKey.enter,
  ),
  knowledgeTasks(
    ShortcutSection.knowledge,
    'Open tasks',
    LogicalKeyboardKey.keyK,
    alt: true,
  ),
  knowledgeJournal(
    ShortcutSection.knowledge,
    'Open the journal',
    LogicalKeyboardKey.keyJ,
    alt: true,
  ),
  knowledgeCapture(
    ShortcutSection.knowledge,
    'Quick capture',
    LogicalKeyboardKey.keyI,
    alt: true,
  ),
  knowledgeViews(
    ShortcutSection.knowledge,
    'Open saved views',
    LogicalKeyboardKey.keyV,
    alt: true,
  ),
  knowledgeBackups(
    ShortcutSection.knowledge,
    'Open library backups',
    LogicalKeyboardKey.keyB,
    alt: true,
  );

  const AppShortcut(
    this.section,
    this.label,
    this._key, {
    this.alt = false,
    this.shift = false,
  });
  final ShortcutSection section;
  final String label;
  final LogicalKeyboardKey _key;
  final bool alt, shift;

  SingleActivator get defaultBinding => SingleActivator(
    _key,
    control: true,
    alt: alt,
    shift: shift,
    includeRepeats: false,
  );
}

extension ShortcutBinding on SingleActivator {
  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Meta',
    trigger.keyLabel,
  ].join(' + ');

  (int, bool, bool, bool, bool) get keys =>
      (trigger.keyId, control, alt, shift, meta);

  Map<String, Object> toJson() => {
    'key': trigger.keyId,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };
}

class KeyboardShortcuts extends ChangeNotifier {
  KeyboardShortcuts(this.file);

  final File file;
  Map<AppShortcut, SingleActivator> _bindings = _defaults();
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  bool _disposed = false;

  static Map<AppShortcut, SingleActivator> _defaults() => {
    for (final action in AppShortcut.values) action: action.defaultBinding,
  };

  SingleActivator? operator [](AppShortcut action) => _bindings[action];

  String tooltip(String label, AppShortcut action) {
    final binding = this[action];
    return binding == null ? label : '$label (${binding.label})';
  }

  AppShortcut? match(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    for (final entry in _bindings.entries) {
      if (entry.value.accepts(event, keyboard)) return entry.key;
    }
    // Keep the alternate document shortcuts only while their defaults are active.
    for (final action in const [
      AppShortcut.toggleTabs,
      AppShortcut.save,
      AppShortcut.zoomIn,
      AppShortcut.zoomOut,
      AppShortcut.resetZoom,
    ]) {
      final binding = action.defaultBinding;
      if (this[action]?.keys != binding.keys) continue;
      for (final key in [
        binding.trigger,
        if (action == AppShortcut.zoomIn) ...[
          LogicalKeyboardKey.add,
          LogicalKeyboardKey.numpadAdd,
        ],
        if (action == AppShortcut.zoomOut) LogicalKeyboardKey.numpadSubtract,
      ]) {
        if (SingleActivator(
              key,
              meta: true,
              alt: binding.alt,
              includeRepeats: false,
            ).accepts(event, keyboard) ||
            SingleActivator(
              key,
              control: true,
              alt: binding.alt,
              shift:
                  action == AppShortcut.zoomIn &&
                  key == LogicalKeyboardKey.equal,
              includeRepeats: false,
            ).accepts(event, keyboard)) {
          return action;
        }
      }
    }
    return null;
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      final bindings = <AppShortcut, SingleActivator>{};
      final used = <(int, bool, bool, bool, bool)>{};
      for (final action in AppShortcut.values) {
        final row = data[action.name];
        if (row is! Map || row['key'] is! int) continue;
        final key = LogicalKeyboardKey.findKeyByKeyId(row['key'] as int);
        if (key == null || isModifier(key)) continue;
        final binding = SingleActivator(
          key,
          control: row['control'] == true,
          alt: row['alt'] == true,
          shift: row['shift'] == true,
          meta: row['meta'] == true,
          includeRepeats: false,
        );
        if (data['defaultsVersion'] == null &&
            key == LogicalKeyboardKey.keyF &&
            binding.control &&
            !binding.alt &&
            !binding.meta &&
            ((action == AppShortcut.importFile && !binding.shift) ||
                (action == AppShortcut.searchLibrary && binding.shift))) {
          continue;
        }
        if (_validateBinding(action, binding) == null &&
            used.add(binding.keys)) {
          bindings[action] = binding;
        }
      }
      // An upgrade can add defaults that overlap existing custom bindings.
      for (final action in AppShortcut.values) {
        if (bindings.containsKey(action) ||
            (data.containsKey(action.name) && data[action.name] == null)) {
          continue;
        }
        final binding = action.defaultBinding;
        if (used.add(binding.keys)) bindings[action] = binding;
      }
      _bindings = bindings;
      if (!_disposed) notifyListeners();
    } on IOException {
      // Shortcuts should remain available when local preferences cannot load.
    } on FormatException {
      // Use the defaults until the user saves a new assignment.
    }
  }

  static bool isModifier(LogicalKeyboardKey key) => const [
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  ].contains(key);

  static String? _validateBinding(AppShortcut action, SingleActivator binding) {
    final key = binding.trigger;
    if (LogicalKeyboardKey.findKeyByKeyId(key.keyId) == null ||
        isModifier(key)) {
      return 'This key cannot be used for a shortcut.';
    }
    final functionKey =
        key.keyId >= LogicalKeyboardKey.f1.keyId &&
        key.keyId <= LogicalKeyboardKey.f24.keyId;
    if (!(binding.control || binding.alt || binding.meta || functionKey)) {
      return 'Use Ctrl, Alt or Meta with another key, or press a function key.';
    }
    final editableAction =
        (key == LogicalKeyboardKey.keyS && action == AppShortcut.save) ||
        ((key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyY) &&
            (action == AppShortcut.undo || action == AppShortcut.redo));
    if (!editableAction &&
        !binding.alt &&
        (binding.control || binding.meta) &&
        const [
          LogicalKeyboardKey.keyA,
          LogicalKeyboardKey.keyC,
          LogicalKeyboardKey.keyS,
          LogicalKeyboardKey.keyV,
          LogicalKeyboardKey.keyX,
          LogicalKeyboardKey.keyY,
          LogicalKeyboardKey.keyZ,
        ].contains(key)) {
      return 'This shortcut is reserved for editing or saving.';
    }
    return null;
  }

  String? validate(AppShortcut action, SingleActivator binding) {
    final invalid = _validateBinding(action, binding);
    if (invalid != null) return invalid;
    for (final entry in _bindings.entries) {
      if (entry.key != action && entry.value.keys == binding.keys) {
        return 'Already assigned to ${entry.key.label}.';
      }
    }
    return null;
  }

  Future<void> assign(AppShortcut action, SingleActivator binding) => _save(() {
    final error = validate(action, binding);
    if (error != null) throw FormatException(error);
    return {..._bindings, action: binding};
  });

  Future<void> reset() => _save(_defaults);

  Future<void> _save(Map<AppShortcut, SingleActivator> Function() next) {
    final result = _writes.then((_) async {
      await load();
      final bindings = next();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'defaultsVersion': 2,
          for (final action in AppShortcut.values)
            action.name: bindings[action]?.toJson(),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      _bindings = bindings;
      if (!_disposed) notifyListeners();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
