import 'package:flutter/material.dart';

Future<(String, String)?> showInboxCaptureDialog(
  BuildContext context, {
  String initial = '',
}) async {
  final title = TextEditingController(),
      text = TextEditingController(text: initial);
  final value = await showDialog<(String, String)>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text('Quick capture'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Title (optional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              minLines: 5,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: 'Text or Markdown',
                helperText: 'Saved to Inbox for later organization.',
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
          onPressed: () => Navigator.pop(context, (title.text, text.text)),
          child: const Text('Capture'),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  title.dispose();
  text.dispose();
  return value;
}
