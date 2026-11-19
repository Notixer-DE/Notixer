import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/file_gateway.dart';
import '../data/knowledge.dart';
import '../data/keyboard_shortcuts.dart';
import '../data/library_backup.dart';
import '../data/notebook.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    required this.repository,
    this.initialSection = 'Search',
    this.sharedText,
    this.onCompleteTask,
    this.autofocusSearch = false,
    this.shortcuts,
    this.onImportFile,
  });
  final LocalNotebookRepository repository;
  final String initialSection;
  final String? sharedText;
  final Future<void> Function(KnowledgeTask)? onCompleteTask;
  final bool autofocusSearch;
  final KeyboardShortcuts? shortcuts;
  final Future<void> Function(VoidCallback onImported)? onImportFile;
  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  late final _store = KnowledgeStore(widget.repository);
  late final _backup = LibraryBackup(widget.repository);
  late String _section = widget.initialSection;
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  final _hubFocus = FocusNode();
  String _tag = '', _folder = '', _kind = 'all';
  bool? _filtersExpanded;
  bool _onlyTasks = false,
      _busy = false,
      _searching = false,
      _cancelRequested = false;
  int _generation = 0, _completed = 0, _total = 0;
  String? _error, _backupStatus;
  KnowledgeScan? _scan;
  List<Notebook> _notes = [];
  List<File> _backups = [];
  DateTime _date = DateTime.now();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (widget.sharedText != null) {
        await _capture(widget.sharedText!);
      }
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          (_section == 'Tasks' || _section == 'Inbox')) {
        await _search();
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _searchFocus.dispose();
    _hubFocus.dispose();
    super.dispose();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _work(() async {
    await _store.reload();
    final notes = await widget.repository.list();
    final backups = await _backup.list();
    String? backupStatus;
    final statusFile = File('${_backup.directory.path}/status.json');
    if (await statusFile.exists()) {
      try {
        final status =
            jsonDecode(await statusFile.readAsString()) as Map<String, dynamic>;
        backupStatus = status['error'] == null
            ? 'Last automatic backup: ${status['lastSuccess']}'
            : 'Automatic backup failed: ${status['error']}';
      } catch (_) {
        backupStatus = 'Could not read automatic backup status.';
      }
    }
    if (mounted) {
      setState(() {
        _notes = notes;
        _backups = backups;
        _backupStatus = backupStatus;
      });
    }
  });

  Future<void> _reload() async {
    final refreshResults =
        _scan != null || _section == 'Tasks' || _section == 'Inbox';
    await _load();
    if (mounted && _error == null && refreshResults) await _search();
  }

  KnowledgeView get _view => KnowledgeView(
    '',
    query: _query.text.trim(),
    tag: _section == 'Inbox' ? 'Inbox' : _tag,
    folder: _folder,
    kind: _kind,
    openTasks: _section == 'Tasks' || (_section == 'Search' && _onlyTasks),
  );
  Future<void> _search() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _scan = null;
      _searching = true;
      _cancelRequested = false;
      _completed = 0;
      _total = 0;
    });
    try {
      final result = await _store.scan(
        _view,
        cancelled: () =>
            !mounted || generation != _generation || _cancelRequested,
        onProgress: (done, total) {
          if (mounted && generation == _generation) {
            setState(() {
              _completed = done;
              _total = total;
            });
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() {
          _scan = result;
          if (_cancelRequested) {
            _error = 'Search cancelled; partial results are shown.';
          }
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _searching = false;
        });
      }
    }
  }

  void _open(Notebook note, [String anchor = '']) =>
      Navigator.pop(context, (note: note, anchor: anchor));
  Future<String?> _name(
    String title, {
    String initial = '',
    String? helper,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          controller: controller,
          decoration: InputDecoration(labelText: 'Name', helperText: helper),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return value;
  }

  Future<void> _capture([String initial = '']) async {
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
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                ),
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
    if (value != null && mounted) {
      await _work(() async {
        final note = await _store.capture(value.$1, value.$2);
        if (mounted) _open(note, 'edit:end');
      });
    }
  }

  Future<void> _template([MarkdownTemplate? template]) async {
    final name = TextEditingController(text: template?.name),
        source = TextEditingController(text: template?.source);
    final value = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          template == null
              ? 'Create Markdown template'
              : 'Edit Markdown template',
        ),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Template name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: source,
                minLines: 8,
                maxLines: 18,
                decoration: const InputDecoration(
                  labelText: 'Markdown',
                  helperText: '{{date}} · {{weekday}} · {{year}} · {{title}}',
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
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(context, (name.text.trim(), source.text));
              }
            },
            child: const Text('Save template'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    source.dispose();
    if (value != null && mounted) {
      await _work(() async {
        final updated = MarkdownTemplate(
          template?.id ?? LocalNotebookRepository.newId(),
          value.$1,
          value.$2,
        );
        _store.templates = [
          ..._store.templates.where((t) => t.id != updated.id),
          updated,
        ];
        await _store.save();
      });
    }
  }

  Future<void> _saveView() async {
    final name = await _name('Save search view');
    if (name == null || name.isEmpty || !mounted) return;
    final view = _view;
    await _work(() async {
      _store.views = [
        ..._store.views.where((v) => v.name != name),
        KnowledgeView(
          name,
          query: view.query,
          tag: view.tag,
          folder: view.folder,
          kind: view.kind,
          openTasks: view.openTasks,
        ),
      ];
      await _store.save();
    });
  }

  Future<void> _complete(KnowledgeTask task) async {
    await _work(() async {
      if (!await FileGateway.prepareClose()) {
        throw const FormatException(
          'Save open documents before changing a task.',
        );
      }
      if (widget.onCompleteTask != null) {
        await widget.onCompleteTask!(task);
      } else {
        await _store.completeTask(task);
      }
    });
    if (_error == null && mounted) await _search();
  }

  Widget _results() {
    final scan = _scan;
    final filtersVisible =
        _filtersExpanded ?? NoterTheme.desktopControls(context);
    final activeFilters = [
      _kind != 'all',
      _section != 'Inbox' && _tag.isNotEmpty,
      _folder.isNotEmpty,
      _section == 'Search' && _onlyTasks,
    ].where((value) => value).length;
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextField(
                      controller: _query,
                      focusNode: _searchFocus,
                      autofocus: widget.autofocusSearch && _section == 'Search',
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        labelText: switch (_section) {
                          'Tasks' => 'Find an open task or file',
                          'Inbox' => 'Search the inbox',
                          _ => 'Search Markdown and PDFs',
                        },
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: filtersVisible
                                  ? 'Hide search filters'
                                  : 'Show search filters',
                              isSelected: filtersVisible,
                              onPressed: _busy
                                  ? null
                                  : () => setState(
                                      () => _filtersExpanded = !filtersVisible,
                                    ),
                              icon: Badge(
                                isLabelVisible: activeFilters > 0,
                                label: Text('$activeFilters'),
                                child: const Icon(Icons.filter_alt_outlined),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Search',
                              onPressed: _busy ? null : _search,
                              icon: const Icon(Icons.search),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (filtersVisible) const SizedBox(height: 8),
                    if (filtersVisible)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<String>(
                            value: _kind,
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('All files'),
                              ),
                              DropdownMenuItem(
                                value: 'markdown',
                                child: Text('Markdown'),
                              ),
                              DropdownMenuItem(
                                value: 'pdf',
                                child: Text('PDFs'),
                              ),
                              DropdownMenuItem(
                                value: 'media',
                                child: Text('Media'),
                              ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _kind = v!),
                          ),
                          if (_section != 'Inbox')
                            DropdownButton<String>(
                              value: _tag,
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('All tags'),
                                ),
                                for (final tag in {
                                  ..._notes
                                      .expand((n) => n.tags)
                                      .where((tag) => tag.isNotEmpty),
                                  if (_tag.isNotEmpty) _tag,
                                }.toList()..sort())
                                  DropdownMenuItem(
                                    value: tag,
                                    child: SizedBox(
                                      width: 100,
                                      child: Text(
                                        tag,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _tag = v!),
                            ),
                          DropdownButton<String>(
                            value: _folder,
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('All folders'),
                              ),
                              for (final folder
                                  in widget.repository.catalog.folders)
                                DropdownMenuItem(
                                  value: folder.id,
                                  child: SizedBox(
                                    width: 110,
                                    child: Text(
                                      folder.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              if (_folder.isNotEmpty &&
                                  widget.repository.catalog.folderName(
                                        _folder,
                                      ) ==
                                      null)
                                DropdownMenuItem(
                                  value: _folder,
                                  child: const SizedBox(
                                    width: 110,
                                    child: Text(
                                      'Unavailable folder',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _folder = v!),
                          ),
                          if (_section == 'Search')
                            FilterChip(
                              label: const Text('Open tasks only'),
                              selected: _onlyTasks,
                              onSelected: _busy
                                  ? null
                                  : (v) => setState(() => _onlyTasks = v),
                            ),

                          OutlinedButton(
                            onPressed: _busy ? null : _saveView,
                            child: const Text('Save view'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (_searching) Text('Scanning $_completed / $_total files…'),
              if (scan != null && scan.warnings.isNotEmpty)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Search warnings'),
                      content: SizedBox(
                        width: 400,
                        height: 260,
                        child: ListView(
                          children: [
                            for (final warning in scan.warnings)
                              ListTile(title: Text(warning)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: Text('${scan.warnings.length} indexing warnings'),
                ),
            ],
          ),
        ),
        if (scan == null || scan.hits.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                scan == null
                    ? (_section == 'Tasks'
                          ? 'Search to collect open checkboxes from every Markdown file.'
                          : 'Enter text, or leave it empty to list all matching files.')
                    : 'No matches.',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: scan.hits.length,
            itemBuilder: (context, index) {
              final hit = scan.hits[index];
              final task = scan.tasksByLocation['${hit.note.id}:${hit.anchor}'];
              return ListTile(
                leading: _view.openTasks && task != null
                    ? Checkbox(
                        value: false,
                        onChanged: _busy ? null : (_) => _complete(task),
                      )
                    : Icon(
                        hit.note.isMedia
                            ? Icons.perm_media_outlined
                            : hit.note.isMarkdown
                            ? Icons.description_outlined
                            : Icons.picture_as_pdf_outlined,
                      ),
                title: Text(
                  hit.snippet.trim().isEmpty ? '(Empty task)' : hit.snippet,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${hit.note.title}${hit.anchor.startsWith('line=')
                      ? ' · Line ${hit.anchor.substring(5)}'
                      : hit.anchor.startsWith('page=')
                      ? ' · Page ${hit.anchor.substring(5)}'
                      : ''}',
                ),
                onTap: _busy ? null : () => _open(hit.note, hit.anchor),
              );
            },
          ),
      ],
    );
  }

  Future<void> _openJournalDay(DateTime date) => _work(() async {
    final note = await _store.journal(date);
    if (mounted) _open(note, 'edit:end');
  });
  Future<void> _journalSettings() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Journal template'),
        content: SizedBox(
          width: 400,
          height: MediaQuery.sizeOf(context).height * .45,
          child: ListView(
            children: [
              ListTile(
                title: const Text('Blank entry'),
                trailing: _store.journalTemplate == null
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final template in _store.templates)
                ListTile(
                  title: Text(template.name),
                  trailing: _store.journalTemplate == template.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, template.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _section = 'Templates');
            },
            child: const Text('Manage templates'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      await _work(() async {
        _store.journalTemplate = selected.isEmpty ? null : selected;
        await _store.save();
      });
    }
  }

  Widget _journal() {
    final entries =
        _notes.where((note) => journalEntryDate(note) != null).toList()..sort(
          (a, b) => journalEntryDate(b)!.compareTo(journalEntryDate(a)!),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _date = DateTime(
                        _date.year,
                        _date.month,
                        _date.day - 1,
                      ),
                    ),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(1900),
                          lastDate: DateTime(2200),
                        );
                        if (date != null && mounted) {
                          setState(() => _date = date);
                        }
                      },
                child: Text(journalDate(_date)),
              ),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _date = DateTime(
                        _date.year,
                        _date.month,
                        _date.day + 1,
                      ),
                    ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              onPressed: _busy ? null : () => _openJournalDay(_date),
              child: const Text('Open day'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _openJournalDay(DateTime.now()),
              child: const Text('Today'),
            ),
            IconButton(
              tooltip: 'Journal template',
              onPressed: _busy ? null : _journalSettings,
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (final note in entries)
          ListTile(
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(note.title),
            subtitle: note.title == journalEntryDate(note)
                ? null
                : Text(journalEntryDate(note)!),
            onTap: () => _open(note, 'edit:end'),
          ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Open today to start your journal.'),
          ),
      ],
    );
  }

  Widget _templates() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ListTile(
        title: const Text('Reusable Markdown templates'),

        trailing: IconButton(
          tooltip: 'Create Markdown template',
          onPressed: _busy ? null : () => _template(),
          icon: const Icon(Icons.add),
        ),
      ),
      for (final template in _store.templates)
        ListTile(
          title: Text(template.name),
          subtitle: Text(
            template.source,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _template(template),
          trailing: IconButton(
            tooltip: 'Delete template',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    _store.templates.removeWhere((t) => t.id == template.id);
                    if (_store.journalTemplate == template.id) {
                      _store.journalTemplate = null;
                    }
                    await _store.save();
                  }),
          ),
        ),
    ],
  );
  Widget _tags() {
    final tags = <String, (String, int)>{};
    for (final note in _notes) {
      final unique = <String, String>{
        for (final tag
            in note.tags
                .map((tag) => tag.trim())
                .where((tag) => tag.isNotEmpty))
          tag.toLowerCase(): tag,
      };
      for (final tag in unique.values) {
        final key = tag.toLowerCase();
        tags[key] = (tags[key]?.$1 ?? tag, (tags[key]?.$2 ?? 0) + 1);
      }
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Rename a tag or merge it into an existing tag. Leave the new name empty to remove that tag from all files.',
        ),
        for (final entry in tags.entries)
          ListTile(
            title: Text('#${entry.value.$1}'),
            subtitle: Text('${entry.value.$2} files'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy
                ? null
                : () async {
                    final value = await _name(
                      'Rename or merge tag',
                      initial: entry.value.$1,
                      helper: 'Empty name removes the tag.',
                    );
                    if (value == null || !mounted) return;
                    await _work(() async {
                      if (!await FileGateway.prepareClose()) {
                        throw const FormatException(
                          'Could not save open files.',
                        );
                      }
                      await _store.renameTag(entry.value.$1, value);
                      _notes = await widget.repository.list();
                      if (_tag.toLowerCase() == entry.value.$1.toLowerCase()) {
                        _tag = value;
                      }
                    });
                  },
          ),
      ],
    );
  }

  Widget _views() => ListView(
    children: [
      if (_store.views.isEmpty)
        const ListTile(
          title: Text('Saved search views'),
          subtitle: Text(
            'Save combinations of text, type, folder, tag and open-task filters from Search.',
          ),
        ),
      for (final view in _store.views)
        ListTile(
          title: Text(view.name),
          subtitle: Text(
            [
              view.query,
              view.tag,
              view.kind,
              if (view.openTasks) 'Open tasks',
            ].where((v) => v.isNotEmpty).join(' · '),
          ),
          onTap: _busy
              ? null
              : () {
                  setState(() {
                    _section = 'Search';
                    _query.text = view.query;
                    _tag = view.tag;
                    _kind = view.kind;
                    _folder = view.folder;
                    _onlyTasks = view.openTasks;
                  });
                  _search();
                },
          trailing: IconButton(
            tooltip: 'Delete saved view',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    _store.views.remove(view);
                    await _store.save();
                  }),
          ),
        ),
    ],
  );
  Widget _backupPage() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_backupStatus != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_backupStatus!),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          tooltip: 'About backups',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Library backups'),
              content: const SingleChildScrollView(
                child: Text(
                  'Keep the latest seven local snapshots. Export copies to separate storage to protect against device loss. Restore adds copies and preserves existing notes. Library snapshots support up to 512 MB.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
      SwitchListTile(
        title: const Text('Automatic backups'),
        subtitle: const Text(
          'While the app is running, every 15 minutes when the library changes.',
        ),
        value: _store.automaticBackups,
        onChanged: _busy
            ? null
            : (v) => _work(() async {
                _store.automaticBackups = v;
                await _store.save();
              }),
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy
                ? null
                : () => _work(() async {
                    if (!await FileGateway.prepareClose()) {
                      throw const FormatException('Could not save open files.');
                    }
                    await _backup.create();
                    _backups = await _backup.list();
                  }),
            child: const Text('Create backup'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _work(() async {
                    final file = await FileGateway().pick();
                    if (file == null) return;
                    if (await file.length() > LibraryBackup.maxBytes) {
                      throw const FormatException('Backup exceeds 512 MB.');
                    }
                    final notes = await _backup.restore(
                      await file.readAsBytes(),
                    );
                    await _store.reload();
                    _notes = await widget.repository.list();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Restored ${notes.length} files as copies.',
                          ),
                        ),
                      );
                    }
                  }),
            child: const Text('Restore backup as copies'),
          ),
        ],
      ),
      for (final file in _backups)
        ListTile(
          title: Text(file.uri.pathSegments.last),
          trailing: IconButton(
            tooltip: 'Export backup',
            icon: const Icon(Icons.save_alt),
            onPressed: _busy
                ? null
                : () => _work(() async {
                    await FileGateway().save(
                      file.uri.pathSegments.last,
                      await file.readAsBytes(),
                      'application/zip',
                    );
                  }),
          ),
        ),
    ],
  );
  void _selectSection(String section) {
    if (widget.shortcuts != null) _hubFocus.requestFocus();
    setState(() {
      _section = section;
      _scan = null;
      if (section == 'Tasks' || section == 'Inbox') {
        _kind = 'all';
        _query.clear();
        _folder = '';
        _tag = '';
      }
    });
    if (section == 'Tasks' || section == 'Inbox') unawaited(_search());
  }

  KeyEventResult _handleShortcut(FocusNode node, KeyEvent event) {
    if (_busy || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    switch (widget.shortcuts?.match(event)) {
      case AppShortcut.knowledgeSearch:
        if (_section != 'Search') _selectSection('Search');
        _searchFocus.requestFocus();
      case AppShortcut.knowledgeTasks:
        _selectSection('Tasks');
      case AppShortcut.knowledgeJournal:
        _selectSection('Journal');
      case AppShortcut.knowledgeViews:
        _selectSection('Views');
      case AppShortcut.knowledgeBackups:
        _selectSection('Backups');
      case AppShortcut.knowledgeCapture:
        unawaited(_capture());
      case AppShortcut.knowledgeSubmit:
        if (!['Search', 'Tasks', 'Inbox'].contains(_section)) {
          return KeyEventResult.ignored;
        }
        unawaited(_search());
      case AppShortcut.importFile when widget.onImportFile != null:
        unawaited(
          widget.onImportFile!(() {
            if (mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).pop();
            }
          }),
        );
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _hubFocus,
    autofocus: widget.shortcuts != null && !widget.autofocusSearch,
    onKeyEvent: _handleShortcut,
    child: _buildPage(),
  );

  static const _primarySections = [
    ('Search', Icons.search),
    ('Tasks', Icons.checklist),
    ('Journal', Icons.calendar_today_outlined),
  ];
  static const _otherSections = [
    ('Inbox', Icons.inbox_outlined),
    ('Tags', Icons.sell_outlined),
    ('Views', Icons.bookmark_border),
    ('Templates', Icons.dashboard_customize_outlined),
    ('Backups', Icons.backup_outlined),
  ];

  Widget _sectionTile(String title, IconData icon, VoidCallback? onTap) =>
      ListTile(
        key: ValueKey('knowledge-section-$title'),
        title: Text(title),
        leading: Icon(icon, size: 20),
        selected: _section == title,
        selectedTileColor: NoterTheme.active,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        onTap: onTap,
      );

  Widget _sectionList(List<Widget> children, {bool shrinkWrap = false}) =>
      ListTileTheme(
        data: ListTileThemeData(
          minLeadingWidth: 18,
          horizontalTitleGap: 10,
          dense: NoterTheme.desktopControls(context),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          titleTextStyle: Theme.of(context).textTheme.bodyMedium,
        ),
        child: ListView(
          padding: const EdgeInsets.all(12),
          shrinkWrap: shrinkWrap,
          children: children,
        ),
      );

  Widget _sidebar() => SizedBox(
    width: 220,
    child: WorkspaceSidebar(
      key: const ValueKey('knowledge-sidebar'),
      child: Material(
        color: Colors.white,
        child: _sectionList([
          for (final (title, icon) in _primarySections)
            _sectionTile(
              title,
              icon,
              _busy ? null : () => _selectSection(title),
            ),
          const Divider(),
          for (final (title, icon) in _otherSections)
            _sectionTile(
              title,
              icon,
              _busy ? null : () => _selectSection(title),
            ),
        ]),
      ),
    ),
  );

  Future<void> _openSections() async {
    final section = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: _sectionList([
          for (final (title, icon) in _otherSections)
            _sectionTile(title, icon, () => Navigator.pop(context, title)),
        ], shrinkWrap: true),
      ),
    );
    if (mounted && !_busy && section != null) _selectSection(section);
  }

  Widget _bottomNavigation() {
    final index = _primarySections.indexWhere((entry) => entry.$1 == _section);
    return NavigationBar(
      selectedIndex: index == -1 ? _primarySections.length : index,
      onDestinationSelected: (index) {
        if (_busy) return;
        if (index == _primarySections.length) {
          unawaited(_openSections());
        } else {
          _selectSection(_primarySections[index].$1);
        }
      },
      destinations: [
        for (final (title, icon) in _primarySections)
          NavigationDestination(
            key: ValueKey('knowledge-section-$title'),
            enabled: !_busy,
            icon: Icon(icon),
            label: title,
          ),
        NavigationDestination(
          key: const ValueKey('knowledge-more-sections'),
          enabled: !_busy,
          icon: const Icon(Icons.more_horiz),
          label: index == -1 ? _section : 'More',
          tooltip: 'More sections',
        ),
      ],
    );
  }

  Widget _buildPage() {
    final desktop = NoterTheme.desktopControls(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge hub'),
        toolbarHeight: NoterTheme.headerHeight(context),
        actions: [
          IconButton(
            tooltip: 'Quick capture',
            onPressed: _busy ? null : _capture,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: desktop ? null : _bottomNavigation(),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (desktop) _sidebar(),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: _sectionBody(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBody() => Column(
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_searching)
        TextButton(
          onPressed: _cancelRequested
              ? null
              : () => setState(() => _cancelRequested = true),
          child: Text(
            _cancelRequested ? 'Finishing current file…' : 'Cancel search',
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _error!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: KeyedSubtree(
          key: ValueKey(_section),
          child: switch (_section) {
            'Journal' => _journal(),
            'Tags' => _tags(),
            'Templates' => _templates(),
            'Views' => _views(),
            'Backups' => _backupPage(),
            _ => _results(),
          },
        ),
      ),
    ],
  );
}
