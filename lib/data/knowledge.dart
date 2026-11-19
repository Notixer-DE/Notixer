import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'catalog.dart';
import 'markdown_document.dart';
import 'markdown_library.dart';
import 'notebook.dart';
import 'pdf_search.dart';

typedef KnowledgeDestination = ({Notebook note, String anchor});

class MarkdownTemplate {
  const MarkdownTemplate(this.id, this.name, this.source);
  final String id, name, source;
  Map<String, String> toJson() => {'id': id, 'name': name, 'source': source};
  String render(DateTime date, String title) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return source
        .replaceAll('{{date}}', journalDate(date))
        .replaceAll('{{title}}', title)
        .replaceAll('{{weekday}}', days[date.weekday - 1])
        .replaceAll('{{year}}', '${date.year}');
  }
}

String journalDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

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
  });
  final String name, query, tag, folder, kind;
  final bool openTasks;
  Map<String, Object> toJson() => {
    'name': name,
    'query': query,
    'tag': tag,
    'folder': folder,
    'kind': kind,
    'openTasks': openTasks,
  };
  factory KnowledgeView.fromJson(Map<String, dynamic> value) {
    if (value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        !['all', 'markdown', 'pdf'].contains(value['kind'] ?? 'all') ||
        [
          'query',
          'tag',
          'folder',
        ].any((key) => value[key] != null && value[key] is! String) ||
        (value['openTasks'] != null && value['openTasks'] is! bool)) {
      throw const FormatException('Invalid saved view.');
    }
    return KnowledgeView(
      value['name'] as String,
      query: value['query'] as String? ?? '',
      tag: value['tag'] as String? ?? '',
      folder: value['folder'] as String? ?? '',
      kind: value['kind'] as String? ?? 'all',
      openTasks: value['openTasks'] as bool? ?? false,
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
  });
  final Notebook note;
  final int offset, line;
  final String text, revision;
  final bool canPlan;
}

String markdownRevision(String source) =>
    sha256.convert(utf8.encode(source)).toString();
List<({int offset, int line, String text})> markdownOpenTasks(String source) =>
    _openTasks(source, markdownTaskOffsets(source));

