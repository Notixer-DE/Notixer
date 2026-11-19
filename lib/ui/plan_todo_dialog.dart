import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/knowledge.dart';

typedef TodoPlan = ({
  String? projectId,
  String? newProject,
  DateTime? due,
  String? text,
});

class PlanTodoDialog extends StatefulWidget {
  const PlanTodoDialog({super.key, required this.task, required this.folders});

  final KnowledgeTask task;
  final List<NoteFolder> folders;

  @override
  State<PlanTodoDialog> createState() => _PlanTodoDialogState();
}

class _PlanTodoDialogState extends State<PlanTodoDialog> {
  static const _newProject = ':new-project:';
  late String _project =
      widget.folders.any((f) => f.id == widget.task.note.folderId)
      ? widget.task.note.folderId!
      : '';
  String _projectName = '';
  late String _text = widget.task.text;
  late DateTime? _due = DateTime.tryParse(widget.task.due ?? '');

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _due ?? DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      helpText: 'Due date',
    );
    if (mounted && date != null) setState(() => _due = date);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Plan to-do'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.task.quickTodo != null)
            TextFormField(
              initialValue: _text,
              decoration: const InputDecoration(labelText: 'To-do'),
              onChanged: (value) => setState(() => _text = value),
            )
          else
            Text(
              widget.task.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _project,
            decoration: const InputDecoration(labelText: 'Project'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Unsorted')),
              for (final folder in widget.folders)
                DropdownMenuItem(
                  value: folder.id,
                  child: Text(folder.name, overflow: TextOverflow.ellipsis),
                ),
              const DropdownMenuItem(
                value: _newProject,
                child: Text('New project…'),
              ),
            ],
            onChanged: (value) => setState(() => _project = value!),
          ),
          if (_project == _newProject) ...[
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _projectName,
              onChanged: (value) => setState(() => _projectName = value),
              decoration: const InputDecoration(labelText: 'Project name'),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _chooseDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  _due == null
                      ? 'Set due date'
                      : MaterialLocalizations.of(
                          context,
                        ).formatMediumDate(_due!),
                ),
              ),
              if (_due != null)
                IconButton(
                  tooltip: 'Clear due date',
                  onPressed: () => setState(() => _due = null),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            (_project == _newProject && _projectName.trim().isEmpty) ||
                (widget.task.quickTodo != null && _text.trim().isEmpty)
            ? null
            : () => Navigator.pop<TodoPlan>(context, (
                projectId: _project.isEmpty || _project == _newProject
                    ? null
                    : _project,
                newProject: _project == _newProject ? _projectName : null,
                due: _due,
                text: widget.task.quickTodo == null ? null : _text,
              )),
        child: const Text('Save'),
      ),
    ],
  );
}
