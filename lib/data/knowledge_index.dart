part of 'knowledge.dart';

const _knowledgeBatchSize = 64;
// Bump when the extracted text or task offset format changes.
const _knowledgeCacheVersion = 1;
const _maxIndexEntryBytes = 4 * 1024 * 1024;

typedef _KnowledgeBatch = ({
  List<KnowledgeHit> hits,
  List<KnowledgeTask> tasks,
  List<String> warnings,
  int processed,
});

Future<_KnowledgeBatch> _scanKnowledgeBatch(
  String directory,
  List<NotebookSearchEntry> notes,
  KnowledgeView view, {
  required bool completed,
  required bool includeCompleted,
}) => Isolate.run(() {
  final index = _KnowledgeIndex(directory);
  final hits = <KnowledgeHit>[], tasks = <KnowledgeTask>[];
  final warnings = <String>[];
  final term = view.query.trim();
  final query = term.toLowerCase();
  final time = Stopwatch()..start();
  var processed = 0;
  for (final entry in notes) {
    final note = entry.note;
    try {
      final titleMatches = note.title.toLowerCase().contains(query);
      if (note.isMedia) {
        if (titleMatches) {
          hits.add(KnowledgeHit(note, note.mediaFormat!.kind, ''));
        }
      } else if (note.isMarkdown) {
        _searchIndexedMarkdown(
          index.markdown(entry),
          note,
          query,
          titleMatches: titleMatches,
          tasksOnly: view.tasksOnly,
          completed: completed,
          includeCompleted: includeCompleted,
          hits: hits,
          tasks: tasks,
        );
      } else if (query.isEmpty) {
        hits.add(KnowledgeHit(note, 'PDF / handwriting', ''));
      } else {
        final result = index.searchPdf(entry, term);
        for (final hit in result.hits) {
          hits.add(
            KnowledgeHit(note, hit.snippet, 'page=${hit.pageIndex + 1}'),
          );
        }
        if (result.hits.isEmpty && titleMatches) {
          hits.add(
            KnowledgeHit(
              note,
              result.hasText ? 'PDF' : 'PDF · No searchable text',
              '',
            ),
          );
        }
        if (result.truncated) {
          warnings.add('${note.title}: first 50 matches shown.');
        }
      }
    } catch (error) {
      warnings.add('${note.title}: $error');
    }
    processed++;
    // Bound cancellation latency even when many files in a batch are large.
    if (time.elapsedMilliseconds >= 80) break;
  }
  return (hits: hits, tasks: tasks, warnings: warnings, processed: processed);
}, debugName: 'noter:knowledge-scan');

void _searchIndexedMarkdown(
  _IndexedMarkdown document,
  Notebook note,
  String query, {
  required bool titleMatches,
  required bool tasksOnly,
  required bool completed,
  required bool includeCompleted,
  required List<KnowledgeHit> hits,
  required List<KnowledgeTask> tasks,
}) {
  final source = document.source;
  final matches = <KnowledgeHit>[];
  if (query.isNotEmpty) {
    final lines = const LineSplitter().convert(source);
    for (var i = 0; i < lines.length && matches.length < 50; i++) {
      final line = note.isTodoList ? todoItemText(lines[i]) : lines[i];
      final offset = line.toLowerCase().indexOf(query);
      if (offset < 0) continue;
      final start = (offset - 60).clamp(0, line.length);
      matches.add(
        KnowledgeHit(
          note,
          line.substring(
            start,
            (offset + query.length + 120).clamp(start, line.length),
          ),
          'line=${i + 1}',
        ),
      );
    }
  }
  if (!titleMatches && matches.isEmpty) return;
  if (!tasksOnly) {
    if (titleMatches) {
      hits.add(
        KnowledgeHit(
          note,
          source.substring(0, source.length.clamp(0, 180)),
          '',
        ),
      );
    }
    hits.addAll(matches);
  }

  final selected = _openTasks(source, document.offsets, completed: completed);
  if (includeCompleted) {
    selected.addAll(
      _openTasks(source, document.offsets, completed: !completed),
    );
  }
  for (final task in selected) {
    final text = note.isTodoList ? todoItemText(task.text) : task.text;
    final entry = KnowledgeTask(
      note,
      task.offset,
      task.line,
      text,
      document.revision,
      canPlan: document.offsets.length == 1 && _isQuickTodo(note),
      documentTodo: documentTask(
        source,
        task.offset,
        text,
        fallback: note.modified,
      ),
    );
    tasks.add(entry);
    if (tasksOnly && (titleMatches || text.toLowerCase().contains(query))) {
      hits.add(KnowledgeHit(note, text, entry.anchor));
    }
  }
}

class _IndexedMarkdown {
  const _IndexedMarkdown(this.source, this.offsets, this.revision);

  factory _IndexedMarkdown.parse(String source) => _IndexedMarkdown(
    source,
    markdownTaskOffsets(source),
    markdownRevision(source),
  );

