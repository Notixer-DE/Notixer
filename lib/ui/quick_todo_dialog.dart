import 'package:flutter/material.dart';

import '../data/knowledge.dart';
import '../data/notebook.dart';

Future<bool> showQuickTodoDialog(
  BuildContext context,
  LocalNotebookRepository repository,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QuickTodoDialog(store: KnowledgeStore(repository)),
    ) ??
    false;

class _QuickTodoDialog extends StatefulWidget {
  const _QuickTodoDialog({required this.store});

  final KnowledgeStore store;

  @override
  State<_QuickTodoDialog> createState() => _QuickTodoDialogState();
}

class _QuickTodoDialogState extends State<_QuickTodoDialog> {
  String _text = '';
  String? _error;
  bool _saving = false;
  bool get _canAdd => !_saving && _text.trim().isNotEmpty;

  Future<void> _add() async {
    if (!_canAdd) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.addQuickTodo(_text);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the to-do: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Add to-do'),
      content: SizedBox(
        width: 400,
        child: TextField(
          autofocus: true,
          readOnly: _saving,
          textInputAction: TextInputAction.done,
          onChanged: (value) => setState(() {
            _text = value;
            _error = null;
          }),
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            labelText: 'To-do',
            helperText: 'Saved to $unsortedTodos.',
            errorText: _error,
            errorMaxLines: 2,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canAdd ? _add : null,
          child: Text(_saving ? 'Saving…' : 'Add'),
        ),
      ],
    ),
  );
}
