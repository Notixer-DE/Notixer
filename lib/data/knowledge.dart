import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'journal_template.dart';
import 'document_task.dart';
import 'file_gateway.dart';
import 'linked_tasks.dart';
import 'markdown_document.dart';
import 'markdown_library.dart';
import 'notebook.dart';
import 'pdf_search.dart';
import 'quick_todos.dart';
import 'todo_list.dart';

export 'journal_template.dart';

part 'knowledge_index.dart';

typedef KnowledgeDestination = ({Notebook note, String anchor});

/// Journal identity survives renaming titles/tags and restoring linked copies.
String? journalEntryDate(Notebook note) {
  if (!note.isMarkdown) return null;
  final path = RegExp(
    r'(?:^|/)journals/(\d{4}-\d{2}-\d{2})\.md$',
  ).firstMatch(note.documentPath);
  if (path != null) return path[1];
  final id = RegExp(r'^journal-(\d{4}-\d{2}-\d{2})$').firstMatch(note.id);
  if (id != null) return id[1];
  return note.tags.any((tag) => tag.toLowerCase() == 'journal') &&
          RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(note.title)
      ? note.title
      : null;
}

class KnowledgeView {
  const KnowledgeView(
    this.name, {
    this.query = '',
    this.tag = '',
    this.folder = '',
    this.kind = 'all',
    this.openTasks = false,
    this.completedTasks = false,
  });
  final String name, query, tag, folder, kind;
  final bool openTasks, completedTasks;
  bool get tasksOnly => openTasks || completedTasks;
  Map<String, Object> toJson() => {
    'name': name,
    'query': query,
    'tag': tag,
    'folder': folder,
    'kind': kind,
    'openTasks': openTasks,
    if (completedTasks) 'completedTasks': true,
  };
  factory KnowledgeView.fromJson(Map<String, dynamic> value) {
    if (value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        !['all', 'markdown', 'pdf', 'media'].contains(value['kind'] ?? 'all') ||
        [
          'query',
          'tag',
          'folder',
        ].any((key) => value[key] != null && value[key] is! String) ||
        (value['openTasks'] != null && value['openTasks'] is! bool) ||
        (value['completedTasks'] != null && value['completedTasks'] is! bool)) {
      throw const FormatException('Invalid saved view.');
    }
    return KnowledgeView(
      value['name'] as String,
      query: value['query'] as String? ?? '',
      tag: value['tag'] as String? ?? '',
      folder: value['folder'] as String? ?? '',
      kind: value['kind'] as String? ?? 'all',
      openTasks: value['openTasks'] as bool? ?? false,
      completedTasks: value['completedTasks'] as bool? ?? false,
    );
  }
}

/// Validate preferences completely before a restore writes notebook copies.
void validateKnowledgeSettings(Map<String, dynamic> value) {
  if (value['version'] != 1 ||
      value['templates'] is! List ||
      value['views'] is! List ||
      (value['automaticBackups'] != null &&
          value['automaticBackups'] is! bool) ||
      (value['journalTemplate'] != null &&
          value['journalTemplate'] is! String)) {
    throw const FormatException('Invalid knowledge settings.');
  }
  final ids = <String>{};
  for (final row in value['templates'] as List) {
    if (row is! Map ||
        row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        !ids.add(row['id'] as String) ||
        row['name'] is! String ||
        (row['name'] as String).trim().isEmpty ||
        row['source'] is! String ||
        utf8.encode(row['source'] as String).length >
            MarkdownDocument.maxTextBytes) {
      throw const FormatException('Invalid Markdown template.');
    }
  }
  for (final row in value['views'] as List) {
    if (row is! Map) throw const FormatException('Invalid saved view.');
    KnowledgeView.fromJson(Map<String, dynamic>.from(row));
  }
  if (utf8.encode(jsonEncode(value)).length > 8 * 1024 * 1024) {
    throw const FormatException('Knowledge settings exceed 8 MB.');
  }
}