  factory _IndexedMarkdown.fromJson(Object? value) {
    final [String source, List<dynamic> offsets, String revision] =
        value as List;
    var last = -1;
    for (final offset in offsets) {
      if (offset is! int || offset <= last || offset + 2 > source.length) {
        throw const FormatException('Invalid indexed task offset.');
      }
      last = offset;
    }
    return _IndexedMarkdown(source, offsets.cast<int>(), revision);
  }

  final String source, revision;
  final List<int> offsets;
  List<Object> toJson() => [source, offsets, revision];
}

Future<void> _pruneKnowledgeIndex(
  String directory,
  List<NotebookSearchEntry> notes,
) => Isolate.run(() {
  final index = _KnowledgeIndex(directory);
  final live = {for (final entry in notes) entry.note.id};
  try {
    for (final file in index.folder.listSync(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final id = p.basenameWithoutExtension(file.path);
      if (!live.contains(id) && !index.archive(id).existsSync()) {
        try {
          file.deleteSync();
        } on FileSystemException {
          // Another scan may have pruned it already.
        }
      }
    }
  } on FileSystemException {
    // Search also works when the cache is missing or read-only.
  }
}, debugName: 'noter:knowledge-index-prune');

/// Derived, versioned entries live beside the notebook library. A failed cache
/// read or write never prevents reading the authoritative archive.
class _KnowledgeIndex {
  _KnowledgeIndex(this.directory)
    : folder = Directory(p.join(directory, knowledgeIndexFolderName));

  final String directory;
  final Directory folder;
  late final _writeId = LocalNotebookRepository.newId();

  File archive(String id) => File(p.join(directory, '$id.noter'));

  String? _stamp(File file, int? checksum) {
    if (checksum == null) return null;
    final stat = file.statSync();
    return stat.type == FileSystemEntityType.file
        ? '$checksum:${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}'
        : null;
  }

  T? _read<T>(
    NotebookSearchEntry entry,
    String? stamp,
    T Function(Object?) decode,
  ) {
    if (stamp == null) return null;
    final id = entry.note.id;
    final file = File(p.join(folder.path, '$id.json'));
    try {
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > _maxIndexEntryBytes) {
        return null;
      }
      final value = jsonDecode(file.readAsStringSync());
      if (value case [
        _knowledgeCacheVersion,
        String version,
        final data,
      ] when version == stamp && _stamp(archive(id), entry.checksum) == stamp) {
        return decode(data);
      }
    } catch (_) {
      // The cache is optional, including malformed entries and I/O failures.
    }
    return null;
  }

  void _write(NotebookSearchEntry entry, String? stamp, Object value) {
    if (stamp == null) return;
    final id = entry.note.id;
    final file = File(p.join(folder.path, '$id.json'));
    final temporary = File('${file.path}.$_writeId.tmp');
    try {
      if (_stamp(archive(id), entry.checksum) != stamp) return;
      final bytes = utf8.encode(
        jsonEncode([_knowledgeCacheVersion, stamp, value]),
      );
      if (bytes.length > _maxIndexEntryBytes) return;
      folder.createSync(recursive: true);
      temporary.writeAsBytesSync(bytes);
      if (_stamp(archive(id), entry.checksum) == stamp) {
        temporary.renameSync(file.path);
      } else {
        temporary.deleteSync();
      }
    } on FileSystemException {
      try {
        temporary.deleteSync();
      } on FileSystemException {
        // Failure to cache must never hide results.
      }
    }
  }

  Uint8List _load(Notebook note, File file) {
    if (file.lengthSync() > 256 * 1024 * 1024) {
      throw const FormatException(
        'The note file is too large (maximum 256 MB).',
      );
    }
    final (stored, bytes) = LocalNotebookRepository.decode(
      file.readAsBytesSync(),
    );
    if (stored.id != note.id || stored.paper != note.paper) {
      throw const FormatException('Incorrect note ID or type.');
    }
    return bytes;
  }

  _IndexedMarkdown markdown(NotebookSearchEntry entry) {
    final note = entry.note;
    final file = archive(note.id);
    final stamp = _stamp(file, entry.checksum);
    final cached = _read(entry, stamp, _IndexedMarkdown.fromJson);
    if (cached != null) return cached;
    final data = _IndexedMarkdown.parse(
      MarkdownDocument.decode(_load(note, file)).source,
    );
    _write(entry, stamp, data.toJson());
    return data;
  }

  PdfSearchPageResult searchPdf(NotebookSearchEntry entry, String term) {
    final note = entry.note;
    final file = archive(note.id);
    final stamp = _stamp(file, entry.checksum);
    final cached = _read(
      entry,
      stamp,
      (data) => List<String>.from(data as List),
    );
    if (cached != null) return searchPdfPageTexts(cached, term, limit: 50);
    final document = validatePdf(_load(note, file));
    final pages = <String>[];
    var size = 0;
    Iterable<String> collect() sync* {
      for (final text in extractPdfSearchPageTexts(document)) {
        size += text.length + 1;
        if (size <= _maxIndexEntryBytes) pages.add(text);
        yield text;
      }
    }

    final result = searchPdfPageTexts(collect(), term, limit: 50);
    if (pages.length == document.pageCount) _write(entry, stamp, pages);
    return result;
  }
}
