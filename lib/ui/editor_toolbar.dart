import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import '../data/catalog.dart';
import '../data/document_session.dart';
import '../data/drawing_preferences.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';

const _editorColors = [
  0xFF293139,
  0xFF238B7E,
  0xFFF4BBD0,
  0xFFFFE481,
  0xFFBCE9C9,
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
  });

  final DocumentSession session;
  final LibraryCatalog catalog;
  final VoidCallback onTextSelection, onLasso, onTape, onImage;
  final ValueChanged<PdfEditTool> onTool;
  final ValueChanged<PenPreset> onPreset;
  final ValueChanged<int> onEditPreset;
  final bool lassoActive, tapeActive, learningActive;
  final PenPreset? preferredPreset;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session.editing,
      session.preferences,
      catalog,
      catalog.drawingPreferences,
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
      }) => IconButton(
        tooltip: label,
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
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  scrollDirection: Axis.horizontal,
                  children: [
                    tool(
                      'Rückgängig',
                      Icons.undo,
                      editing.canUndo ? editing.undo : null,
                    ),
                    tool(
                      'Text auswählen',
                      Icons.text_fields,
                      onTextSelection,
                      selected: normal && editing.tool == null,
                    ),
                    tool(
                      'Stift',
                      Icons.edit_outlined,
                      () => onTool(PdfEditTool.ink),
                      selected: normal && editing.tool == PdfEditTool.ink,
                    ),
                    tool(
                      'Freihandmarker',
                      Icons.highlight_outlined,
                      () => onTool(PdfEditTool.highlight),
                      selected: normal && editing.tool == PdfEditTool.highlight,
                    ),
                    tool(
                      'Gerade Striche (Lineal)',
                      Icons.straighten,
                      () async {
                        try {
                          await catalog.drawingPreferences
                              .toggleStraightStrokes();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Linealmodus konnte nicht gespeichert werden: $e',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      selected: catalog.drawingPreferences.straightStrokes,
                    ),
                    tool(
                      'Radierer',
                      Icons.auto_fix_normal,
                      () => onTool(PdfEditTool.eraser),
                      selected: editing.tool == PdfEditTool.eraser,
                    ),
                    tool(
                      'Lasso-Auswahl',
                      Icons.gesture,
                      onLasso,
                      selected:
                          lassoActive && editing.tool == PdfEditTool.select,
                    ),
                    tool(
                      'Auswählen',
                      Icons.near_me_outlined,
                      () => onTool(PdfEditTool.select),
                      selected: normal && editing.tool == PdfEditTool.select,
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
                      'Text einfügen',
                      Icons.text_fields_outlined,
                      () => onTool(PdfEditTool.freeText),
                      selected: normal && editing.tool == PdfEditTool.freeText,
                    ),
                    tool('Bild einfügen', Icons.image_outlined, onImage),
                    tool(
                      'Lern-Abdeckung zeichnen',
                      Icons.rectangle_outlined,
                      onTape,
                      selected:
                          tapeActive && editing.tool == PdfEditTool.select,
                    ),
                    tool(
                      'Wiederholen',
                      Icons.redo,
                      editing.canRedo ? editing.redo : null,
                    ),
                  ],
                ),
              ),
              if (constraints.maxWidth >= 900)
                for (final c in _editorColors)
                  IconButton(
                    tooltip:
                        'Farbe #${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                    onPressed: session.toolsReady
                        ? () => _applyColor(editing, Color(c))
                        : null,
                    icon: Icon(Icons.circle, color: Color(c), size: 20),
                  ),
              IconButton(
                tooltip: 'Farbe und Strichstärke',
                onPressed: !session.toolsReady
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => _ToolStyleDialog(
                          editing: editing,
                          preferences: session.preferences,
                          drawing: catalog.drawingPreferences,
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

class _ToolStyleDialog extends StatefulWidget {
  const _ToolStyleDialog({
    required this.preferences,
    required this.editing,
    required this.drawing,
  });
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
  Future<void> _changeDrawing(Future<void> change) async {
    try {
      await change;
      if (mounted) setState(() => _storageError = null);
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _storageError = 'Einstellung konnte nicht gespeichert werden: $e',
        );
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
    return AlertDialog(
      scrollable: true,
      title: const Text('Farbe und Strichstärke'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              children: [
                for (final c in _editorColors)
                  IconButton(
                    tooltip:
                        'Farbe #${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
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
                labelText: 'Farbe (Hex)',
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
                  _error = 'Sechs Hex-Zeichen eingeben.';
                }
              }),
            ),
            Text('Strichstärke: ${p.strokeWidth.toStringAsFixed(1)} pt'),
            Slider(
              value: p.strokeWidth.clamp(.5, 30),
              min: .5,
              max: 30,
              onChanged: (value) => setState(() {
                p.strokeWidth = value;
                widget.editing.restyleSelected(strokeWidth: value);
              }),
            ),
            Text('Deckkraft: ${(p.opacity * 100).round()} %'),
            Slider(
              value: p.opacity.clamp(.05, 1),
              min: .05,
              max: 1,
              onChanged: (value) => setState(() {
                p.opacity = value;
                widget.editing.restyleSelected(opacity: value);
              }),
            ),
            SwitchListTile(
              key: const ValueKey('fixed-pressure-ink'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Feste Strichstärke – Stift'),
              value: !widget.drawing.pressureSensitive('ink'),
              onChanged: (value) => _changeDrawing(
                widget.drawing.setPressureSensitive('ink', !value),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('fixed-pressure-highlight'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Feste Strichstärke – Freihandmarker'),
              value: !widget.drawing.pressureSensitive('highlight'),
              onChanged: (value) => _changeDrawing(
                widget.drawing.setPressureSensitive('highlight', !value),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('whole-stroke-eraser'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Ganze Striche radieren'),
              subtitle: const Text(
                'Gilt auch für die Stylus-Seitentaste. Aus: punktuell radieren.',
              ),
              value: widget.drawing.wholeStrokeEraser,
              onChanged: (value) =>
                  _changeDrawing(widget.drawing.setWholeStrokeEraser(value)),
            ),
            if (_storageError != null)
              Text(
                _storageError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}