class KnowledgeTask {
  const KnowledgeTask(
    this.note,
    this.offset,
    this.line,
    this.text,
    this.revision, {
    this.canPlan = false,
    this.quickTodo,
    this.documentTodo,
    this.timerAction,
    this.workTime,
    this.countdown,
    this.deleting = false,
  });
  final Notebook note;
  final int offset, line;
  final String text, revision;
  final bool canPlan, deleting;
  final QuickTodo? quickTodo, documentTodo;
  final TodoTimerAction? timerAction;
  final Duration? workTime, countdown;
  QuickTodo? get todo => quickTodo ?? documentTodo;
  bool get done => todo?.done ?? false;

  KnowledgeTask withTimer({
    TodoTimerAction? timer,
    Duration? workTime,
    Duration? countdown,
  }) => KnowledgeTask(
    note,
    offset,
    line,
    text,
    revision,
    canPlan: canPlan,
    quickTodo: quickTodo,
    documentTodo: documentTodo,
    timerAction: timer,
    workTime: workTime,
    countdown: countdown,
  );

  KnowledgeTask forDeletion() => KnowledgeTask(
    note,
    offset,
    line,
    text,
    revision,
    quickTodo: quickTodo,
    documentTodo: documentTodo,
    deleting: true,
  );

  KnowledgeTask afterQuickTodoTimerEdit(QuickTodo updated) => KnowledgeTask(
    note,
    offset,
    line,
    text,
    updated.revision,
    canPlan: canPlan,
    quickTodo: updated,
  );

  KnowledgeTask afterDocumentTimerEdit(String source, DateTime modified) =>
      KnowledgeTask(
        note,
        offset,
        line,
        text,
        markdownRevision(source),
        canPlan: canPlan,
        documentTodo: documentTask(source, offset, text, fallback: modified),
      );

  String editDocument(String source) {
    if (markdownRevision(source) != revision ||
        !markdownTaskOffsets(source).contains(offset) ||
        (source[offset] != ' ') != done) {
      throw const FormatException('The task changed. Reload the task list.');
    }
    if (deleting) return deleteDocumentTaskLine(source, offset);
    return updateDocumentTask(
      source,
      offset,
      done: timerAction == null && workTime == null ? !done : null,
      timer: timerAction,
      workTime: workTime,
      countdown: countdown,
      previousModified: note.modified,
    );
  }

  String get anchor => quickTodo == null ? 'line=$line' : 'task';
  String? get due => quickTodo?.due ?? quickTodoDueDate(note);
}

String markdownRevision(String source) =>
    sha256.convert(utf8.encode(source)).toString();
List<({int offset, int line, String text})> markdownOpenTasks(String source) =>
    _openTasks(source, markdownTaskOffsets(source));

List<({int offset, int line, String text})> _openTasks(
  String source,
  List<int> offsets, {
  bool completed = false,
}) {
  final tasks = <({int offset, int line, String text})>[];
  var line = 1, nextBreak = source.indexOf('\n');
  for (final offset in offsets) {
    if ((source[offset] != ' ') != completed) continue;
    while (nextBreak >= 0 && nextBreak < offset) {
      line++;
      nextBreak = source.indexOf('\n', nextBreak + 1);
    }
    final end = source.indexOf('\n', offset);
    tasks.add((
      offset: offset,
      line: line,
      text: visibleTaskText(
        source.substring(offset + 2, end < 0 ? source.length : end).trimRight(),
      ).trim(),
    ));
  }
  return tasks;
}

class KnowledgeHit {
  const KnowledgeHit(this.note, this.snippet, this.anchor);
  final Notebook note;
  final String snippet, anchor;
}

class KnowledgeScan {
  KnowledgeScan(this.hits, this.tasks, this.warnings)
    : tasksByLocation = {
        for (final task in tasks) '${task.note.id}:${task.anchor}': task,
      };
  final List<KnowledgeHit> hits;
  final List<KnowledgeTask> tasks;
  final Map<String, KnowledgeTask> tasksByLocation;
  final List<String> warnings;
}

