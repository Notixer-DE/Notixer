import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/file_gateway.dart';
import '../data/document_task.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/knowledge.dart';
import '../data/markdown_document.dart';
import '../data/markdown_session.dart';
import '../data/notebook.dart';
import '../data/todo_list.dart';
import 'document_tab.dart';
import 'noter_theme.dart';
import 'todo_timer.dart';
import 'workspace_chrome.dart';

class TodoListPage extends StatefulWidget {
  const TodoListPage({
    super.key,
    required this.note,
    required this.bytes,
    required this.repository,
    this.initialAnchor = '',
    this.tabController,
    this.onLibrary,
  });

  final Notebook note;
  final Uint8List bytes;
  final LocalNotebookRepository repository;
  final String initialAnchor;
  final DocumentTabController? tabController;
  final Future<void> Function()? onLibrary;

  @override
  State<TodoListPage> createState() => _TodoListPageState();
}

class _TodoListPageState extends State<TodoListPage> {
  late final _document = decodeMarkdownAsync(widget.bytes);

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _document,
    builder: (context, snapshot) {
      final document = snapshot.data;
      if (document == null) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.note.title)),
          body: Center(
            child: snapshot.hasError
                ? Text('Could not open the to-do list: ${snapshot.error}')
                : const CircularProgressIndicator(),
          ),
        );
      }
      return _TodoListEditor(page: widget, document: document);
    },
  );
}

class _TodoListEditor extends StatefulWidget {
  const _TodoListEditor({required this.page, required this.document});

  final TodoListPage page;
  final MarkdownDocument document;

  @override
  State<_TodoListEditor> createState() => _TodoListEditorState();
}

