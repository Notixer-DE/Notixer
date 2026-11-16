import 'package:flutter/material.dart';
import '../data/catalog.dart';

class PresetDialog extends StatefulWidget {
  const PresetDialog({super.key, required this.preset});
  final PenPreset preset;
  @override
  State<PresetDialog> createState() => _PresetDialogState();
}

class _PresetDialogState extends State<PresetDialog> {
  late final name = TextEditingController(text: widget.preset.name);
  late final color = TextEditingController(
    text: (widget.preset.color & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase(),
  );
  late String tool = widget.preset.tool;
  late double width = widget.preset.width, opacity = widget.preset.opacity;
  late bool pressureSensitive = widget.preset.pressureSensitive;
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Stiftfavorit bearbeiten'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
              maxLength: 24,
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Bitte einen Namen eingeben.'
                  : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: tool,
              decoration: const InputDecoration(labelText: 'Werkzeug'),
              items: const [
                DropdownMenuItem(value: 'ink', child: Text('Stift')),
                DropdownMenuItem(
                  value: 'highlight',
                  child: Text('Freihandmarker'),
                ),
              ],
              onChanged: (value) => setState(() => tool = value!),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: color,
              decoration: const InputDecoration(
                labelText: 'Farbe (Hex)',
                prefixText: '#',
              ),
              validator: (v) => RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v ?? '')
                  ? null
                  : 'Sechs Hex-Zeichen, z. B. 202020.',
            ),
            const SizedBox(height: 8),
            Wrap(
              children: [
                for (final c in [
                  0x202020,
                  0xBC2424,
                  0xFFD740,
                  0x2468B0,
                  0x315F50,
                  0x9C3EAD,
                ])
                  IconButton(
                    tooltip: 'Farbe #${c.toRadixString(16)}',
                    onPressed: () => setState(
                      () => color.text = c
                          .toRadixString(16)
                          .padLeft(6, '0')
                          .toUpperCase(),
                    ),
                    icon: Icon(Icons.circle, color: Color(0xFF000000 | c)),
                  ),
              ],
            ),
            Text('Strichstärke: ${width.toStringAsFixed(1)} pt'),
            Slider(
              value: width.clamp(.5, 30),
              min: .5,
              max: 30,
              onChanged: (v) => setState(() => width = v),
            ),
            Text('Deckkraft: ${(opacity * 100).round()} %'),
            Slider(
              value: opacity,
              min: .05,
              max: 1,
              onChanged: (v) => setState(() => opacity = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Feste Strichstärke'),
              value: !pressureSensitive,
              onChanged: (value) => setState(() => pressureSensitive = !value),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(
              context,
              PenPreset(
                name.text.trim(),
                tool,
                0xFF000000 | int.parse(color.text, radix: 16),
                width,
                opacity,
                pressureSensitive: pressureSensitive,
              ),
            );
          }
        },
        child: const Text('Speichern'),
      ),
    ],
  );
}