/// Shared, local preferences. Notes, journal entries and tags remain ordinary
/// portable notebook documents; this file contains only views and templates.
const unsortedTodos = 'Unsorted to-dos';
const _quickTodoTag = 'Quick to-do';
final _dueTag = RegExp(r'^Due: (\d{4}-\d{2}-\d{2})$', caseSensitive: false);

bool _isQuickTodo(Notebook note) =>
    note.isMarkdown && !note.isTodoList && note.tags.any(_isTodoTag);

bool _isTodoTag(String tag) =>
    tag.toLowerCase() == unsortedTodos.toLowerCase() ||
    tag.toLowerCase() == _quickTodoTag.toLowerCase();

String? quickTodoDueDate(Notebook note) {
  for (final tag in note.tags) {
    final date = _dueTag.firstMatch(tag)?[1];
    if (date == null) continue;
    final parsed = DateTime.tryParse(date);
    if (parsed != null && parsed.year > 0 && journalDate(parsed) == date) {
      return date;
    }
  }
  return null;
}

class KnowledgeStore {
  KnowledgeStore(this.repository);
  final LocalNotebookRepository repository;
  File get file => File(p.join(repository.directory.path, '.knowledge.json'));
  List<MarkdownTemplate> templates = [defaultJournalTemplate];
  List<KnowledgeView> views = [];
  String? journalTemplate = 'daily';
  bool automaticBackups = true;
  static final _journalQueues = <String, Future<void>>{};
  static final _settingsQueues = <String, Future<void>>{};
  String get _settingsKey => file.absolute.path;
  Future<void>? get _queue => _settingsQueues[_settingsKey];
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load();
  Future<void> reload() async {
    await _queue;
    _loading = null;
    await load();
  }

