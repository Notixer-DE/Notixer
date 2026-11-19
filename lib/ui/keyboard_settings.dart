import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/keyboard_shortcuts.dart';

class KeyboardSettingsPage extends StatefulWidget {
  const KeyboardSettingsPage({super.key, required this.shortcuts});

  final KeyboardShortcuts shortcuts;

  @override
  State<KeyboardSettingsPage> createState() => _KeyboardSettingsPageState();
}

class _KeyboardSettingsPageState extends State<KeyboardSettingsPage> {
  bool _saving = false;
  String? _error;

  Future<void> _save(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not save shortcuts: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(AppShortcut action) async {
    SingleActivator? candidate;
    String? error;
    final binding = await showDialog<SingleActivator>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final keyboard = HardwareKeyboard.instance;
            final key = event.logicalKey;
            if (KeyboardShortcuts.isModifier(key)) {
              return KeyEventResult.handled;
            }
            final modified =
                keyboard.isControlPressed ||
                keyboard.isAltPressed ||
                keyboard.isMetaPressed;
            if (!modified &&
                (key == LogicalKeyboardKey.escape ||
                    key == LogicalKeyboardKey.tab ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.space)) {
              return KeyEventResult.ignored;
            }
            final next = SingleActivator(
              key,
              control: keyboard.isControlPressed,
              alt: keyboard.isAltPressed,
              shift: keyboard.isShiftPressed,
              meta: keyboard.isMetaPressed,
              includeRepeats: false,
            );
            update(() {
              candidate = next;
              error = widget.shortcuts.validate(action, next);
            });
            return KeyEventResult.handled;
          },
          child: AlertDialog(
            title: Text(action.label),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(candidate?.label ?? 'Press a shortcut'),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: candidate == null || error != null
                    ? null
                    : () => Navigator.pop(context, candidate),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && binding != null) {
      await _save(() => widget.shortcuts.assign(action, binding));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListenableBuilder(
            listenable: widget.shortcuts,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Keyboard shortcuts',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => _save(widget.shortcuts.reset),
                    child: const Text('Restore defaults'),
                  ),
                ),
                if (_saving) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final section in ShortcutSection.values) ...[
                  const Divider(),
                  Text(
                    section.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final action in AppShortcut.values.where(
                    (action) => action.section == section,
                  ))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(action.label),
                      subtitle: Text(widget.shortcuts[action].label),
                      trailing: const Icon(Icons.edit_outlined),
                      enabled: !_saving,
                      onTap: () => _edit(action),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
