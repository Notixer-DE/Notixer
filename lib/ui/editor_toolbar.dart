import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import '../data/catalog.dart';
import '../data/document_session.dart';
import '../data/drawing_preferences.dart';
import '../data/keyboard_shortcuts.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';

// Shared by the PDF editor and Live Canvas.
const drawingPalette = [
  ('Black', 0xFF293139),
  ('Green', 0xFF238B7E),
  ('Pink', 0xFFF4BBD0),
  ('Yellow', 0xFFFFE481),
  ('Mint', 0xFFBCE9C9),
  ('Blue', 0xFF3572DB),
];

void _applyColor(PdfEditingController editing, Color color) {
  editing.color = color;
  if (editing.restyleEditingTextSelection(color: color.toARGB32() & 0xFFFFFF)) {
    return;
  }
  if (editing.canRestyleSelected) editing.restyleSelected(color: color);
}

/// One tool strip for every viewport. Secondary tools scroll rather than
/// adding another row above the document on a phone or split pane.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.session,
    required this.catalog,
    required this.onTextSelection,
    required this.onTool,
    required this.onLasso,
    required this.onTape,
    required this.onImage,
    required this.onPreset,
    required this.onEditPreset,
    this.lassoActive = false,
    this.tapeActive = false,
    this.learningActive = false,
    this.preferredPreset,
    this.shortcuts,
    this.onToggleProperties,
    this.propertiesVisible = false,
    this.contextualProperties = false,
  });

  final DocumentSession session;
  final LibraryCatalog catalog;
  final VoidCallback onTextSelection, onLasso, onTape, onImage;
  final ValueChanged<PdfEditTool> onTool;
  final ValueChanged<PenPreset> onPreset;
  final ValueChanged<int> onEditPreset;
  final bool lassoActive, tapeActive, learningActive;
  final PenPreset? preferredPreset;
  final KeyboardShortcuts? shortcuts;
  final VoidCallback? onToggleProperties;
  final bool propertiesVisible, contextualProperties;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session.editing,
      session.preferences,
      catalog,
      catalog.drawingPreferences,
      shortcuts,
    ]),
    builder: (context, _) {
      final editing = session.editing;
      final normal = !lassoActive && !tapeActive && !learningActive;
      bool matches(PenPreset preset) =>
          normal &&
          !session.eraser.held &&
          editing.tool?.name == preset.tool &&
          session.preferences.color.toARGB32() == preset.color &&
          (session.preferences.strokeWidth - preset.width).abs() < .000001 &&
          (session.preferences.opacity - preset.opacity).abs() < .000001 &&
          catalog.drawingPreferences.pressureSensitive(preset.tool) ==
              preset.pressureSensitive;
      // Derive activity from the actual style, not just the last button tap.
      // Identical styles have one deterministic winner; retain the clicked
      // preset when two favourites deliberately use the same configuration.
      var presetIndex = catalog.presets.indexWhere(matches);
      final preferred = preferredPreset == null
          ? -1
          : catalog.presets.indexOf(preferredPreset!);
      if (preferred >= 0 && matches(catalog.presets[preferred])) {
        presetIndex = preferred;
      }
      Widget tool(
        String label,
        IconData icon,
        VoidCallback? action, {
        bool selected = false,
        AppShortcut? shortcut,
      }) => IconButton(
        tooltip: shortcut == null
            ? label
            : shortcuts?.tooltip(label, shortcut) ?? label,
        isSelected: selected,
        onPressed: session.toolsReady ? action : null,
        style: IconButton.styleFrom(
          backgroundColor: selected ? NoterTheme.active : null,
          foregroundColor: selected
              ? NoterTheme.accentStrong
              : NoterTheme.muted,
        ),
        icon: Icon(icon, size: 18),
      );
      return LayoutBuilder(
        builder: (context, constraints) => WorkspaceToolbar(
          child: Row(
            children: [
              Expanded(
                child: _ScrollableTools(
                  children: [
                    tool(
                      'Pen',
                      Icons.edit_outlined,
                      () => onTool(PdfEditTool.ink),
                      shortcut: AppShortcut.pdfPen,
                      selected: normal && editing.tool == PdfEditTool.ink,
                    ),
                    tool(
                      'Highlighter',
                      Icons.highlight_outlined,
                      () => onTool(PdfEditTool.highlight),
                      shortcut: AppShortcut.pdfHighlighter,
                      selected: normal && editing.tool == PdfEditTool.highlight,
                    ),
                    tool(
                      'Eraser',
                      Icons.auto_fix_normal,
                      () => onTool(PdfEditTool.eraser),
                      shortcut: AppShortcut.pdfEraser,
                      selected: editing.tool == PdfEditTool.eraser,
                    ),
                    tool(
                      'Lasso selection',
                      Icons.gesture,
                      onLasso,
                      shortcut: AppShortcut.pdfLasso,
                      selected:
                          lassoActive && editing.tool == PdfEditTool.select,
                    ),
                    tool(
                      'Undo',
                      Icons.undo,
                      editing.canUndo ? editing.undo : null,
                    ),
                    tool(
                      'Redo',
                      Icons.redo,
                      editing.canRedo ? editing.redo : null,
                    ),
                    tool(
                      'Select text',
                      Icons.text_fields,
                      onTextSelection,
                      shortcut: AppShortcut.pdfSelectText,
                      selected: normal && editing.tool == null,
                    ),
                    tool(
                      'Select',
                      Icons.near_me_outlined,
                      () => onTool(PdfEditTool.select),
                      shortcut: AppShortcut.pdfSelect,
                      selected: normal && editing.tool == PdfEditTool.select,
                    ),
                    tool(
                      'Straight strokes (ruler)',
                      Icons.straighten,
                      () async {
                        try {
                          await catalog.drawingPreferences
                              .toggleStraightStrokes();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Could not save ruler mode: $e'),
                              ),
                            );
                          }
                        }
                      },
                      selected: catalog.drawingPreferences.straightStrokes,
                    ),
                    const ToolbarSeparator(),
                    for (var i = 0; i < catalog.presets.length; i++)
                      Tooltip(
                        message: catalog.presets[i].name,
                        child: Semantics(
                          key: ValueKey('pen-preset-$i'),
                          button: true,
                          selected: presetIndex == i,
                          child: Ink(
                            decoration: BoxDecoration(
                              color: presetIndex == i
                                  ? NoterTheme.active
                                  : null,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: presetIndex == i
                                    ? NoterTheme.accentStrong
                                    : Colors.transparent,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(5),
                              onTap: session.toolsReady
                                  ? () => onPreset(catalog.presets[i])
                                  : null,
                              onLongPress: () => onEditPreset(i),
                              child: SizedBox(
                                width: NoterTheme.controlExtent(context),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Icon(
                                      catalog.presets[i].tool == 'highlight'
                                          ? Icons.highlight
                                          : Icons.edit,
                                      color: Color(catalog.presets[i].color),
                                      size: 18,
                                    ),
                                    if (presetIndex == i)
                                      const Positioned(
                                        top: 2,
                                        right: 2,
                                        child: Icon(
                                          Icons.check,
                                          size: 12,
                                          color: NoterTheme.accentStrong,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    tool(
                      'Insert text',
                      Icons.text_fields_outlined,
                      () => onTool(PdfEditTool.freeText),
                      shortcut: AppShortcut.pdfInsertText,
                      selected: normal && editing.tool == PdfEditTool.freeText,
                    ),
                    tool('Insert image', Icons.image_outlined, onImage),
                    tool(
                      'Draw study cover',
                      Icons.rectangle_outlined,
                      onTape,
                      selected:
                          tapeActive && editing.tool == PdfEditTool.select,
                    ),
                  ],
                ),
              ),
              if (!NoterTheme.mobileLayout(constraints.maxWidth) &&
                  constraints.maxWidth >= 900)
                for (final (_, c) in drawingPalette)
                  IconButton(
                    tooltip:
                        'Color #${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                    onPressed: session.toolsReady
                        ? () => _applyColor(editing, Color(c))
                        : null,
                    icon: Icon(Icons.circle, color: Color(c), size: 20),
                  ),
              IconButton(
                tooltip: 'Tool settings',
                isSelected: onToggleProperties != null && propertiesVisible,
                onPressed: !session.toolsReady
                    ? null
                    : onToggleProperties ??
                          () => showDialog<void>(
                            context: context,
                            builder: (_) => _ToolStyleDialog(
                              editing: editing,
                              preferences: session.preferences,
                              drawing: catalog.drawingPreferences,
                              contextual: contextualProperties,
                            ),
                          ),
                icon: Icon(Icons.tune, color: editing.color),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ScrollableTools extends StatefulWidget {
  const _ScrollableTools({required this.children});

  final List<Widget> children;

  @override
  State<_ScrollableTools> createState() => _ScrollableToolsState();
}

class _ScrollableToolsState extends State<_ScrollableTools> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    thumbVisibility: true,
    scrollbarOrientation: ScrollbarOrientation.bottom,
    child: ListView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      children: widget.children,
    ),
  );
}

class ToolPropertiesPanel extends StatelessWidget {
  const ToolPropertiesPanel({
    super.key,
    required this.session,
    required this.catalog,
    required this.onClose,
  });

  final DocumentSession session;
  final LibraryCatalog catalog;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session.editing,
      session.preferences,
      catalog.drawingPreferences,
    ]),
    builder: (context, _) => _ToolStyleDialog(
      key: ObjectKey(session),
      editing: session.editing,
      preferences: session.preferences,
      drawing: catalog.drawingPreferences,
      onClose: onClose,
      contextual: true,
    ),
  );
}

class _ToolStyleDialog extends StatefulWidget {
  const _ToolStyleDialog({
    required this.preferences,
    required this.editing,
    required this.drawing,
    super.key,
    this.onClose,
    this.contextual = false,
  });
  final VoidCallback? onClose;
  final bool contextual;
  final PdfEditingPreferences preferences;
  final PdfEditingController editing;
  final DrawingPreferences drawing;
  @override
  State<_ToolStyleDialog> createState() => _ToolStyleDialogState();
}

class _ToolStyleDialogState extends State<_ToolStyleDialog> {
  late final _hex = TextEditingController(
    text: (widget.preferences.color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase(),
  );
  String? _error, _storageError;
  double? _widthPreview, _opacityPreview;
  Future<void> _changeDrawing(Future<void> change) async {
    try {
      await change;
      if (mounted) setState(() => _storageError = null);
    } catch (e) {
      if (mounted) {
        setState(() => _storageError = 'Could not save the setting: $e');
      }
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preferences;
    final tool = widget.editing.tool;
    final showStroke = !widget.contextual || tool != PdfEditTool.eraser;
    final showEraser = !widget.contextual || tool == PdfEditTool.eraser;
    final tools = [
      if (showStroke) ...[
        Wrap(
          children: [
            for (final (_, c) in drawingPalette)
              IconButton(
                tooltip:
                    'Color #${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                onPressed: () => setState(() {
                  _applyColor(widget.editing, Color(c));
                  _hex.text = (c & 0xFFFFFF)
                      .toRadixString(16)
                      .padLeft(6, '0')
                      .toUpperCase();
                  _error = null;
                }),
                icon: Icon(Icons.circle, color: Color(c)),
              ),
          ],
        ),
        TextField(
          controller: _hex,
          maxLength: 6,
          decoration: InputDecoration(
            labelText: 'Color (hex)',
            prefixText: '#',
            errorText: _error,
          ),
          onChanged: (value) => setState(() {
            if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) {
              _applyColor(
                widget.editing,
                Color(0xFF000000 | int.parse(value, radix: 16)),
              );
              _error = null;
            } else {
              _error = 'Enter six hexadecimal digits.';
            }
          }),
        ),
        Text(
          'Stroke width: ${(_widthPreview ?? p.strokeWidth).toStringAsFixed(1)} pt',
        ),
        Slider(
          value: (_widthPreview ?? p.strokeWidth).clamp(.5, 30),
          min: .5,
          max: 30,
          onChanged: (value) => setState(() => _widthPreview = value),
          onChangeEnd: (value) => setState(() {
            _widthPreview = null;
            p.strokeWidth = value;
            widget.editing.restyleSelected(strokeWidth: value);
          }),
        ),
        Text('Opacity: ${((_opacityPreview ?? p.opacity) * 100).round()} %'),
        Slider(
          value: (_opacityPreview ?? p.opacity).clamp(.05, 1),
          min: .05,
          max: 1,
          onChanged: (value) => setState(() => _opacityPreview = value),
          onChangeEnd: (value) => setState(() {
            _opacityPreview = null;
            p.opacity = value;
            widget.editing.restyleSelected(opacity: value);
          }),
        ),
        if (!widget.contextual || tool == PdfEditTool.ink)
          SwitchListTile(
            key: const ValueKey('fixed-pressure-ink'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Fixed width – pen'),
            value: !widget.drawing.pressureSensitive('ink'),
            onChanged: (value) => _changeDrawing(
              widget.drawing.setPressureSensitive('ink', !value),
            ),
          ),
        if (!widget.contextual || tool == PdfEditTool.highlight)
          SwitchListTile(
            key: const ValueKey('fixed-pressure-highlight'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Fixed width – highlighter'),
            value: !widget.drawing.pressureSensitive('highlight'),
            onChanged: (value) => _changeDrawing(
              widget.drawing.setPressureSensitive('highlight', !value),
            ),
          ),
      ],
      if (showEraser) ...[
        if (!widget.contextual) const Divider(),
        Text('Eraser diameter: ${(p.eraserRadius * 2).toStringAsFixed(0)} pt'),
        Slider(
          key: const ValueKey('eraser-diameter'),
          value: (p.eraserRadius * 2).clamp(4, 80),
          min: 4,
          max: 80,
          label: '${(p.eraserRadius * 2).round()} pt',
          onChanged: (diameter) =>
              setState(() => p.eraserRadius = diameter / 2),
        ),
        const Text(
          'Applies to the eraser and stylus side button. Pen width is independent.',
        ),
        SwitchListTile(
          key: const ValueKey('whole-stroke-eraser'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Erase whole strokes'),
          subtitle: const Text(
            'Also applies to the stylus side button. Off: erase parts of strokes.',
          ),
          value: widget.drawing.wholeStrokeEraser,
          onChanged: (value) =>
              _changeDrawing(widget.drawing.setWholeStrokeEraser(value)),
        ),
      ],
      if (_storageError != null)
        Text(
          _storageError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ];
    if (widget.onClose case final close?) {
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(switch (tool) {
                PdfEditTool.ink => 'Pen',
                PdfEditTool.highlight => 'Highlighter',
                PdfEditTool.eraser => 'Eraser',
                _ => 'Tool settings',
              }),
              trailing: IconButton(
                tooltip: 'Close tool settings',
                icon: const Icon(Icons.close),
                onPressed: close,
              ),
            ),
            ...tools,
          ],
        ),
      );
    }
    return AlertDialog(
      scrollable: true,
      title: const Text('Tool settings'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: tools,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