  Future<void> _load() async {
    if (!await file.exists()) {
      templates = [defaultJournalTemplate];
      views = [];
      journalTemplate = 'daily';
      automaticBackups = true;
      return;
    }
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('Knowledge settings exceed 8 MB.');
    }
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    validateKnowledgeSettings(value);
    templates = [
      for (final row in value['templates'] as List)
        MarkdownTemplate(
          row['id'] as String,
          row['name'] as String,
          row['source'] as String,
        ),
    ];
    views = [
      for (final row in value['views'] as List)
        KnowledgeView.fromJson(Map<String, dynamic>.from(row)),
    ];
    journalTemplate = value['journalTemplate'] as String?;
    automaticBackups = value['automaticBackups'] as bool? ?? true;
  }

  Future<void> updateSettings(void Function(KnowledgeStore) update) =>
      _writeSettings(() async {
        await _load();
        update(this);
        await _persist(_settingsSnapshot());
      });

  Future<void> save() {
    final snapshot = _settingsSnapshot();
    return _writeSettings(() => _persist(snapshot));
  }

  Future<void> _writeSettings(Future<void> Function() write) {
    final result = (_queue ?? Future<void>.value()).then((_) => write());
    late final Future<void> pending;
    pending = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_settingsQueues[_settingsKey], pending)) {
            _settingsQueues.remove(_settingsKey);
          }
        });
    _settingsQueues[_settingsKey] = pending;
    return result;
  }

  String _settingsSnapshot() {
    final value = <String, dynamic>{
      'version': 1,
      'templates': templates.map((t) => t.toJson()).toList(),
      'views': views.map((v) => v.toJson()).toList(),
      'journalTemplate': journalTemplate,
      'automaticBackups': automaticBackups,
    };
    validateKnowledgeSettings(value);
    final snapshot = jsonEncode(value);
    if (utf8.encode(snapshot).length > 8 * 1024 * 1024) {
      throw const FormatException('Knowledge settings exceed 8 MB.');
    }
    return snapshot;
  }

  Future<void> _persist(String snapshot) async {
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.readAsString() == snapshot) return;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(snapshot, flush: true);
    await temporary.rename(file.path);
  }

  Future<T> _writeJournal<T>(Future<T> Function() write) {
    final key = repository.directory.absolute.path;
    final result = (_journalQueues[key] ?? Future<void>.value()).then(
      (_) => write(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _journalQueues[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_journalQueues[key], tail)) _journalQueues.remove(key);
      }),
    );
    return result;
  }

  Future<Notebook?> _journalNote(String day) async {
    final notes = await repository.list();
    return notes.where((note) => note.id == 'journal-$day').firstOrNull ??
        notes.where((note) => journalEntryDate(note) == day).firstOrNull;
  }

  Notebook _newJournalNote(String day, DateTime now) => Notebook(
    id: 'journal-$day',
    title: day,
    paper: 'markdown',
    created: now,
    modified: now,
    tags: const ['Journal'],
    linkPath: 'journals/$day.md',
  );

  MarkdownDocument _newJournalDocument(DateTime date, {String? templateId}) {
    final day = journalDate(date);
    final template = templates
        .where((entry) => entry.id == (templateId ?? journalTemplate))
        .firstOrNull;
    return MarkdownDocument(template?.render(date, day) ?? '# $day\n\n');
  }

  Future<Notebook> journal(DateTime date, {String? templateId}) =>
      _writeJournal(() async {
        await reload();
        final day = journalDate(date);
        final existing = await _journalNote(day);
        if (existing != null) return existing;
        return repository.save(
          _newJournalNote(day, DateTime.now()),
          _newJournalDocument(date, templateId: templateId).encode(),
        );
      });

  Future<Notebook> appendJournal(
    DateTime day,
    String text, {
    required String entryId,
    required DateTime recordedAt,
  }) => _writeJournal(() async {
    if (text.trim().isEmpty ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(entryId)) {
      throw const FormatException('Enter a journal entry.');
    }
    await reload();
    final date = journalDate(day);
    final existing = await _journalNote(date);
    final snapshot = existing == null
        ? null
        : await repository.snapshotForSync(existing.id);
    if (existing != null && snapshot == null) {
      throw const FormatException('The journal day was removed. Try again.');
    }
    final (note, document) = snapshot == null
        ? (_newJournalNote(date, recordedAt), _newJournalDocument(day))
        : await LocalNotebookRepository.decodeValidated(snapshot.archive).then(
            (decoded) async =>
                (decoded.$1, await decodeMarkdownAsync(decoded.$2)),
          );
    final marker = '<!-- notixer-journal:$entryId -->';
    if (document.source.split('\n').contains(marker)) return note;
    final hour = recordedAt.hour.toString().padLeft(2, '0');
    final minute = recordedAt.minute.toString().padLeft(2, '0');
    final updated = note.copy(modified: DateTime.now());
    final archive = await LocalNotebookRepository.encodeAsync(
      updated,
      document
          .copy(
            source:
                '${document.source.trimRight()}\n\n$marker\n\n'
                '### $hour:$minute\n\n${text.trim()}\n',
          )
          .encode(),
    );
    await repository.applySync(updated.id, snapshot?.raw, archive);
    return updated;
  });

  Future<Notebook> capture(String title, String source) async {
    if (title.trim().isEmpty && source.trim().isEmpty) {
      throw const FormatException('Enter a title or some text.');
    }
    final now = DateTime.now();
    return repository.save(
      Notebook(
        id: LocalNotebookRepository.newId(),
        title: title.trim().isEmpty
            ? 'Quick capture · ${journalDate(now)}'
            : title.trim(),
        paper: 'markdown',
        created: now,
        modified: now,
        tags: const ['Inbox'],
      ),
      MarkdownDocument(source).encode(),
    );
  }

  QuickTodoStore get quickTodos => QuickTodoStore(repository.directory);

  String _quickTodoText(String value) {
    final text = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (text.isEmpty) throw const FormatException('Enter a to-do.');
    return text;
  }

  Future<QuickTodo> addQuickTodo(
    String text, {
    String? projectId,
    DateTime? due,
  }) async {
    final task = _quickTodoText(text);
    if (projectId != null) {
      await repository.catalog.load();
      if (!repository.catalog.folders.any((folder) => folder.id == projectId)) {
        throw const FormatException('The project was removed.');
      }
    }
    if (due != null && (due.year < 1 || due.year > 9999)) {
      throw const FormatException('Choose a valid due date.');
    }
    final now = DateTime.now();
    final todo = QuickTodo(
      id: LocalNotebookRepository.newId(),
      text: task,
      created: now,
      modified: now,
      project: projectId,
      due: due == null ? null : journalDate(due),
    );
    await quickTodos.change((tasks) => tasks[todo.id] = todo);
    return todo;
  }

  /// Copy the previous one-checkbox format before retiring its file to Trash.
  /// Notes with extra content, attachments or custom tags remain documents.
  Future<bool> migrateQuickTodos(
    List<Notebook> notes, {
    required bool Function(String id) isOpen,
  }) async {
    final migrated = <({QuickTodo task, String id, Uint8List raw})>[];
    for (final note in notes.where(_isQuickTodo)) {
      if (isOpen(note.id)) continue;
      final snapshot = await repository.snapshotForSync(note.id);
      if (snapshot == null) continue;
      final (current, bytes) = await LocalNotebookRepository.decodeValidated(
        snapshot.archive,
      );
      if (!_isQuickTodo(current) ||
          current.linkPath != null ||
          current.tags.any(
            (tag) => !_isTodoTag(tag) && !_dueTag.hasMatch(tag),
          )) {
        continue;
      }
      final document = await decodeMarkdownAsync(bytes);
      final match = RegExp(
        r'^- \[([ xX])\] ([^\r\n]+)\r?\n?$',
      ).firstMatch(document.source);
      if (match == null ||
          document.assets.isNotEmpty ||
          match[2]!.trim().isEmpty ||
          current.title != match[2]!.trim() ||
          isOpen(current.id)) {
        continue;
      }
      migrated.add((
        id: current.id,
        raw: snapshot.raw,
        task: QuickTodo(
          id: 'legacy-${current.id}',
          text: match[2]!.trim(),
          created: current.created,
          modified: current.modified,
          done: match[1] != ' ',
          project: current.folderId,
          due: quickTodoDueDate(current),
        ),
      ));
    }
    if (migrated.isEmpty) return false;
    await quickTodos.change((tasks) {
      for (final entry in migrated) {
        final previous = tasks[entry.task.id];
        if (previous == null || entry.task.supersedes(previous)) {
          tasks[entry.task.id] = entry.task;
        }
      }
    });
    for (final entry in migrated) {
      if (isOpen(entry.id)) continue;
      try {
        await repository.applySync(entry.id, entry.raw, null);
      } catch (_) {
        // Another refresh can finish retiring the same archive.
        if (await repository.snapshotForSync(entry.id) != null) rethrow;
      }
    }
    return true;
  }

  Future<Notebook?> planQuickTodo(
    KnowledgeTask task, {
    required String? projectId,
    String? newProject,
    String? text,
    required DateTime? due,
  }) async {
    if (due != null && (due.year < 1 || due.year > 9999)) {
      throw const FormatException('Choose a valid due date.');
    }
    await repository.catalog.load();
    final project = newProject != null
        ? await repository.catalog.ensureFolder(newProject)
        : repository.catalog.folders
              .where((f) => f.id == projectId)
              .firstOrNull;
    if (projectId != null && project == null) {
      throw const FormatException('The project was removed.');
    }
    final date = due == null ? null : journalDate(due);
    if (task.quickTodo != null) {
      await _changeQuickTodo(
        task.quickTodo!,
        project: project?.id,
        due: date,
        text: text == null ? null : _quickTodoText(text),
      );
      return null;
    }
    final snapshot = await repository.snapshotForSync(task.note.id);
    if (snapshot == null) throw const FormatException('The to-do was removed.');
    final (current, bytes) = await LocalNotebookRepository.decodeValidated(
      snapshot.archive,
    );
    final document = await decodeMarkdownAsync(bytes);
    final offsets = markdownTaskOffsets(document.source);
    if (!_isQuickTodo(current) ||
        markdownRevision(document.source) != task.revision ||
        offsets.singleOrNull != task.offset ||
        document.source[task.offset] != ' ' ||
        current.folderId != task.note.folderId ||
        quickTodoDueDate(current) != quickTodoDueDate(task.note)) {
      throw const FormatException('The to-do changed. Reload the task list.');
    }
    if (project?.id == current.folderId && date == quickTodoDueDate(current)) {
      return current;
    }
    // Tags keep the planning date portable across archive and client versions.
    final updated = current.copy(
      folderId: project?.id,
      folderName: project?.name,
      clearFolder: project == null,
      modified: DateTime.now(),
      tags: [
        ...current.tags.where(
          (tag) => !_isTodoTag(tag) && !_dueTag.hasMatch(tag),
        ),
        project == null ? unsortedTodos : _quickTodoTag,
        if (date != null) 'Due: $date',
      ],
    );
    final archive = await LocalNotebookRepository.encodeAsync(updated, bytes);
    await repository.applySync(current.id, snapshot.raw, archive);
    return updated;
  }

  Future<QuickTodo> changeQuickTodoTimer(
    String id, {
    TodoTimerAction? timer,
    Duration? workTime,
    Duration? countdown,
  }) => quickTodos.change((tasks) {
    final current = tasks[id];
    if (current == null || current.deleted) {
      throw const FormatException('The to-do no longer exists.');
    }
    return tasks[id] = current.update(
      DateTime.now(),
      project: current.project,
      due: current.due,
      timer: timer,
      workTime: workTime,
      countdown: countdown,
    );
  });

  Future<void> changeTaskStatus(QuickTodo todo, bool done) =>
      _changeQuickTodo(todo, complete: done);

  Future<void> _changeQuickTodo(
    QuickTodo expected, {
    String? project,
    String? due,
    String? text,
    bool? complete,
    TodoTimerAction? timer,
    Duration? workTime,
    Duration? countdown,
    bool delete = false,
  }) => quickTodos.change((tasks) {
    final current = tasks[expected.id];
    if (current == null ||
        current.deleted ||
        current.revision != expected.revision) {
      throw const FormatException('The to-do changed. Reload the task list.');
    }
    if (delete) {
      tasks[current.id] = current.delete(DateTime.now());
      return;
    }
    final preservePlan = complete != null || timer != null || workTime != null;
    tasks[current.id] = current.update(
      DateTime.now(),
      project: preservePlan ? current.project : project,
      due: preservePlan ? current.due : due,
      text: text,
      done: complete,
      timer: timer,
      workTime: workTime,
      countdown: countdown,
    );
  });

  Future<Notebook> sourceNote(Notebook source, int page, String quote) async {
    if (quote.trim().isEmpty || page < 1) {
      throw const FormatException('Select PDF text first.');
    }
    final now = DateTime.now();
    final note = Notebook(
      id: LocalNotebookRepository.newId(),
      title: 'Source · ${source.title}',
      paper: 'markdown',
      created: now,
      modified: now,
      tags: const ['Inbox', 'Source'],
    );
    final search = quote.replaceAll(RegExp(r'\s+'), ' ').trim();
    final fragment =
        'page=$page&quote=${Uri.encodeComponent(search.length > 160 ? search.substring(0, 160) : search)}';
    final href = '${MarkdownLibrary.linkTo(note, source)}#$fragment';
    final text =
        '${quote.trim().split('\n').map((line) => '> $line').join('\n')}\n\n[${markdownLabel(source.title)} · Page $page](<$href>)\n\n## Notes\n\n';
    return repository.save(note, MarkdownDocument(text).encode());
  }

  Future<KnowledgeScan> scan(
    KnowledgeView view, {
    bool onlyQuickTodos = false,
    bool completedTasks = false,
    bool includeCompletedTasks = false,
    bool Function()? cancelled,
    void Function(int, int)? onProgress,
    void Function(KnowledgeScan)? onPartial,
  }) async {
    final completed = completedTasks || view.completedTasks;
    bool matchesFilters(Notebook note) =>
        (!view.tasksOnly || note.isMarkdown) &&
        (view.kind == 'all' ||
            (view.kind == 'markdown' && note.isMarkdown) ||
            (view.kind == 'pdf' && note.isPdf) ||
            (view.kind == 'media' && note.isMedia)) &&
        (view.tag.isEmpty ||
            note.tags.any(
              (tag) => tag.toLowerCase() == view.tag.toLowerCase(),
            )) &&
        (view.folder.isEmpty || note.folderId == view.folder);
    final listing = await repository.listForSearch();
    final notes = listing.entries
        .where(
          (entry) =>
              (!onlyQuickTodos || _isQuickTodo(entry.note)) &&
              matchesFilters(entry.note),
        )
        .toList();
    final hits = <KnowledgeHit>[], tasks = <KnowledgeTask>[];
    final warnings = List<String>.of(listing.errors);
    final query = view.query.trim().toLowerCase();
    KnowledgeScan snapshot({required bool partial}) {
      final ordered = partial ? List<KnowledgeHit>.of(hits) : hits;
      if (completed && view.tasksOnly && !includeCompletedTasks) {
        final completedByLocation = {
          for (final task in tasks)
            '${task.note.id}:${task.anchor}': task.todo!.completionTime!,
        };
        ordered.sort(
          (a, b) => completedByLocation['${b.note.id}:${b.anchor}']!.compareTo(
            completedByLocation['${a.note.id}:${a.anchor}']!,
          ),
        );
      }
      return KnowledgeScan(
        ordered,
        partial ? List<KnowledgeTask>.of(tasks) : tasks,
        partial ? List<String>.of(warnings) : warnings,
      );
    }

    if (view.tasksOnly || query.isNotEmpty) {
      try {
        final inbox = (await quickTodos.read()).values.toList()
          ..sort(
            (a, b) => completed
                ? (b.completionTime ?? b.modified).compareTo(
                    a.completionTime ?? a.modified,
                  )
                : b.created.compareTo(a.created),
          );
        for (final todo in inbox) {
          if (cancelled?.call() == true) break;
          if ((!includeCompletedTasks && todo.done != completed) ||
              !todo.text.toLowerCase().contains(query)) {
            continue;
          }
          // Keep document and inbox results in the same list without creating
          // a repository document or an editor destination for inbox entries.
          final note = Notebook(
            id: 'quick:${todo.id}',
            title: todo.text,
            paper: 'markdown',
            created: todo.created,
            modified: todo.modified,
            folderId: todo.project,
            tags: [
              todo.project == null ? unsortedTodos : _quickTodoTag,
              if (todo.due != null) 'Due: ${todo.due}',
            ],
          );
          if (!matchesFilters(note)) continue;
          final task = KnowledgeTask(
            note,
            0,
            0,
            todo.text,
            todo.revision,
            canPlan: true,
            quickTodo: todo,
          );
          tasks.add(task);
          hits.add(KnowledgeHit(note, todo.text, task.anchor));
        }
      } catch (error) {
        warnings.add('Quick to-dos: $error');
      }
    }
    final progress = Stopwatch()..start();
    var shown = false;
    if (hits.isNotEmpty && notes.isNotEmpty && cancelled?.call() != true) {
      onPartial?.call(snapshot(partial: true));
      shown = onPartial != null;
    }
    for (var done = 0; done < notes.length;) {
      if (cancelled?.call() == true) break;
      final end = (done + _knowledgeBatchSize).clamp(0, notes.length);
      final batch = await _scanKnowledgeBatch(
        repository.directory.path,
        notes.sublist(done, end),
        view,
        completed: completed,
        includeCompleted: includeCompletedTasks,
      );
      hits.addAll(batch.hits);
      tasks.addAll(batch.tasks);
      warnings.addAll(batch.warnings);
      done += batch.processed;
      if (done == notes.length ||
          !shown ||
          progress.elapsedMilliseconds >= 120) {
        onProgress?.call(done, notes.length);
        if (done < notes.length && cancelled?.call() != true) {
          onPartial?.call(snapshot(partial: true));
          shown = true;
        }
        progress.reset();
      }
    }
    if (cancelled?.call() != true) {
      await _pruneKnowledgeIndex(repository.directory.path, listing.entries);
    }
    return snapshot(partial: false);
  }

  Future<KnowledgeTask?> changeTask(KnowledgeTask task) async {
    final todo = task.quickTodo;
    if (todo != null) {
      final timer = task.timerAction;
      if (task.deleting) {
        await _changeQuickTodo(todo, delete: true);
      } else if (timer == null && task.workTime == null) {
        await changeTaskStatus(todo, !todo.done);
      } else {
        await _changeQuickTodo(
          todo,
          timer: timer,
          workTime: task.workTime,
          countdown: task.countdown,
        );
      }
      return null;
    }
    final snapshot = await repository.snapshotForSync(task.note.id);
    if (snapshot == null) {
      throw const FormatException('The task no longer exists.');
    }
    final (note, bytes) = await LocalNotebookRepository.decodeValidated(
      snapshot.archive,
    );
    final document = await decodeMarkdownAsync(bytes);
    final linkId =
        !task.deleting && task.timerAction == null && task.workTime == null
        ? documentTaskLinkId(document.source, task.offset)
        : null;
    var source = task.editDocument(document.source);
    final modified = DateTime.now();
    if (linkId != null) {
      source = syncDocumentTasksByLinkId(
        source,
        linkId,
        done: !task.done,
        previousModified: note.modified,
        now: modified,
      );
    }
    final archive = await LocalNotebookRepository.encodeAsync(
      note.copy(modified: modified),
      document.copy(source: source).encode(),
    );
    await repository.applySync(note.id, snapshot.raw, archive);
    if (linkId != null) {
      if (FileGateway.syncLinkedTask case final sync?) {
        await sync(linkId, !task.done, excludeNoteId: note.id);
      } else {
        await syncLinkedTaskStatus(
          repository,
          linkId,
          done: !task.done,
          excludeNoteId: note.id,
          now: modified,
        );
      }
    }
    return task.timerAction != null || task.workTime != null
        ? task.afterDocumentTimerEdit(source, modified)
        : null;
  }

  Future<void> renameTag(String from, String to) async {
    if (from.trim().isEmpty) return;
    for (final note in await repository.list()) {
      if (!note.tags.any((tag) => tag.toLowerCase() == from.toLowerCase())) {
        continue;
      }
      final tags = <String, String>{};
      for (final original in note.tags) {
        final value = original.toLowerCase() == from.toLowerCase()
            ? to.trim()
            : original;
        if (value.isNotEmpty) {
          tags.putIfAbsent(value.toLowerCase(), () => value);
        }
      }
      await repository.save(
        note.copy(tags: tags.values.toList()),
        await repository.load(note.id),
      );
    }
    for (var i = 0; i < views.length; i++) {
      final view = views[i];
      if (view.tag.toLowerCase() == from.toLowerCase()) {
        views[i] = KnowledgeView(
          view.name,
          query: view.query,
          tag: to.trim(),
          folder: view.folder,
          kind: view.kind,
          openTasks: view.openTasks,
          completedTasks: view.completedTasks,
        );
      }
    }
    await save();
  }
}
