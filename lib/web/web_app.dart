import 'dart:convert';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/journal_template.dart';
import '../data/markdown_document.dart';
import '../data/todo_items.dart';
import '../ui/journal_calendar.dart';
import '../ui/journal_template_dialog.dart';
import '../ui/markdown_preview.dart';
import '../ui/noter_theme.dart';
import 'web_library.dart';

typedef WebDownload = void Function(String name, String contents, String type);

class NotixerWebApp extends StatelessWidget {
  const NotixerWebApp({
    super.key,
    required this.library,
    required this.download,
  });

  final WebLibrary library;
  final WebDownload download;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Notixer',
    theme: NoterTheme.light,
    builder: (context, child) =>
        Theme(data: NoterTheme.forWindow(context), child: child!),
    home: _Workspace(library: library, download: download),
  );
}

class _Workspace extends StatefulWidget {
  const _Workspace({required this.library, required this.download});
  final WebLibrary library;
  final WebDownload download;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  static const _destinations = [
    ('Library', Icons.folder_outlined),
    ('Tasks', Icons.checklist),
    ('Journal', Icons.calendar_today_outlined),
  ];
  final _random = Random.secure();
  List<WebNote> _notes = [];
  int _section = 0;
  String _query = '';
  String? _error;
  bool _busy = true;
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  late DateTime _month = DateTime(_day.year, _day.month);

  @override
  void initState() {
    super.initState();
    _load();
  }

  WebNote? _note(String id) =>
      _notes.where((note) => note.id == id).firstOrNull;

  Future<void> _load() => _perform(() async {});

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      final notes = await widget.library.readAll();
      notes.sort((a, b) => b.modified.compareTo(a.modified));
      if (mounted) setState(() => _notes = notes);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _id() =>
      'note-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_random.nextInt(0x7fffffff).toRadixString(36)}';

