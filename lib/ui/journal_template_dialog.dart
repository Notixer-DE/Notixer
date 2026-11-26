import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../data/document_task.dart';
import '../data/journal_template.dart';
import 'markdown_style.dart';

class JournalTemplateDialog extends StatefulWidget {
  const JournalTemplateDialog({
    super.key,
    required this.templates,
    required this.templateId,
    required this.date,
  });

  final List<MarkdownTemplate> templates;
  final String? templateId;
  final DateTime date;

  @override
  State<JournalTemplateDialog> createState() => _JournalTemplateDialogState();
}

class _JournalTemplateDialogState extends State<JournalTemplateDialog> {
  MarkdownTemplate? _find(String? id) =>
      widget.templates.where((entry) => entry.id == id).firstOrNull;

  late String _selected = _find(widget.templateId)?.id ?? '';
  late final _source = TextEditingController(
    text: _find(_selected)?.source ?? '',
  );
  bool _preview = false;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sample = MarkdownTemplate(
      '',
      '',
      _source.text,
    ).render(widget.date, journalDate(widget.date));
    return AlertDialog(
      scrollable: true,
      title: const Text('Journal template'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _selected,
              decoration: const InputDecoration(labelText: 'Default template'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Blank entry')),
                for (final entry in widget.templates)
                  DropdownMenuItem(
                    value: entry.id,
                    child: Text(entry.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => setState(() {
                _selected = value!;
                _source.text = _find(_selected)?.source ?? '';
              }),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Read')),
                ButtonSegment(value: false, label: Text('Edit')),
              ],
              selected: {_preview},
              onSelectionChanged: (value) =>
                  setState(() => _preview = value.single),
            ),
            const SizedBox(height: 12),
            if (_preview)
              MarkdownBody(
                inlineSyntaxes: [TaskMetadataSyntax()],
                key: const ValueKey('journal-template-preview'),
                data: sample.trim().isEmpty
                    ? '# ${journalDate(widget.date)}'
                    : sample,
                styleSheet: noterMarkdownStyle(context),
                imageBuilder: (uri, title, alt) => Text(alt ?? uri.toString()),
              )
            else
              TextField(
                controller: _source,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'Template Markdown',
                  helperText: '{{date}} · {{weekday}} · {{year}} · {{title}}',
                  helperMaxLines: 2,
                ),
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
          onPressed: () => Navigator.pop(context, (_selected, _source.text)),
          child: const Text('Save template'),
        ),
      ],
    );
  }
}