List<({int offset, int line, String text})> _openTasks(
  String source,
  List<int> offsets,
) {
  final tasks = <({int offset, int line, String text})>[];
  var line = 1, nextBreak = source.indexOf('\n');
  for (final offset in offsets) {
    if (source[offset] != ' ') continue;
    while (nextBreak >= 0 && nextBreak < offset) {
      line++;
      nextBreak = source.indexOf('\n', nextBreak + 1);
    }
    final end = source.indexOf('\n', offset);
    tasks.add((
      offset: offset,
      line: line,
      text: source.substring(offset + 2, end < 0 ? source.length : end).trim(),
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
        for (final task in tasks) '${task.note.id}:line=${task.line}': task,
      };
  final List<KnowledgeHit> hits;
  final List<KnowledgeTask> tasks;
  final Map<String, KnowledgeTask> tasksByLocation;
  final List<String> warnings;
}

Future<
  ({
    List<({int offset, int line, String text})> tasks,
    List<({String snippet, int line})> matches,
    String revision,
    bool singleTask,
  })
>
_scanMarkdown(String source, String query) => Isolate.run(() {
  final offsets = markdownTaskOffsets(source);
  final tasks = _openTasks(source, offsets);
  final matches = <({String snippet, int line})>[];
  if (query.isNotEmpty) {
    final lines = const LineSplitter().convert(source);
    for (var i = 0; i < lines.length && matches.length < 50; i++) {
      if (lines[i].toLowerCase().contains(query.toLowerCase())) {
        final line = lines[i];
        final offset = line.toLowerCase().indexOf(query.toLowerCase());
        final start = (offset - 60).clamp(0, line.length);
        matches.add((
          snippet: line.substring(
            start,
            (offset + query.length + 120).clamp(start, line.length),
          ),
          line: i + 1,
        ));
      }
    }
  }
  return (
    tasks: tasks,
    matches: matches,
    revision: markdownRevision(source),
    singleTask: offsets.length == 1,
  );
});

/// Shared, local preferences. Notes, journal entries and tags remain ordinary
/// portable notebook documents; this file contains only views and templates.
const unsortedTodos = 'Unsorted to-dos';
const _quickTodoTag = 'Quick to-do';
final _dueTag = RegExp(r'^Due: (\d{4}-\d{2}-\d{2})$', caseSensitive: false);

bool _isQuickTodo(Notebook note) =>
    note.isMarkdown && note.tags.any(_isTodoTag);

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
  List<MarkdownTemplate> templates = [
    const MarkdownTemplate(
      'daily',
      'Daily journal',
      '# {{date}} · {{weekday}}\n\n## Tasks\n\n## Notes\n- \n\n## Reflection\n',
    ),
  ];
  List<KnowledgeView> views = [];
  String? journalTemplate = 'daily';
  bool automaticBackups = true;
  static final _journalQueues = <String, Future<void>>{};
  Future<void> _queue = Future.value();
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load();
  Future<void> reload() async {
    await _queue;
    _loading = null;
    await load();
  }

  Future<void> _load() async {
    if (!await file.exists()) return;
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

  Future<void> save() {
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
    final result = _queue.then((_) async {
      await file.parent.create(recursive: true);
      if (await file.exists() && await file.readAsString() == snapshot) return;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Notebook> journal(DateTime date, {String? templateId}) async {
    await load();
    // Serialize date lookup and creation, including concurrent Today actions.
    final journalKey = repository.directory.absolute.path;
    final result = (_journalQueues[journalKey] ?? Future<void>.value()).then((
      _,
    ) async {
      final key = journalDate(date);
      final existing = (await repository.list()).where(
        (n) => n.id == 'journal-$key' || journalEntryDate(n) == key,
      );
      if (existing.isNotEmpty) {
        final original = existing.where((note) => note.id == 'journal-$key');
        return original.isNotEmpty ? original.first : existing.first;
      }
      final selected = templates.where(
        (t) => t.id == (templateId ?? journalTemplate),
      );
      final source = selected.isEmpty
          ? '# $key\n\n'
          : selected.first.render(date, key);
      final now = DateTime.now();
      return repository.save(
        Notebook(
          id: 'journal-$key',
          title: key,
          paper: 'markdown',
          created: now,
          modified: now,
          tags: const ['Journal'],
          linkPath: 'journals/$key.md',
        ),
        MarkdownDocument(source).encode(),
      );
    });
    _journalQueues[journalKey] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

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

  Future<Notebook> addQuickTodo(String text) async {
    final task = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (task.isEmpty) throw const FormatException('Enter a to-do.');
    final now = DateTime.now();
    return repository.save(
      Notebook(
        id: LocalNotebookRepository.newId(),
        title: task,
        paper: 'markdown',
        created: now,
        modified: now,
        tags: const [unsortedTodos],
      ),
      MarkdownDocument('- [ ] $task\n').encode(),
    );
  }

  Future<Notebook> planQuickTodo(
    KnowledgeTask task, {
    required String? projectId,
    String? newProject,
    required DateTime? due,
  }) async {
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
    if (due != null && (due.year < 1 || due.year > 9999)) {
      throw const FormatException('Choose a valid due date.');
    }
    NoteFolder? project;
    if (newProject != null) {
      project = await repository.catalog.ensureFolder(newProject);
    } else if (projectId != null) {
      project = repository.catalog.folders
          .where((f) => f.id == projectId)
          .firstOrNull;
      if (project == null) {
        throw const FormatException('The project was removed.');
      }
    }
    final date = due == null ? null : journalDate(due);
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
    bool Function()? cancelled,
    void Function(int, int)? onProgress,
  }) async {
    final notes = (await repository.list())
        .where(
          (note) =>
              (!onlyQuickTodos || _isQuickTodo(note)) &&
              (!view.openTasks || note.isMarkdown) &&
              (view.kind == 'all' ||
                  (view.kind == 'markdown' && note.isMarkdown) ||
                  (view.kind == 'pdf' && note.isPdf) ||
                  (view.kind == 'media' && note.isMedia)) &&
              (view.tag.isEmpty ||
                  note.tags.any(
                    (tag) => tag.toLowerCase() == view.tag.toLowerCase(),
                  )) &&
              (view.folder.isEmpty || note.folderId == view.folder),
        )
        .toList();
    final hits = <KnowledgeHit>[], tasks = <KnowledgeTask>[];
    final warnings = List<String>.of(repository.readErrors);
    for (var i = 0; i < notes.length; i++) {
      if (cancelled?.call() == true) break;
      final note = notes[i];
      try {
        if (note.isMedia) {
          if (view.query.isEmpty ||
              note.title.toLowerCase().contains(view.query.toLowerCase())) {
            hits.add(KnowledgeHit(note, note.mediaFormat!.kind, ''));
          }
          onProgress?.call(i + 1, notes.length);
          continue;
        }
        if (!note.isMarkdown && view.query.trim().isEmpty) {
          hits.add(KnowledgeHit(note, 'PDF / handwriting', ''));
          onProgress?.call(i + 1, notes.length);
          continue;
        }
        final bytes = await repository.load(note.id);
        if (note.isMarkdown) {
          final document = await decodeMarkdownAsync(bytes);
          final result = await _scanMarkdown(
            document.source,
            view.query.trim(),
          );
          if (view.query.trim().isEmpty ||
              note.title.toLowerCase().contains(view.query.toLowerCase()) ||
              result.matches.isNotEmpty) {
            tasks.addAll(
              result.tasks.map(
                (task) => KnowledgeTask(
                  note,
                  task.offset,
                  task.line,
                  task.text,
                  result.revision,
                  canPlan: result.singleTask && _isQuickTodo(note),
                ),
              ),
            );
          }
          if (view.openTasks) {
            for (final task in result.tasks.where(
              (task) =>
                  view.query.isEmpty ||
                  task.text.toLowerCase().contains(view.query.toLowerCase()) ||
                  note.title.toLowerCase().contains(view.query.toLowerCase()),
            )) {
              hits.add(KnowledgeHit(note, task.text, 'line=${task.line}'));
            }
          } else if (view.query.trim().isEmpty ||
              note.title.toLowerCase().contains(view.query.toLowerCase())) {
            hits.add(
              KnowledgeHit(
                note,
                document.source.length > 180
                    ? document.source.substring(0, 180)
                    : document.source,
                '',
              ),
            );
          } else {
            hits.addAll(
              result.matches.map(
                (match) =>
                    KnowledgeHit(note, match.snippet, 'line=${match.line}'),
              ),
            );
          }
        } else if (!view.openTasks) {
          if (view.query.trim().isEmpty) {
            hits.add(KnowledgeHit(note, 'PDF / handwriting', ''));
          } else {
            final result = await searchPdf(bytes, view.query, limit: 50);
            hits.addAll(
              result.hits.map(
                (hit) => KnowledgeHit(
                  note,
                  hit.snippet,
                  'page=${hit.pageIndex + 1}',
                ),
              ),
            );
            if (result.hits.isEmpty &&
                note.title.toLowerCase().contains(view.query.toLowerCase())) {
              hits.add(KnowledgeHit(note, 'PDF / handwriting', ''));
            }
            if (result.truncated) {
              warnings.add('${note.title}: first 50 matches shown.');
            }
          }
        }
      } catch (error) {
        warnings.add('${note.title}: $error');
      }
      onProgress?.call(i + 1, notes.length);
    }
    return KnowledgeScan(hits, tasks, warnings);
  }

  Future<void> completeTask(KnowledgeTask task) async {
    final current = (await repository.list())
        .where((n) => n.id == task.note.id)
        .single;
    final document = await decodeMarkdownAsync(
      await repository.load(current.id),
    );
    if (markdownRevision(document.source) != task.revision ||
        !markdownOpenTasks(
          document.source,
        ).any((t) => t.offset == task.offset)) {
      throw const FormatException(
        'The task changed. Reload the task list before editing it.',
      );
    }
    await repository.save(
      current,
      document
          .copy(
            source: document.source.replaceRange(
              task.offset,
              task.offset + 1,
              'x',
            ),
          )
          .encode(),
    );
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
        );
      }
    }
    await save();
  }
}