  Future<void> _open(WebNote note, {bool newNote = false}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _Editor(
          note: note,
          previous: newNote ? null : note,
          library: widget.library,
          download: widget.download,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _create(WebNoteKind kind) async {
    final title = await _askText(
      context,
      kind == WebNoteKind.todo ? 'New to-do list' : 'New Markdown note',
      'Title',
    );
    if (title == null || !mounted) return;
    await _open(WebNote(_id(), kind, title, '', DateTime.now()), newNote: true);
  }

  Future<void> _import() => _perform(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Markdown or Notixer Web backup',
          extensions: ['md', 'markdown', 'json'],
        ),
      ],
    );
    if (file == null) return;
    final backup = file.name.toLowerCase().endsWith('.json');
    if (await file.length() >
        (backup ? webBackupMaxBytes : MarkdownDocument.maxTextBytes)) {
      throw const FormatException('The file is too large to import.');
    }
    final source = utf8.decode(await file.readAsBytes());
    if (backup) {
      final notes = decodeWebBackup(source);
      final added = await widget.library.importMissing(notes);
      if (mounted) {
        _message(
          'Imported $added entries. ${notes.length - added} already existed.',
        );
      }
      return;
    }
    final name = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
    final title = name.isEmpty
        ? 'Imported note'
        : String.fromCharCodes(name.runes.take(60));
    await widget.library.write(
      WebNote(_id(), WebNoteKind.markdown, title, source, DateTime.now()),
      previous: null,
    );
  });

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _backup() => _perform(() async {
    widget.download(
      'notixer-web-${journalDate(DateTime.now())}.json',
      encodeWebBackup(await widget.library.readAll()),
      'application/json',
    );
  });

  Future<void> _addTodo([String? supplied]) async {
    final text = supplied ?? await _askText(context, 'Add to-do', 'To-do');
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _perform(() async {
      final existing = _note(WebNote.inboxId);
      final note =
          existing ??
          WebNote(
            WebNote.inboxId,
            WebNoteKind.inbox,
            'Unsorted to-dos',
            '',
            DateTime.now(),
          );
      await widget.library.write(
        note.edit(note.title, appendTodoItem(note.source, text)),
        previous: existing,
      );
    });
  }

  WebNote _newDay(DateTime date) {
    final day = journalDate(date);
    final source =
        _note(WebNote.templateId)?.source ?? defaultJournalTemplate.source;
    final template = MarkdownTemplate(
      '',
      '',
      source.isEmpty ? '# {{date}}\n' : source,
    );
    return WebNote(
      'journal-$day',
      WebNoteKind.journal,
      day,
      template.render(date, day),
      DateTime.now(),
    );
  }

  Future<void> _todayEntry() async {
    final draft = _newDay(_day);
    final note = _note(draft.id);
    final text = await _askText(
      context,
      'Add journal entry',
      'Journal entry',
      multiline: true,
    );
    if (text == null || !mounted) return;
    await _perform(() async {
      final current = note ?? draft;
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.now());
      await widget.library.write(
        current.edit(
          current.title,
          '${current.source.trimRight()}\n\n### $time\n\n$text\n',
        ),
        previous: note,
      );
    });
  }

  Future<void> _template() async {
    final note = _note(WebNote.templateId);
    final template = MarkdownTemplate(
      'daily',
      defaultJournalTemplate.name,
      note == null || note.source.isEmpty
          ? defaultJournalTemplate.source
          : note.source,
    );
    final choice = await showDialog<(String, String)>(
      context: context,
      builder: (_) => JournalTemplateDialog(
        templates: [template],
        templateId: note?.source == '' ? null : template.id,
        date: _day,
      ),
    );
    if (choice == null || !mounted) return;
    await _perform(
      () => widget.library.write(
        WebNote(
          WebNote.templateId,
          WebNoteKind.template,
          'Journal template',
          choice.$2,
          DateTime.now(),
        ),
        previous: note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final panel = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              ListTile(
                title: Text(error),
                trailing: TextButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('Reload'),
                ),
              ),
            Expanded(
              child: switch (_section) {
                1 => _tasks(),
                2 => _journal(),
                _ => _library(),
              },
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notixer'),
        actions: [
          IconButton(
            tooltip: 'Add to-do',
            onPressed: _busy ? null : _addTodo,
            icon: const Icon(Icons.playlist_add),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'Library actions',
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: !_busy,
                value: _backup,
                child: const Text('Export web backup'),
              ),
              PopupMenuItem(
                enabled: !_busy,
                value: _load,
                child: const Text('Reload'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: desktop
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _section,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (value) =>
                        setState(() => _section = value),
                    destinations: [
                      for (final (title, icon) in _destinations)
                        NavigationRailDestination(
                          icon: Icon(icon),
                          label: Text(title),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: panel),
                ],
              )
            : panel,
      ),
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: _section,
              onDestinationSelected: (value) =>
                  setState(() => _section = value),
              destinations: [
                for (final (title, icon) in _destinations)
                  NavigationDestination(icon: Icon(icon), label: title),
              ],
            ),
    );
  }

  Widget _library() {
    final visible = _notes
        .where(
          (note) =>
              (note.kind == WebNoteKind.markdown ||
                  note.kind == WebNoteKind.todo) &&
              note.title.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: visible.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'My notes',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _create(WebNoteKind.markdown),
                    icon: const Icon(Icons.add),
                    label: const Text('New Markdown note'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _create(WebNoteKind.todo),
                    icon: const Icon(Icons.checklist),
                    label: const Text('New to-do list'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Import file'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: _query,
                decoration: const InputDecoration(
                  hintText: 'Search note titles',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              if (visible.isEmpty && !_busy)
                Text(_query.isEmpty ? 'No notes yet.' : 'No matching notes.'),
            ],
          );
        }
        final note = visible[index - 1];
        final tasks = note.kind == WebNoteKind.todo;
        return ListTile(
          leading: Icon(tasks ? Icons.checklist : Icons.description_outlined),
          title: Text(note.title),
          subtitle: Text(tasks ? 'To-do list' : 'Markdown'),
          onTap: _busy ? null : () => _open(note),
        );
      },
    );
  }

  Widget _tasks() {
    final note = _note(WebNote.inboxId);
    return _TaskList(
      heading: 'Unsorted to-dos',
      source: note?.source ?? '',
      enabled: !_busy,
      onAdd: _addTodo,
      onChange: (source) {
        if (note == null) return;
        _perform(
          () => widget.library.write(
            note.edit(note.title, source),
            previous: note,
          ),
        );
      },
    );
  }

  Widget _journal() {
    final note = _note('journal-${journalDate(_day)}');
    void choose(DateTime day) {
      setState(() {
        _day = day;
        _month = DateTime(day.year, day.month);
      });
      final entry = _note('journal-${journalDate(day)}');
      if (entry != null) _open(entry);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => choose(DateUtils.dateOnly(DateTime.now())),
              icon: const Icon(Icons.today_outlined),
              label: const Text('Today'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _template,
              icon: const Icon(Icons.tune),
              label: const Text('Journal template'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: JournalCalendar(
              month: _month,
              selected: _day,
              entryDays: _notes.map((note) => note.day).nonNulls.toSet(),
              onMonth: _busy ? null : (month) => setState(() => _month = month),
              onDay: _busy ? null : choose,
            ),
          ),
        ),
        const Divider(height: 32),
        Text(
          MaterialLocalizations.of(context).formatFullDate(_day),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (note == null)
          const Text('No journal entry for this day.')
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : () => _open(note),
              child: Text(note.title),
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _todayEntry,
            icon: const Icon(Icons.add),
            label: const Text('Add entry'),
          ),
        ),
      ],
    );
  }
}

