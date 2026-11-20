import 'dart:convert';
import 'dart:math';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/journal_template.dart';
import '../data/document_task.dart';
import '../data/markdown_document.dart';
import '../data/markdown_library.dart';
import '../data/media.dart';
import '../data/paper.dart';
import '../data/quick_todos.dart';
import '../data/todo_items.dart';
import '../sync/notebook_sync.dart'
    show SettingsConflictNote, archivedSettingsConflictTag;
import '../ui/journal_calendar.dart';
import '../ui/journal_template_dialog.dart';
import '../ui/markdown_preview.dart';
import '../ui/noter_theme.dart';
import '../ui/todo_timer.dart';
import 'web_library.dart';
import 'web_note_archive.dart';
import 'web_document_page.dart';
import 'browser_library.dart' show downloadBrowserBytes;
import 'web_sync.dart';
import 'web_sync_page.dart';

typedef WebDownload = void Function(String name, String contents, String type);

class NotixerWebApp extends StatelessWidget {
  const NotixerWebApp({
    super.key,
    required this.library,
    required this.download,
    required this.sync,
  });

  final WebLibrary library;
  final WebDownload download;
  final WebSync sync;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Notixer',
    localizationsDelegates: const [DartPdfEditorLocalizations.delegate],
    theme: NoterTheme.light,
    builder: (context, child) =>
        Theme(data: NoterTheme.forWindow(context), child: child!),
    home: _Workspace(library: library, download: download, sync: sync),
  );
}

