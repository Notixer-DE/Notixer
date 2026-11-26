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
  static const _newProject = '::new-project::';
  String? _project;
  String _projectName = '';
  DateTime? _due;
  late final _catalog = widget.store.repository.catalog;
  Future<void>? _folders;
  String? _error;
  bool _saving = false;
  bool get _canAdd =>
      !_saving &&
      _text.trim().isNotEmpty &&
      (_project != _newProject || _projectName.trim().isNotEmpty);

  Future<void> _add() async {
    if (!_canAdd) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final project = _project == _newProject
          ? (await _catalog.ensureFolder(_projectName)).id
          : _project;
      await widget.store.addQuickTodo(_text, projectId: project, due: _due);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the to-do: $error';
      });
    }
  }

  Future<void> _chooseDue() async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      initialDate: _due ?? DateTime.now(),
      helpText: 'Due date',
    );
    if (mounted && date != null) setState(() => _due = date);
  }

  Widget _planning() => ExpansionTile(
    title: const Text('Project and due date'),
    tilePadding: EdgeInsets.zero,
    onExpansionChanged: (expanded) {
      if (expanded && _folders == null) {
        setState(() => _folders = _catalog.load());
      }
    },
    children: [
      FutureBuilder<void>(
        future: _folders,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Text('Could not load projects.');
          if (snapshot.connectionState != ConnectionState.done) {
            return const LinearProgressIndicator();
          }
          return DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _project ?? '',
            decoration: const InputDecoration(
              labelText: 'Project',
              helperText: 'Projects are library folders.',
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('Unsorted')),
              for (final folder in _catalog.folders)
                DropdownMenuItem(value: folder.id, child: Text(folder.name)),
              const DropdownMenuItem(
                value: _newProject,
                child: Text('New project…'),
              ),
            ],
            onChanged: _saving
                ? null
                : (value) => setState(() {
                    _project = value == '' ? null : value;
                  }),
          );
        },
      ),
      if (_project == _newProject)
        TextFormField(
          initialValue: _projectName,
          decoration: const InputDecoration(labelText: 'New folder name'),
          onChanged: _saving
              ? null
              : (value) => setState(() => _projectName = value),
        ),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _saving ? null : _chooseDue,
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(
              _due == null
                  ? 'Set due date'
                  : MaterialLocalizations.of(context).formatMediumDate(_due!),
            ),
          ),
          if (_due != null)
            IconButton(
              tooltip: 'Clear due date',
              onPressed: _saving ? null : () => setState(() => _due = null),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Add to-do'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
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
                helperText: _project == null
                    ? 'Saved to $unsortedTodos.'
                    : null,
                errorText: _error,
                errorMaxLines: 2,
              ),
            ),
            _planning(),
          ],
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
