import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart';
import '../data/document_session.dart';
import '../data/notebook.dart';
import '../data/ink.dart';
import '../data/ink_pdf_controller.dart';
import '../editor/operations.dart';
import 'template_library.dart';
import 'ink_layer.dart';

class PageManager extends StatefulWidget {
  const PageManager({
    super.key,
    required this.session,
    required this.currentPage,
    required this.onPage,
    required this.onCopyTo,
  });
  final DocumentSession session;
  final int currentPage;
  final ValueChanged<int> onPage;
  final Future<void> Function(Notebook, List<int>) onCopyTo;
  @override
  State<PageManager> createState() => _PageManagerState();
}

class _PageManagerState extends State<PageManager> {
  InkPdfController get editing => widget.session.editing;
  final Set<int> selected = {};
  final _inkCache = InkPathCache();
  bool busy = false;
  @override
  void initState() {
    super.initState();
    selected.add(widget.currentPage);
    editing.addListener(_changed);
  }

  void _changed() {
    if (mounted) {
      setState(
        () => selected.removeWhere((i) => i >= editing.document.pageCount),
      );
    }
  }

  @override
  void dispose() {
    _inkCache.clear();
    editing.removeListener(_changed);
    super.dispose();
  }

  Future<void> run(FutureOr<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      editing.finishInk();
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<int> get pages => selected.toList()..sort();
  void _move(bool up) {
    final order = List<int>.generate(editing.document.pageCount, (i) => i);
    if (up) {
      for (var i = 1; i < order.length; i++) {
        if (selected.contains(order[i]) && !selected.contains(order[i - 1])) {
          final t = order[i];
          order[i] = order[i - 1];
          order[i - 1] = t;
        }
      }
    } else {
      for (var i = order.length - 2; i >= 0; i--) {
        if (selected.contains(order[i]) && !selected.contains(order[i + 1])) {
          final t = order[i];
          order[i] = order[i + 1];
          order[i + 1] = t;
        }
      }
    }
    final updated = [
      for (var i = 0; i < order.length; i++)
        if (selected.contains(order[i])) i,
    ];
    editing.apply((e) => e.reorderPages(order));
    setState(
      () => selected
        ..clear()
        ..addAll(updated),
    );
  }

  Future<void> _delete() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete pages?'),
        content: Text(
          '${selected.length}selected pages will be removed. You can undo this in the editor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (answer == true) {
      editing.removePages(pages);
      setState(selected.clear);
    }
  }

  Future<void> _copyTo() async {
    final targets = (await widget.session.repository.list())
        .where((n) => !n.isMarkdown)
        .toList();
    if (!mounted) return;
    final note = await showDialog<Notebook>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy to another note'),
        children: [
          for (final n in targets.where((n) => n.id != widget.session.note.id))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: Text(n.title),
            ),
          if (targets.length < 2)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Create another note first.'),
            ),
        ],
      ),
    );
    if (note != null) {
      await widget.onCopyTo(note, pages);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Pages copied.')));
      }
    }
  }

  Future<void> _insertTemplate() async {
    final entry = await pickTemplate(
      context,
      widget.session.repository.templates,
    );
    if (entry == null || !mounted) return;
    final template = await widget.session.repository.templates
        .instantiateEditable(entry.id);
    if (!mounted) return;
    final at = selected.isEmpty ? editing.document.pageCount : pages.last + 1;
    editing.insertEditablePages(template, at: at);
    setState(
      () => selected
        ..clear()
        ..addAll(List.generate(entry.pageCount, (i) => at + i)),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 720,
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Manage pages',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    if (selected.length == editing.document.pageCount) {
                      selected.clear();
                    } else {
                      selected.addAll(
                        List.generate(editing.document.pageCount, (i) => i),
                      );
                    }
                  }),
                  child: const Text('Select all'),
                ),
                IconButton(
                  tooltip: 'Move selection up',
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => run(() => _move(true)),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move selection down',
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => run(() => _move(false)),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Duplicate pages',
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => run(() async {
                          final count = selected.length;
                          final at = pages.last + 1;
                          await duplicateNotebookPages(editing, pages);
                          selected
                            ..clear()
                            ..addAll(List.generate(count, (i) => at + i));
                        }),
                  icon: const Icon(Icons.copy_all),
                ),
                IconButton(
                  tooltip: 'Copy pages',
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => run(() async {
                          await editing.copyEditablePages(pages);
                        }),
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: 'Paste pages',
                  onPressed: busy || !editing.hasPageClipboard
                      ? null
                      : () => run(() {
                          pasteNotebookPages(
                            editing,
                            at: selected.isEmpty ? null : pages.last + 1,
                          );
                          selected
                            ..clear()
                            ..addAll(editing.selectedPages);
                        }),
                  icon: const Icon(Icons.paste),
                ),
                IconButton(
                  tooltip: 'Copy to another note',
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => run(_copyTo),
                  icon: const Icon(Icons.drive_file_move_outline),
                ),
                IconButton(
                  tooltip: 'Insert from template',
                  onPressed: busy ? null : () => run(_insertTemplate),
                  icon: const Icon(Icons.dashboard_customize_outlined),
                ),
                IconButton(
                  tooltip: 'Delete pages',
                  onPressed:
                      busy ||
                          selected.isEmpty ||
                          selected.length >= editing.document.pageCount
                      ? null
                      : () => run(_delete),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: editing.document.pageCount,
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                if (busy) return;
                editing.clearPageSelection();
                editing.movePage(from, to);
                setState(
                  () => selected
                    ..clear()
                    ..add(to),
                );
              },
              itemBuilder: (context, index) {
                final page = editing.document.page(index);
                final side = page.rotation % 180 != 0;
                final width = side ? page.cropBox.height : page.cropBox.width;
                final height = side ? page.cropBox.width : page.cropBox.height;
                return SizedBox(
                  key: ValueKey(inkPageId(editing.document, index)),
                  height: 120,
                  child: Row(
                    children: [
                      Checkbox(
                        value: selected.contains(index),
                        onChanged: busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(index);
                                } else {
                                  selected.remove(index);
                                }
                              }),
                      ),
                      SizedBox(
                        width: 72,
                        height: 100,
                        child: Center(
                          child: SizedBox(
                            width: width * math.min(72 / width, 100 / height),
                            height: height * math.min(72 / width, 100 / height),
                            child: InkPagePreview(
                              page: page,
                              pageId: inkPageId(editing.document, index),
                              controller: widget.session.ink,
                              cache: _inkCache,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            widget.onPage(index);
                            Navigator.pop(context);
                          },
                          child: Text(
                            'Page ${index + 1}',
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        enabled: !busy,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