class _Workspace extends StatefulWidget {
  const _Workspace({
    required this.library,
    required this.download,
    required this.sync,
  });
  final WebLibrary library;
  final WebDownload download;
  final WebSync sync;

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
  List<QuickTodo> _quickTodos = [];
  bool _completedTasks = false;
  int _section = 0;
  String _query = '';
  String? _folder;
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
      await widget.sync.quickTodos.migrate();
      final quickTodos = await widget.sync.quickTodos.read();
      final notes = await widget.library.readAll();
      notes.sort((a, b) => b.modified.compareTo(a.modified));
      if (mounted) {
        setState(() {
          _notes = notes;
          _quickTodos = quickTodos;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _id() =>
      'note-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_random.nextInt(0x7fffffff).toRadixString(36)}';

  Future<void> _open(
    WebNote note, {
    bool newNote = false,
    String? heading,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            note.kind == WebNoteKind.pdf || note.kind == WebNoteKind.media
            ? WebDocumentPage(note: note, library: widget.library)
            : _Editor(
                note: note,
                previous: newNote ? null : note,
                library: widget.library,
                download: widget.download,
                onFollow: _followDocument,
                heading: heading,
              ),
      ),
    );
    if (mounted) await _load();
  }

  Future<bool> _followDocument(WebNote from, String href) async {
    final visible = _notes.where((note) => note.syncDocument);
    final target = MarkdownLibrary.target(
      visible.map(metadataForWebNote).toList(),
      metadataForWebNote(from),
      href,
    );
    final note = target == null ? null : _note(target.id);
    if (note == null || !mounted) return false;
    await _open(note, heading: Uri.parse(href).fragment);
    return true;
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

  Future<void> _createPaperNote(String pattern) async {
    final title = await _askText(context, 'New notebook', 'Title');
    if (title == null || !mounted) return;
    WebNote? note;
    await _perform(() async {
      final newNote = webNoteFromFile(
        _id(),
        title,
        pattern,
        await createPaper(pattern),
      );
      await widget.library.write(newNote, previous: null);
      note = newNote;
    });
    final saved = note;
    if (mounted && saved != null) await _open(saved);
  }

  Future<void> _import() => _perform(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Notixer files, Markdown, PDF, media and Web backups',
          extensions: [
            'md',
            'markdown',
            'json',
            'noter',
            'pdf',
            for (final format in MediaFormat.formats) format.extension,
          ],
        ),
      ],
    );
    if (file == null) return;
    final extension = file.name.toLowerCase().split('.').last;
    final media = MediaFormat.of(extension);
    final backup = extension == 'json';
    final binary = extension == 'pdf' || extension == 'noter' || media != null;
    if (await file.length() >
        (backup
            ? webBackupMaxBytes
            : binary
            ? 128 * 1024 * 1024
            : MarkdownDocument.maxTextBytes)) {
      throw const FormatException('The file is too large to import.');
    }
    final bytes = await file.readAsBytes();
    final source = binary ? '' : utf8.decode(bytes);
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
    final note = switch (extension) {
      'noter' => webNoteFromArchive(bytes),
      'pdf' => webNoteFromFile(_id(), title, 'pdf', bytes),
      _ when media != null => webNoteFromFile(
        _id(),
        title,
        'media:$extension',
        bytes,
      ),
      _ => WebNote(_id(), WebNoteKind.markdown, title, source, DateTime.now()),
    };
    if (extension == 'noter') {
      final added = await widget.library.importMissing([note]);
      if (mounted && added == 0) _message('This note already exists.');
    } else {
      await widget.library.write(note, previous: null);
    }
  });

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _backup() => _perform(() async {
    widget.download(
      'notixer-web-${journalDate(DateTime.now())}.json',
      encodeWebBackup([
        ...await widget.library.readAll(),
        ...await widget.sync.quickTodos.backup(),
      ]),
      'application/json',
    );
  });

  Future<void> _addTodo([String? supplied]) async {
    final text = supplied ?? await _askText(context, 'Add to-do', 'To-do');
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _perform(() async {
      final now = DateTime.now();
      await widget.sync.quickTodos.write(
        QuickTodo(
          id: _id(),
          text: text.trim().replaceAll(RegExp(r'[\r\n]+'), ' '),
          created: now,
          modified: now,
        ),
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

  WebNote? _journalNote(DateTime date) {
    final day = journalDate(date);
    return _note('journal-$day') ??
        _notes.where((note) => note.day == day).firstOrNull;
  }

  Future<void> _todayEntry() async {
    final draft = _newDay(_day);
    final note = _journalNote(_day);
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
            tooltip: 'Sync',
            onPressed: _busy
                ? null
                : () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => WebSyncPage(sync: widget.sync),
                      ),
                    );
                    if (mounted) await _load();
                  },
            icon: Icon(
              widget.sync.connected
                  ? Icons.cloud_sync_outlined
                  : Icons.cloud_outlined,
            ),
          ),
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
    final folders = _notes.map((note) => note.folder).nonNulls.toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final folder = folders.contains(_folder) ? _folder : null;
    final query = _query.toLowerCase();
    final visible = _notes
        .where(
          (note) =>
              note.syncDocument &&
              (folder == null || note.folder == folder) &&
              [
                note.title,
                note.source,
                ...note.tags,
                if (note.folder != null) note.folder!,
              ].any((value) => value.toLowerCase().contains(query)),
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
                  PopupMenuButton<String>(
                    tooltip: 'New notebook',
                    enabled: !_busy,
                    onSelected: _createPaperNote,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'blank', child: Text('Blank paper')),
                      PopupMenuItem(value: 'lined', child: Text('Lined paper')),
                      PopupMenuItem(value: 'grid', child: Text('Grid paper')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text('New notebook'),
                    ),
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
                  hintText: 'Search notes, contents and tags',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              if (folders.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey(folder),
                  initialValue: folder ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Folder'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All folders'),
                    ),
                    for (final name in folders)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                  onChanged: (value) =>
                      setState(() => _folder = value == '' ? null : value),
                ),
              ],
              const SizedBox(height: 12),
              if (visible.isEmpty && !_busy)
                Text(
                  query.isEmpty && folder == null
                      ? 'No notes yet.'
                      : 'No matching notes.',
                ),
            ],
          );
        }
        final note = visible[index - 1];
        final metadata = metadataForWebNote(note);
        final settingsConflict =
            metadata.isSettingsConflict && !metadata.isArchivedSettingsConflict;
        final (type, icon) = switch (note.kind) {
          _ when settingsConflict => ('Settings conflict', Icons.warning_amber),
          _ when note.id.startsWith('conflict_') => (
            'Sync conflict',
            Icons.warning_amber,
          ),
          WebNoteKind.pdf => ('PDF', Icons.picture_as_pdf_outlined),
          WebNoteKind.media => ('Media', Icons.perm_media_outlined),
          WebNoteKind.todo => ('To-do list', Icons.checklist),
          WebNoteKind.journal => ('Journal', Icons.calendar_today_outlined),
          _ => ('Markdown', Icons.description_outlined),
        };
        return ListTile(
          leading: Icon(icon),
          title: Text(note.title),
          subtitle: Text(
            [
              type,
              if (note.folder != null) note.folder!,
              ...note.tags.map((tag) => '#$tag'),
            ].join(' · '),
          ),
          onTap: _busy ? null : () => _open(note),
          trailing: PopupMenuButton<String>(
            tooltip: 'Note actions',
            enabled: !_busy,
            onSelected: (value) {
              if (value == 'organize') _organize(note);
              if (value == 'archive') _archiveConflict(note);
              if (value == 'download') _downloadArchive(note);
              if (value == 'delete') _deleteNote(note);
            },
            itemBuilder: (_) => [
              if (settingsConflict)
                const PopupMenuItem(
                  value: 'archive',
                  child: Text('Archive conflict'),
                ),
              const PopupMenuItem(
                value: 'organize',
                child: Text('Folders and tags'),
              ),
              const PopupMenuItem(
                value: 'download',
                child: Text('Download Notixer file'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        );
      },
    );
  }

  Future<void> _archiveConflict(WebNote note) => _perform(
    () => widget.library.write(
      note.organize('Archived settings conflicts', [
        ...note.tags.where((tag) => tag != 'Sync conflict'),
        archivedSettingsConflictTag,
      ]),
      previous: note,
    ),
  );

  Future<void> _deleteNote(WebNote note) async {
    if (!await _confirm(context, 'Delete this note?', 'Delete') || !mounted) {
      return;
    }
    await _perform(() => widget.library.delete(note));
  }

  Future<void> _downloadArchive(WebNote note) => _perform(() async {
    downloadBrowserBytes(
      '${note.title}.noter',
      archiveForWebNote(note),
      'application/zip',
    );
  });

  Future<void> _organize(WebNote note) async {
    var folder = note.folder ?? '';
    var tags = note.tags.join(', ');
    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Folders and tags'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: folder,
              decoration: const InputDecoration(labelText: 'Folder'),
              onChanged: (value) => folder = value.trim(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: tags,
              decoration: const InputDecoration(
                labelText: 'Tags separated by commas',
              ),
              onChanged: (value) => tags = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated != true || !mounted) return;
    final unique = tags
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    await _perform(
      () => widget.library.write(
        note.organize(folder.isEmpty ? null : folder, unique),
        previous: note,
      ),
    );
  }

  Future<void> _editQuickTodo(QuickTodo todo) async {
    var text = todo.text;
    var project = todo.project ?? '';
    var due = todo.due ?? '';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Plan to-do'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: text,
              onChanged: (value) => text = value,
              decoration: const InputDecoration(labelText: 'To-do'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: project,
              onChanged: (value) => project = value,
              decoration: const InputDecoration(labelText: 'Project'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: due,
              onChanged: (value) => due = value,
              decoration: const InputDecoration(
                labelText: 'Due date (YYYY-MM-DD)',
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
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || result != true) return;
    await _changeQuickTodo(
      todo,
      text: text.trim(),
      project: project.trim(),
      due: due.trim(),
    );
  }

  Future<void> _changeQuickTodo(
    QuickTodo previous, {
    bool? done,
    String? text,
    String? project,
    String? due,
    TodoTimerAction? timer,
  }) => _perform(() async {
    final updated = previous.update(
      DateTime.now(),
      text: text,
      done: done,
      timer: timer,
      project: project == '' ? null : project ?? previous.project,
      due: due == '' ? null : due ?? previous.due,
    );
    await widget.sync.quickTodos.write(
      QuickTodo.fromJson(updated.id, updated.toJson()),
      previous: previous,
    );
  });

  Future<void> _changeDocumentTodo(
    WebNote note,
    int offset, {
    bool? done,
    TodoTimerAction? timer,
  }) => _perform(() async {
    final source = updateDocumentTask(
      note.source,
      offset,
      done: done,
      timer: timer,
    );
    await widget.library.write(note.edit(note.title, source), previous: note);
  });

  Widget _tasks() {
    final visible = <(QuickTodo, WebNote?, int?)>[
      for (final task in _quickTodos)
        if (task.done == _completedTasks) (task, null, null),
      for (final note in _notes)
        if (note.kind == WebNoteKind.markdown ||
            note.kind == WebNoteKind.todo ||
            note.kind == WebNoteKind.journal)
          for (final item in todoListItems(note.source))
            if (item.done == _completedTasks)
              (
                documentTask(
                  note.source,
                  item.offset,
                  item.text,
                  fallback: note.modified,
                ),
                note,
                item.offset,
              ),
    ];
    if (_completedTasks) {
      visible.sort(
        (a, b) => b.$1.completionTime!.compareTo(a.$1.completionTime!),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Tasks', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add task'),
              onPressed: _busy ? null : _addTodo,
            ),
            for (final completed in [false, true])
              ChoiceChip(
                label: Text(completed ? 'Completed' : 'Open'),
                selected: completed == _completedTasks,
                onSelected: (_) => setState(() => _completedTasks = completed),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (visible.isEmpty)
          Text(_completedTasks ? 'No completed tasks.' : 'No open tasks.'),
        for (final (todo, note, offset) in visible)
          ListTile(
            dense: true,
            onTap: note == null || _busy ? null : () => _open(note),
            leading: Checkbox(
              value: todo.done,
              semanticLabel: todo.text,
              onChanged: _busy
                  ? null
                  : (value) => note == null
                        ? _changeQuickTodo(todo, done: value)
                        : _changeDocumentTodo(note, offset!, done: value),
            ),
            title: Text(todo.text),
            subtitle: Text(
              [
                ?note?.title,
                ?todo.project,
                ?todo.due,
                if (todo.completionTime case final completed?)
                  completedTaskLabel(context, completed),
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TodoTimer(
                  todo: todo,
                  onChanged: _busy
                      ? null
                      : (action) => note == null
                            ? _changeQuickTodo(todo, timer: action)
                            : _changeDocumentTodo(note, offset!, timer: action),
                ),
                if (note == null && !todo.done)
                  IconButton(
                    tooltip: 'Plan to-do',
                    icon: const Icon(Icons.edit_calendar_outlined),
                    onPressed: _busy ? null : () => _editQuickTodo(todo),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _journal() {
    final note = _journalNote(_day);
    void choose(DateTime day) {
      setState(() {
        _day = day;
        _month = DateTime(day.year, day.month);
      });
      final entry = _journalNote(day);
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
    required this.onFollow,
    this.heading,
  });
  final WebNote note;
  final WebNote? previous;
  final WebLibrary library;
  final WebDownload download;
  final Future<bool> Function(WebNote, String) onFollow;
  final String? heading;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late WebNote? _saved = widget.previous;
  late final _title = TextEditingController(text: widget.note.title);
  late final _source = TextEditingController(text: widget.note.source);
  late final _document = markdownForWebNote(widget.note);
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
  void initState() {
    super.initState();
    final heading = widget.heading;
    if (heading != null && heading.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _preview.currentState?.scrollToHeading(heading);
      });
    }
  }

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
      final note = (_saved ?? widget.note).edit(_title.text, source);
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
    } else if (_document.assets[href] case final bytes?) {
      downloadBrowserBytes(
        href.split('/').last,
        bytes,
        'application/octet-stream',
      );
    } else if (!await widget.onFollow(_saved ?? widget.note, href) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The linked file could not be found.')),
      );
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
                          modified: (_saved ?? widget.note).modified,
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
          document: _document.copy(source: _source.text),
          scrollController: _scroll,
          onToggle: (offset, checked) {
            if (!_busy) {
              _save(updateDocumentTask(_source.text, offset, done: checked));
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
    required this.modified,
  });

  final String source, heading;
  final DateTime modified;
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TodoTimer(
                todo: documentTask(
                  source,
                  item.offset,
                  item.text,
                  fallback: modified,
                ),
                onChanged: enabled
                    ? (action) => onChange(
                        updateDocumentTask(source, item.offset, timer: action),
                      )
                    : null,
              ),
              IconButton(
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
            ],
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