class _TodoListEditorState extends State<_TodoListEditor> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  late final MarkdownSession _session;
  late List<TodoListItem> _items;
  int? _selectedLine;
  bool _leaving = false;
  bool _exporting = false;
  Future<bool> Function()? _previousClose;
  late final Future<bool> Function() _closeHandler = _session.save;
  TodoListPage get _page => widget.page;
  String get _source => _session.document.source;
  double get _rowHeight {
    final style = Theme.of(context).textTheme.bodyMedium!;
    final fontSize = MediaQuery.textScalerOf(context).scale(style.fontSize!);
    return math.max(44.0, fontSize * (style.height ?? 1.4) * 2 + 3);
  }

  @override
  void initState() {
    super.initState();
    _session = MarkdownSession(_page.note, widget.document, _page.repository)
      ..addListener(_changed);
    _items = todoListItems(_source);
    if (_page.tabController case final tab?) {
      tab.attach(this, save: _session.save, anchor: _reveal);
      tab.completeTask = _completeTask;
      tab.commandFor = (action) =>
          action == AppShortcut.export ? _export : null;
      tab.refreshMetadata = () async {
        final notes = await _page.repository.list();
        if (!mounted) return;
        final current = notes
            .where((note) => note.id == _session.note.id)
            .firstOrNull;
        if (current != null) {
          _session.note = current;
          _changed();
        }
      };
    } else {
      _previousClose = FileGateway.beforeClose;
      FileGateway.beforeClose = _closeHandler;
    }
    if (_page.initialAnchor.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _reveal(_page.initialAnchor),
      );
    }
  }

  void _changed() {
    if (!mounted) return;
    _page.tabController?.update(_session.note.title, _session.dirty);
    setState(() {});
  }

  void _replace(String source) {
    if (source == _source) return;
    _items = todoListItems(source);
    _selectedLine = null;
    _session.update(_session.document.copy(source: source));
  }

  void _add() {
    if (_leaving || _input.text.trim().isEmpty) return;
    _replace(appendTodoItem(_source, _input.text));
    _input.clear();
    _inputFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _edit(TodoListItem item) async {
    final source = _source;
    var text = item.text;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit task'),
          scrollable: true,
          content: TextFormField(
            initialValue: text,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Task'),
            onChanged: (value) => setDialogState(() => text = value),
            onFieldSubmitted: (_) {
              if (text.trim().isNotEmpty) Navigator.pop(context, text);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, text),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || value == null || value.trim() == item.text) return;
    if (source != _source) {
      _message('The list changed. Open the task again to edit it.');
      return;
    }
    _replace(item.rename(source, value));
  }

  Future<void> _reveal(String anchor) async {
    if (!mounted || !anchor.startsWith('line=')) return;
    final line = int.tryParse(anchor.substring(5));
    final index = _items.indexWhere((item) => item.line == line);
    if (index < 0) return;
    setState(() => _selectedLine = line);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(
      (_rowHeight * index).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  Future<void> _completeTask(KnowledgeTask task) async {
    if (task.note.id != _session.note.id) {
      throw const FormatException('The task changed. Reload the task list.');
    }
    _replace(task.editDocument(_source));
    if (!await _session.save()) throw StateError(_session.error!);
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      if (!await _session.save() || !mounted) return;
      final bytes = await _page.repository.exportArchive(_session.note);
      if (!mounted) return;
      if (await FileGateway().save(
        FileGateway.exportName(_session.note.title, 'noter'),
        bytes,
        'application/zip',
      )) {
        _message('File saved.');
      }
    } catch (error) {
      _message('Could not save the file: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (_page.onLibrary case final showLibrary?) {
      await showLibrary();
      return;
    }
    setState(() => _leaving = true);
    final saved = await _session.save();
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (_page.tabController == null)
        AppShortcut.save.defaultBinding: _session.save,
    },
    child: PopScope(
      canPop: _page.tabController != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page.tabController == null) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _session.note.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          toolbarHeight: NoterTheme.headerHeight(context),
          leadingWidth: DocumentTabsChrome.leadingWidth(context),
          leading: DocumentNavigation(child: BackButton(onPressed: _leave)),
          actions: [
            IconButton(
              tooltip: 'Save file to device',
              onPressed: _exporting ? null : _export,
              icon: const Icon(Icons.save_alt),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  children: [
                    TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: _add,
                      decoration: InputDecoration(
                        labelText: 'New task',
                        suffixIcon: ValueListenableBuilder(
                          valueListenable: _input,
                          builder: (context, value, _) => IconButton(
                            tooltip: 'Add task',
                            onPressed: _leaving || value.text.trim().isEmpty
                                ? null
                                : _add,
                            icon: const Icon(Icons.add),
                          ),
                        ),
                      ),
                    ),
                    if (_session.error case final error?)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _session.save,
                          child: Text('$error · Retry'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _items.isEmpty
                          ? const Center(child: Text('No tasks yet.'))
                          : ListView.builder(
                              controller: _scroll,
                              itemExtent: _rowHeight,
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final item = _items[index];
                                return ListTile(
                                  key: ValueKey('todo-line-${item.line}'),
                                  selected: _selectedLine == item.line,
                                  selectedTileColor: NoterTheme.active,
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  minVerticalPadding: 0,
                                  horizontalTitleGap: 6,
                                  leading: Checkbox(
                                    value: item.done,
                                    visualDensity: VisualDensity.compact,
                                    semanticLabel: item.text,
                                    onChanged: _leaving
                                        ? null
                                        : (value) => _replace(
                                            item.check(_source, value!),
                                          ),
                                  ),
                                  title: Text(
                                    item.text.isEmpty
                                        ? '(Empty task)'
                                        : item.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium!
                                        .copyWith(
                                          decoration: item.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TodoTimer(
                                        todo: documentTask(
                                          _source,
                                          item.offset,
                                          item.text,
                                          fallback: _session.note.modified,
                                        ),
                                        onChanged: _leaving
                                            ? null
                                            : (action) => _replace(
                                                updateDocumentTask(
                                                  _source,
                                                  item.offset,
                                                  timer: action,
                                                ),
                                              ),
                                      ),
                                      IconButton(
                                        tooltip: 'Edit task',
                                        onPressed: _leaving
                                            ? null
                                            : () => _edit(item),
                                        icon: const Icon(Icons.edit_outlined),
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
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _page.tabController?.detach(this);
    if (identical(FileGateway.beforeClose, _closeHandler)) {
      FileGateway.beforeClose = _previousClose;
    }
    _session.removeListener(_changed);
    _session.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