class _Editor extends StatefulWidget {
  const _Editor({
    required this.note,
    required this.previous,
    required this.library,
    required this.download,
  });
  final WebNote note;
  final WebNote? previous;
  final WebLibrary library;
  final WebDownload download;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late WebNote? _saved = widget.previous;
  late final _title = TextEditingController(text: widget.note.title);
  late final _source = TextEditingController(text: widget.note.source);
  final _scroll = ScrollController();
  final _preview = GlobalKey<MarkdownPreviewState>();
  late bool _editing = _saved == null;
  bool _busy = false, _leaving = false;
  String? _error;

  bool get _tasks => widget.note.kind == WebNoteKind.todo;
  bool get _dirty =>
      _source.text != (_saved ?? widget.note).source ||
      _title.text != (_saved ?? widget.note).title;

  @override
  void dispose() {
    _title.dispose();
    _source.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _save(String source) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = widget.note.edit(_title.text, source);
      await widget.library.write(note, previous: _saved);
      if (!mounted) return false;
      setState(() {
        _saved = note;
        if (_source.text != source) _source.text = source;
      });
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _leaving) return;
    if (_dirty &&
        !await _confirm(context, 'Discard unsaved changes?', 'Discard')) {
      return;
    }
    if (!mounted) return;
    setState(() => _leaving = true);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final note = _saved;
    if (note == null ||
        !await _confirm(
          context,
          'Delete this note from this browser?',
          'Delete',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.library.delete(note);
      if (!mounted) return;
      setState(() => _leaving = true);
      Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _follow(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (href.startsWith('#')) {
      await _preview.currentState?.scrollToHeading(uri.fragment);
    } else if (uri.scheme == 'https' || uri.scheme == 'http') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving || (!_dirty && !_busy),
    onPopInvokedWithResult: (popped, _) {
      if (!popped) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _leave,
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(_saved?.title ?? widget.note.title),
        actions: [
          if (_editing || _saved == null || _dirty)
            TextButton(
              onPressed: _busy || _title.text.trim().isEmpty
                  ? null
                  : () async {
                      if (await _save(_source.text) && mounted) {
                        setState(() => _editing = false);
                      }
                    },
              child: const Text('Save'),
            ),
          if (_saved != null)
            PopupMenuButton<String>(
              tooltip: 'Note actions',
              enabled: !_busy,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'save', child: Text('Download Markdown')),
                PopupMenuItem(value: 'delete', child: Text('Delete note')),
              ],
              onSelected: (value) {
                if (value == 'delete') {
                  _delete();
                } else {
                  final note = _saved!;
                  final name = note.title.replaceAll(
                    RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
                    '_',
                  );
                  widget.download(
                    '$name.md',
                    note.source,
                    'text/markdown;charset=utf-8',
                  );
                }
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(error),
                  ),
                if (!_tasks)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Formatted')),
                        ButtonSegment(value: true, label: Text('Markdown')),
                      ],
                      selected: {_editing},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() => _editing = value.single),
                    ),
                  ),
                Expanded(
                  child: _tasks
                      ? _TaskList(
                          source: _source.text,
                          enabled: !_busy,
                          onAdd: (text) =>
                              _save(appendTodoItem(_source.text, text)),
                          onChange: _save,
                          heading: _title.text,
                        )
                      : _editing
                      ? _sourceEditor()
                      : _formatted(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _sourceEditor() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      children: [
        TextField(
          controller: _title,
          maxLength: 120,
          readOnly: _busy,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        Expanded(
          child: TextField(
            controller: _source,
            readOnly: _busy,
            onChanged: (_) => setState(() {}),
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Markdown source',
              alignLabelWithHint: true,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _formatted() => CustomScrollView(
    controller: _scroll,
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        sliver: MarkdownPreview(
          key: _preview,
          document: MarkdownDocument(_source.text),
          scrollController: _scroll,
          onToggle: (offset, checked) {
            if (!_busy) {
              _save(
                _source.text.replaceRange(
                  offset,
                  offset + 1,
                  checked ? 'x' : ' ',
                ),
              );
            }
          },
          onFollow: _follow,
        ),
      ),
    ],
  );
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.source,
    required this.enabled,
    required this.onAdd,
    required this.onChange,
    required this.heading,
  });

  final String source, heading;
  final bool enabled;
  final ValueChanged<String> onAdd, onChange;

  @override
  Widget build(BuildContext context) {
    final tasks = todoListItems(source);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: tasks.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(heading, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add task'),
                onPressed: !enabled
                    ? null
                    : () async {
                        final text = await _askText(
                          context,
                          'Add task',
                          'Task',
                        );
                        if (text != null && context.mounted) onAdd(text);
                      },
              ),
              const SizedBox(height: 8),
              if (tasks.isEmpty) const Text('No tasks yet.'),
            ],
          );
        }
        final item = tasks[index - 1];
        return ListTile(
          dense: true,
          leading: Checkbox(
            value: item.done,
            semanticLabel: item.text,
            onChanged: !enabled
                ? null
                : (done) => onChange(item.check(source, done!)),
          ),
          title: Text(
            item.text,
            style: item.done
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
          ),
          trailing: IconButton(
            tooltip: 'Edit task',
            icon: const Icon(Icons.edit_outlined),
            onPressed: !enabled
                ? null
                : () async {
                    final text = await _askText(
                      context,
                      'Edit task',
                      'Task',
                      initial: item.text,
                    );
                    if (text != null && context.mounted) {
                      onChange(item.rename(source, text));
                    }
                  },
          ),
        );
      },
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> _askText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
  bool multiline = false,
}) {
  var text = initial;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        void submit() {
          if (text.trim().isNotEmpty) Navigator.pop(context, text.trim());
        }

        return AlertDialog(
          scrollable: true,
          title: Text(title),
          content: TextFormField(
            autofocus: true,
            initialValue: initial,
            decoration: InputDecoration(labelText: label),
            onChanged: (value) => update(() => text = value),
            onFieldSubmitted: multiline ? null : (_) => submit(),
            maxLength: label == 'Title' ? 120 : null,
            minLines: multiline ? 3 : 1,
            maxLines: multiline ? 8 : 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: text.trim().isEmpty ? null : submit,
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}
