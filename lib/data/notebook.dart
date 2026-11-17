import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfDocument;
import 'package:path/path.dart' as p;
import 'catalog.dart';
import 'templates.dart';
import 'learning.dart';
import 'markdown_document.dart';
import 'ink.dart';

// Keep the original 64 KB bound for titles/folders/tags; allow a bounded,
// lossless assessment log instead of silently truncating learning history.
const maxNotebookMetadataBytes = 8 * 1024 * 1024 + 65536;

List<int> _metadataBytes(Notebook note) {
  final json = note.toJson();
  final basic = Map<String, Object?>.of(json)..remove('learning');
  if (utf8.encode(jsonEncode(basic)).length > 65536) {
    throw const FormatException(
      'Titles, folders and tags may use at most 64 KB in total.',
    );
  }
  final bytes = utf8.encode(jsonEncode(json));
  if (bytes.length > maxNotebookMetadataBytes) {
    throw const FormatException(
      'Study history is too large (maximum 8 MB). Please export a backup.',
    );
  }
  return bytes;
}

class Notebook {
  const Notebook({
    required this.id,
    required this.title,
    required this.created,
    required this.modified,
    this.paper = 'blank',
    this.lineColor = 0xDCE4EC,
    this.folderId,
    this.folderName,
    this.tags = const [],
    this.learning = const LearningProgress.empty(),
    this.linkPath,
  });
  final String id, title, paper;
  final int lineColor;
  final DateTime created, modified;
  final String? folderId, folderName;
  final List<String> tags;
  final LearningProgress learning;
  final String? linkPath;
  bool get isMarkdown => paper == 'markdown';
  String get documentPath => linkPath ?? '$id.${isMarkdown ? 'md' : 'pdf'}';
  Notebook copy({
    String? title,
    int? lineColor,
    DateTime? modified,
    String? folderId,
    String? folderName,
    List<String>? tags,
    LearningProgress? learning,
    bool clearFolder = false,
  }) => Notebook(
    id: id,
    title: title ?? this.title,
    created: created,
    modified: modified ?? this.modified,
    paper: paper,
    lineColor: lineColor ?? this.lineColor,
    folderId: clearFolder ? null : folderId ?? this.folderId,
    folderName: clearFolder ? null : folderName ?? this.folderName,
    tags: List.unmodifiable(tags ?? this.tags),
    learning: learning ?? this.learning,
    linkPath: linkPath,
  );
  Map<String, Object?> toJson() => {
    'version': isMarkdown || linkPath != null
        ? 4
        : learning.isEmpty
        ? 2
        : 3,
    if (linkPath != null) 'linkPath': linkPath,
    if (!learning.isEmpty) 'learning': learning.toJson(),
    'folderId': folderId,
    'folderName': folderName,
    'tags': tags,
    'id': id,
    'title': title,
    'created': created.toUtc().toIso8601String(),
    'modified': modified.toUtc().toIso8601String(),
    'paper': paper,
    if (lineColor != 0xDCE4EC) 'lineColor': lineColor,
  };
  factory Notebook.fromJson(Map<String, dynamic> json) {
    final basic = Map<String, dynamic>.of(json)..remove('learning');
    if (utf8.encode(jsonEncode(basic)).length > 65536) {
      throw const FormatException(
        'Titles, folders and tags may use at most 64 KB in total.',
      );
    }
    if (![1, 2, 3, 4].contains(json['version']) ||
        (json['version'] == 3 && json['learning'] is! Map<String, dynamic>) ||
        (json['version'] != 3 &&
            json['version'] != 4 &&
            json.containsKey('learning')) ||
        (json['linkPath'] != null &&
            (json['version'] != 4 ||
                json['linkPath'] is! String ||
                !MarkdownDocument.safePath(json['linkPath'] as String) ||
                !((json['linkPath'] as String).toLowerCase().endsWith(
                  json['paper'] == 'markdown' ? '.md' : '.pdf',
                )))) ||
        (json['folderId'] != null && json['folderId'] is! String) ||
        (json['folderName'] != null && json['folderName'] is! String) ||
        (json['tags'] != null &&
            (json['tags'] is! List ||
                (json['tags'] as List).any((t) => t is! String))) ||
        (json['lineColor'] != null &&
            (json['lineColor'] is! int ||
                json['lineColor'] < 0 ||
                json['lineColor'] > 0xFFFFFF)) ||
        json['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(json['id'] as String) ||
        json['title'] is! String ||
        (json['title'] as String).trim().isEmpty ||
        ![
          'blank',
          'lined',
          'grid',
          'pdf',
          if (json['version'] == 4) 'markdown',
        ].contains(json['paper'])) {
      throw const FormatException('Invalid or unsupported note file.');
    }
    return Notebook(
      id: json['id'],
      title: json['title'],
      paper: json['paper'],
      lineColor: json['lineColor'] as int? ?? 0xDCE4EC,
      created: DateTime.parse(json['created']),
      modified: DateTime.parse(json['modified']),
      folderId: json['folderId'],
      folderName: json['folderName'],
      tags: List.unmodifiable(
        (json['tags'] as List? ?? const []).cast<String>(),
      ),
      linkPath: json['linkPath'],
      learning: json.containsKey('learning')
          ? LearningProgress.fromJson(json['learning'] as Map<String, dynamic>)
          : const LearningProgress.empty(),
    );
  }
}

void validatePdf(Uint8List bytes) {
  if (bytes.length < 8 ||
      !String.fromCharCodes(bytes.take(1024)).contains('%PDF-')) {
    throw const FormatException('The file is not a valid PDF.');
  }
  try {
    final pdf = PdfDocument.open(bytes);
    if (pdf.cos.isEncrypted) {
      throw const FormatException(
        'Password-protected PDFs are not supported yet.',
      );
    }
    if (pdf.pageCount < 1) {
      throw const FormatException('The PDF has no pages.');
    }
    for (var i = 0; i < pdf.pageCount; i++) {
      pdf.page(i);
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('The PDF is corrupted or password-protected.');
  }
}

void validateNotebookContent(Notebook note, Uint8List bytes) {
  if (note.isMarkdown) {
    MarkdownDocument.decode(bytes);
  } else {
    validatePdf(bytes);
  }
}

abstract class NotebookRepository {
  LibraryCatalog get catalog;
  TemplateRepository get templates;
  Future<void> flush();
  Future<List<Notebook>> list();
  Future<Uint8List> load(String id);
  Future<Notebook> create(
    String title,
    Uint8List pdf, {
    String paper = 'pdf',
    int lineColor = 0xDCE4EC,
  });
  Future<Notebook> save(Notebook note, Uint8List pdf);
  Future<void> delete(String id);
  Future<Uint8List> exportArchive(Notebook note);
  Future<Notebook> importArchive(Uint8List bytes);
}

/// A local recovery archive. [revision] is null for the current trash entry.
class RecoveryEntry {
  const RecoveryEntry(this.note, this.recorded, this.size, {this.revision});
  final Notebook note;
  final DateTime recorded;
  final int size;
  final String? revision;
}

/// One atomically replaced archive per document keeps metadata and PDF together.
class LocalNotebookRepository implements NotebookRepository {
  LocalNotebookRepository(this.directory, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      templates = TemplateRepository(
        Directory(p.join(directory.path, '.templates')),
      ),
      catalog = LibraryCatalog(File(p.join(directory.path, '.library.json')));
  @override
  final LibraryCatalog catalog;
  @override
  final TemplateRepository templates;
  final Directory directory;
  final DateTime Function() _clock;
  static const historyInterval = Duration(minutes: 5);
  static const historyLimit = 20;
  static const historyByteLimit = 512 * 1024 * 1024;
  Future<void> _queue = Future.value();
  final List<String> readErrors = [];
  final _loadedInk = <String, (InkDocument, String, int)>{};
  (InkDocument, String, int)? cachedInk(String id) => _loadedInk.remove(id);
  void _cacheInk(String id, (InkDocument, String, int) value) {
    _loadedInk.remove(id);
    _loadedInk[id] = value;
    while (_loadedInk.length > 4) {
      _loadedInk.remove(_loadedInk.keys.first);
    }
  }

  File _file(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid document ID.');
    }
    return File(p.join(directory.path, '$id.noter'));
  }

  Future<T> _serialize<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';
  static Uint8List encode(Notebook note, Uint8List pdf, {InkDocument? ink}) {
    final metadata = _metadataBytes(note);
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', metadata.length, metadata))
      ..addFile(
        ArchiveFile(
          note.isMarkdown ? 'document.markdown.zip' : 'document.pdf',
          pdf.length,
          pdf,
        )..compression = CompressionType.none,
      );
    if (ink != null) {
      final bytes = ink.encode();
      if (bytes.length > InkDocument.maxBytes || note.isMarkdown) {
        throw const FormatException('Invalid or oversized ink layer.');
      }
      archive.addFile(ArchiveFile('ink.json', bytes.length, bytes));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static (Notebook, Uint8List) decode(Uint8List bytes) {
    final decoded = decodeWithInk(bytes);
    return (decoded.$1, decoded.$2);
  }

  static (Notebook, Uint8List, InkDocument?) decodeWithInk(Uint8List bytes) {
    if (bytes.length > 256 * 1024 * 1024) {
      throw const FormatException(
        'The note file is too large (maximum 256 MB).',
      );
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length != 2 && archive.files.length != 3) {
      throw const FormatException('Invalid note archive.');
    }
    final manifest = archive.find('manifest.json');
    if (manifest == null || manifest.size > maxNotebookMetadataBytes) {
      throw const FormatException('Invalid note archive.');
    }
    final note = Notebook.fromJson(
      jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>,
    );
    final pdf = archive.find(
      note.isMarkdown ? 'document.markdown.zip' : 'document.pdf',
    );
    if (pdf == null || pdf.size > 256 * 1024 * 1024) {
      throw const FormatException('Invalid note archive.');
    }
    final ink = archive.find('ink.json');
    if (archive.files.any((f) => !f.isFile) ||
        archive.files.map((f) => f.name).toSet().length !=
            archive.files.length ||
        (archive.files.length == 3 && (ink == null || note.isMarkdown)) ||
        (ink != null && ink.size > InkDocument.maxBytes)) {
      throw const FormatException('Invalid note archive.');
    }
    return (
      note,
      pdf.content,
      ink == null ? null : InkDocument.decode(ink.content),
    );
  }

  Future<List<String>> syncIds() => _serialize(() async {
    await directory.create(recursive: true);
    final ids = <String>[];
    await for (final entry in directory.list()) {
      if (entry is File && entry.path.endsWith('.noter')) {
        final id = p.basenameWithoutExtension(entry.path);
        _file(id); // Validate filenames before planning synchronization.
        ids.add(id);
      }
    }
    return ids;
  });

  /// Read one note at a time, so a large library is not held twice in memory.
  /// Raw bytes guard replacement; the archive carries portable folder metadata.
  Future<({Uint8List raw, Uint8List archive})?> snapshotForSync(String id) =>
      _serialize(() async {
        await catalog.load();
        return _snapshotNotebook(_file(id).path, {
          for (final folder in catalog.folders) folder.id: folder.name,
        });
      });

  static Future<Uint8List> encodeAsync(
    Notebook note,
    Uint8List pdf, {
    InkDocument? ink,
  }) {
    final snapshot = TransferableTypedData.fromList([pdf]);
    return _encodeTransferred(note, snapshot, ink);
  }

  static Future<(Notebook, Uint8List, InkDocument?)> decodeInkValidated(
    Uint8List bytes,
  ) => _decodeInkTransferred(TransferableTypedData.fromList([bytes]));

  static Future<(Notebook, Uint8List)> decodeValidated(Uint8List bytes) =>
      _decodeValidated(bytes);

  /// A remote operation cannot overwrite edits made while the network was busy.
  Future<void> applySync(String id, Uint8List? expected, Uint8List? archive) {
    final expectedSnapshot = expected == null
        ? null
        : TransferableTypedData.fromList([expected]);
    // Freeze caller-owned bytes now; decode inside the serialized operation.
    final incoming = archive == null
        ? null
        : TransferableTypedData.fromList([archive]);
    return _serialize(() async {
      final target = _file(id);
      final decoded = incoming == null
          ? null
          : await _decodeInkTransferred(incoming);
      Notebook? mapped;
      TransferableTypedData? pdf;
      InkDocument? ink;
      if (decoded != null) {
        final note = decoded.$1;
        if (note.id != id) {
          throw const FormatException('Incorrect sync note ID.');
        }
        final folder = note.folderName == null
            ? null
            : await catalog.ensureFolder(note.folderName!);
        mapped = note.copy(
          folderId: folder?.id,
          folderName: folder?.name,
          clearFolder: folder == null,
        );
        pdf = TransferableTypedData.fromList([decoded.$2]);
        ink = decoded.$3;
      }
      await _applySyncNotebook(
        target.path,
        expectedSnapshot,
        mapped,
        pdf,
        _clock(),
        ink,
      );
      _loadedInk.remove(id);
      _failedInkJournals.remove(id);
    });
  }

  @override
  Future<void> flush() async {
    await _queue;
    await catalog.flush();
    await templates.flush();
  }

  @override
  Future<List<Notebook>> list() async {
    await _queue;
    final result = await _listNotebooks(directory.path);
    readErrors
      ..clear()
      ..addAll(result.$2);
    return result.$1;
  }

  @override
  Future<Uint8List> load(String id) async {
    await _queue;
    final loaded = await _loadNotebookWithInk(
      _file(id).path,
      _inkJournal(id).path,
    );
    _cacheInk(id, loaded.$2);
    return loaded.$1;
  }

  /// Interchange/preview PDF, not the editor's unchanged base document.
  Future<Uint8List> loadPdf(String id) async {
    final bytes = await load(id);
    final ink = _loadedInk[id]?.$1;
    return ink == null ? bytes : _renderInkPdf(bytes, ink);
  }

  File _inkJournal(String id) {
    _file(id);
    return File(p.join(directory.path, '.ink', '$id.jsonl'));
  }

  Future<(InkDocument, String, int)> openInk(String id) => _serialize(() {
    final path = _file(id).path, journal = _inkJournal(id).path;
    return _loadInkNotebook(path, journal);
  });

  /// Encode/write only the new operation, never a PDF or full stroke list.
  final _failedInkJournals = <String>{};
  Future<void> appendInk(
    String id,
    String base,
    String generation,
    int sequence,
    InkEdit edit,
  ) => _serialize(() async {
    if (_failedInkJournals.contains(id)) {
      throw StateError('The ink journal needs a checkpoint.');
    }
    try {
      final file = _inkJournal(id);
      await file.parent.create(recursive: true);
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsString(
          '${jsonEncode({'base': base, 'generation': generation})}\n',
          flush: true,
        );
      }
      await file.writeAsString(
        '${jsonEncode({'sequence': sequence, ...edit.toJson()})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // No later operation may append N + 1 after a failed/partial N.
      // Only an atomic snapshot can make this journal writable again.
      _failedInkJournals.add(id);
      rethrow;
    }
  });

  Future<Notebook> saveWithInk(Notebook note, Uint8List pdf, InkDocument ink) {
    final snapshot = TransferableTypedData.fromList([pdf]);
    return _serialize(() async {
      await catalog.load();
      final updated = note.copy(
        modified: _clock(),
        folderName: catalog.folderName(note.folderId),
        clearFolder: note.folderId == null,
      );
      await _saveNotebook(_file(note.id).path, updated, snapshot, ink: ink);
      _cacheInk(note.id, (ink, '', ink.sequence));
      // Earlier appends precede this checkpoint; newer edits are queued behind
      // it and recreate the header after the atomic archive replacement.
      final journal = _inkJournal(note.id);
      if (await journal.exists()) await journal.delete();
      _failedInkJournals.remove(note.id);
      return updated;
    });
  }

  /// Ink-only checkpoints read the unchanged PDF on the storage isolate:
  /// no large PDF copy/transfer on the UI thread.
  Future<Notebook> checkpointInk(Notebook note, InkDocument ink) =>
      _serialize(() async {
        await catalog.load();
        final updated = note.copy(
          modified: _clock(),
          folderName: catalog.folderName(note.folderId),
          clearFolder: note.folderId == null,
        );
        await _saveInkOnly(_file(note.id).path, updated, ink);
        _cacheInk(note.id, (ink, '', ink.sequence));
        final journal = _inkJournal(note.id);
        if (await journal.exists()) await journal.delete();
        _failedInkJournals.remove(note.id);
        return updated;
      });

  @override
  Future<Notebook> create(
    String title,
    Uint8List pdf, {
    String paper = 'pdf',
    int lineColor = 0xDCE4EC,
  }) async {
    if (paper == 'markdown') {
      MarkdownDocument.decode(pdf);
    } else {
      await _validatePdfOffThread(pdf);
    }
    final now = DateTime.now();
    return save(
      Notebook(
        id: newId(),
        title: title.trim().isEmpty ? 'New note' : title.trim(),
        created: now,
        modified: now,
        paper: paper,
        lineColor: lineColor,
      ),
      pdf,
    );
  }

  @override
  Future<Notebook> save(Notebook note, Uint8List pdf) {
    // One isolated snapshot, even when a caller mutates its buffer immediately.
    final snapshot = TransferableTypedData.fromList([pdf]);
    final frozen = note.copy(tags: note.tags);
    return _serialize(() async {
      await catalog.load();
      final updated = frozen.copy(
        modified: _clock(),
        folderName: catalog.folderName(frozen.folderId),
        clearFolder: frozen.folderId == null,
      );
      final path = _file(note.id).path;
      final isNew = !await File(path).exists();
      if (!isNew) {
        await _checkpointInkJournalAsync(path);
        _loadedInk.remove(note.id);
      }
      await _saveNotebook(path, updated, snapshot);
      if (isNew && !note.isMarkdown) {
        _cacheInk(note.id, (
          InkDocument(generation: _legacyInkGeneration(updated)),
          '',
          0,
        ));
      }
      return updated;
    });
  }

  @override
  Future<void> delete(String id) => _serialize(() async {
    await _trashNotebook(_file(id).path);
    _loadedInk.remove(id);
    _failedInkJournals.remove(id);
  });

  File _recoveryFile(String id, String? revision) {
    _file(id); // Use the same strict ID validation for every recovery path.
    if (revision == null) {
      return File(p.join(directory.path, '.trash', '$id.noter'));
    }
    _file(revision);
    return File(p.join(directory.path, '.history', id, '$revision.noter'));
  }

  Future<List<RecoveryEntry>> recovery({String? id}) => _serialize(() async {
    if (id != null) _file(id);
    final path = id == null
        ? p.join(directory.path, '.trash')
        : p.join(directory.path, '.history', id);
    return _listRecovery(path, id);
  });

  Future<Uint8List> recoveryPdf(RecoveryEntry entry) => _serialize(() async {
    final path = _recoveryFile(entry.note.id, entry.revision).path;
    return _loadRecovery(path, entry.note.id);
  });

  /// Always create a new identity: an old synchronized deletion stays deleted.
  /// The source remains available until explicitly purged or history retention.
  Future<Notebook> restore(RecoveryEntry entry) async {
    final archive = await _serialize(() async {
      final file = _recoveryFile(entry.note.id, entry.revision);
      return file.readAsBytes();
    });
    final (note, pdf, ink) = await decodeInkValidated(archive);
    if (note.id != entry.note.id) {
      throw const FormatException('Incorrect recovery ID.');
    }
    await catalog.load();
    final folderName = catalog.folderName(note.folderId) ?? note.folderName;
    final folder = folderName == null
        ? null
        : await catalog.ensureFolder(folderName);
    final now = _clock();
    final restored = Notebook(
      id: newId(),
      title: '${note.title} (Restored)',
      created: now,
      modified: now,
      paper: note.paper,
      lineColor: note.lineColor,
      folderId: folder?.id,
      folderName: folder?.name,
      tags: note.tags,
      learning: note.learning,
      linkPath: note.linkPath == null
          ? null
          : p.posix.normalize(
              p.posix.join(
                p.posix.dirname(note.documentPath),
                '${newId()}.${note.isMarkdown ? 'md' : 'pdf'}',
              ),
            ),
    );
    return ink == null ? save(restored, pdf) : saveWithInk(restored, pdf, ink);
  }

  /// Purging a trash item also removes its local history, never server revisions.
  Future<void> purgeTrash(String id) => _serialize(() async {
    final file = _recoveryFile(id, null);
    if (await file.exists()) await file.delete();
    final history = Directory(p.join(directory.path, '.history', id));
    if (await history.exists()) await history.delete(recursive: true);
  });

  Future<void> clearHistory(String id) => _serialize(() async {
    _file(id);
    final history = Directory(p.join(directory.path, '.history', id));
    if (await history.exists()) await history.delete(recursive: true);
  });

  @override
  Future<Uint8List> exportArchive(Notebook note) async {
    await _queue;
    await catalog.load();
    return _exportNotebook(_file(note.id).path, {
      for (final folder in catalog.folders) folder.id: folder.name,
    });
  }

  @override
  Future<Notebook> importArchive(Uint8List bytes) async {
    final (note, pdf, ink) = await decodeInkValidated(bytes);
    // Import is a copy, never overwrite a possibly newer local document.
    await catalog.load();
    final folder = note.folderName == null
        ? null
        : await catalog.ensureFolder(note.folderName!);
    final now = DateTime.now();
    final imported = Notebook(
      id: newId(),
      title: note.title,
      created: now,
      modified: now,
      paper: note.paper,
      lineColor: note.lineColor,
      folderId: folder?.id,
      folderName: folder?.name,
      tags: note.tags,
      learning: note.learning,
      linkPath: note.linkPath == null
          ? null
          : p.posix.normalize(
              p.posix.join(
                p.posix.dirname(note.documentPath),
                '${newId()}.${note.isMarkdown ? 'md' : 'pdf'}',
              ),
            ),
    );
    return ink == null ? save(imported, pdf) : saveWithInk(imported, pdf, ink);
  }
}

// These top-level isolate entry helpers capture only explicit data, never a
// repository, controller, widget tree or platform channel.
Future<void> _trashNotebook(String path) =>
    Isolate.run(() => _moveToTrash(path), debugName: 'noter:trash');

Future<List<RecoveryEntry>> _listRecovery(String path, String? id) =>
    Isolate.run(() {
      final dir = Directory(path);
      if (!dir.existsSync()) return <RecoveryEntry>[];
      final entries = <RecoveryEntry>[];
      for (final file in dir.listSync().whereType<File>()) {
        if (!file.path.endsWith('.noter')) continue;
        final key = p.basenameWithoutExtension(file.path);
        if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(key)) {
          throw const FormatException('Invalid recovery file.');
        }
        final note = _readNotebookMetadata(file);
        if (note.id != (id ?? key)) {
          throw const FormatException('Incorrect recovery ID.');
        }
        entries.add(
          RecoveryEntry(
            note,
            file.lastModifiedSync(),
            file.lengthSync(),
            revision: id == null ? null : key,
          ),
        );
      }
      entries.sort((a, b) => b.recorded.compareTo(a.recorded));
      return entries;
    }, debugName: 'noter:recovery-list');

Future<(List<Notebook>, List<String>)> _listNotebooks(String directory) =>
    Isolate.run(() {
      Directory(directory).createSync(recursive: true);
      final notes = <Notebook>[], errors = <String>[];
      for (final entry in Directory(directory).listSync()) {
        if (entry is! File || !entry.path.endsWith('.noter')) continue;
        try {
          final note = _readNotebookMetadata(entry);
          if (p.basenameWithoutExtension(entry.path) != note.id) {
            throw const FormatException('Incorrect ID');
          }
          notes.add(note);
        } catch (_) {
          errors.add(p.basename(entry.path));
        }
      }
      notes.sort((a, b) => b.modified.compareTo(a.modified));
      return (notes, errors);
    }, debugName: 'noter:library-metadata');

Notebook _readNotebookMetadata(File file) {
  if (file.lengthSync() > 256 * 1024 * 1024) {
    throw const FormatException('The note is too large.');
  }
  final input = InputFileStream(file.path, bufferSize: 64 * 1024);
  try {
    final archive = ZipDecoder().decodeStream(input, verify: true);
    final manifest = archive.find('manifest.json');
    final note = manifest == null || manifest.size > maxNotebookMetadataBytes
        ? null
        : Notebook.fromJson(
            jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>,
          );
    final pdf = archive.find(
      note?.isMarkdown == true ? 'document.markdown.zip' : 'document.pdf',
    );
    if ((archive.files.length != 2 &&
            !(archive.files.length == 3 &&
                archive.find('ink.json') != null &&
                note?.isMarkdown == false)) ||
        manifest == null ||
        pdf == null ||
        manifest.size > maxNotebookMetadataBytes ||
        pdf.size > 256 * 1024 * 1024) {
      throw const FormatException('Invalid note archive.');
    }
    // ZIP entries are lazy: never read the PDF while listing metadata.
    return note!;
  } finally {
    input.closeSync();
  }
}

Future<Uint8List> _loadRecovery(String path, String id) => Isolate.run(() {
  final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(
    File(path).readAsBytesSync(),
  );
  if (note.id != id) {
    throw const FormatException('Incorrect recovery ID.');
  }
  validateNotebookContent(note, pdf);
  return ink == null ? pdf : pdfWithInk(pdf, ink);
}, debugName: 'noter:recovery-preview');

Future<(Uint8List, (InkDocument, String, int))> _loadNotebookWithInk(
  String path,
  String journal,
) => Isolate.run(() {
  final content = LocalNotebookRepository.decodeWithInk(
    File(path).readAsBytesSync(),
  );
  final (note, pdf, _) = content;
  validateNotebookContent(note, pdf);
  if (p.basenameWithoutExtension(path) != note.id) {
    throw const FormatException('Incorrect note ID.');
  }
  return (pdf, _readInk(path, journal, content: content));
}, debugName: 'noter:load-document');

Future<Uint8List> _renderInkPdf(Uint8List bytes, InkDocument ink) =>
    Isolate.run(
      () => pdfWithInk(bytes, ink),
      debugName: 'noter:render-ink-pdf',
    );

Future<void> _validatePdfOffThread(Uint8List bytes) {
  final snapshot = TransferableTypedData.fromList([bytes]);
  return _validateTransferred(snapshot);
}

Future<void> _validateTransferred(TransferableTypedData bytes) =>
    Isolate.run(() {
      validatePdf(bytes.materialize().asUint8List());
    }, debugName: 'noter:validate-pdf');

Future<(Notebook, Uint8List)> _decodeValidated(Uint8List bytes) {
  final snapshot = TransferableTypedData.fromList([bytes]);
  return _decodeTransferred(snapshot);
}

Future<(Notebook, Uint8List)> _decodeTransferred(TransferableTypedData bytes) =>
    Isolate.run(() {
      final result = LocalNotebookRepository.decode(
        bytes.materialize().asUint8List(),
      );
      validateNotebookContent(result.$1, result.$2);
      return result;
    }, debugName: 'noter:import-archive');

Future<(Notebook, Uint8List, InkDocument?)> _decodeInkTransferred(
  TransferableTypedData bytes,
) => Isolate.run(() {
  final result = LocalNotebookRepository.decodeWithInk(
    bytes.materialize().asUint8List(),
  );
  validateNotebookContent(result.$1, result.$2);
  return result;
}, debugName: 'noter:decode-ink-archive');

Future<void> _saveNotebook(
  String path,
  Notebook note,
  TransferableTypedData snapshot, {
  InkDocument? ink,
}) => Isolate.run(() {
  final pdf = snapshot.materialize().asUint8List();
  _checkpoint(path, note.modified);
  _writeNotebook(path, note, pdf, ink: ink);
  _pruneHistory(path);
}, debugName: 'noter:atomic-save');

Directory _historyDirectory(String path) => Directory(
  p.join(p.dirname(path), '.history', p.basenameWithoutExtension(path)),
);

/// Copy the previous complete archive before replacing it. Failed checkpoint
/// writes abort the save; a failed save never destroys the previous live file.
void _checkpoint(
  String path,
  DateTime now, {
  bool force = false,
  File? previous,
}) {
  final source = previous ?? File(path);
  if (!source.existsSync()) return;
  final history = _historyDirectory(path);
  history.createSync(recursive: true);
  final files =
      history
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.noter'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  if (!force &&
      files.isNotEmpty &&
      now.difference(files.first.lastModifiedSync()) <
          LocalNotebookRepository.historyInterval) {
    return;
  }
  final destination = File(
    p.join(history.path, '${LocalNotebookRepository.newId()}.noter'),
  );
  final temporary = File('${destination.path}.tmp');
  try {
    source.copySync(temporary.path);
    final handle = temporary.openSync(mode: FileMode.append);
    try {
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    temporary.setLastModifiedSync(now);
    temporary.renameSync(destination.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

void _pruneHistory(String path) {
  final history = _historyDirectory(path);
  if (!history.existsSync()) return;
  final files =
      history
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.noter'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  var bytes = 0;
  for (var i = 0; i < files.length; i++) {
    bytes += files[i].lengthSync();
    if (i > 0 &&
        (i >= LocalNotebookRepository.historyLimit ||
            bytes > LocalNotebookRepository.historyByteLimit)) {
      files[i].deleteSync();
    }
  }
}

void _moveToTrash(String path) {
  _checkpointInkJournal(path);
  final source = File(path);
  final destination = File(p.join(p.dirname(path), '.trash', p.basename(path)));
  destination.parent.createSync(recursive: true);
  // A previous trash item with the same identity must never be overwritten.
  if (destination.existsSync()) {
    _checkpoint(path, DateTime.now(), force: true, previous: destination);
  }
  source.renameSync(destination.path);
}

void _writeNotebook(
  String path,
  Notebook note,
  Uint8List pdf, {
  InkDocument? ink,
  bool preserveInk = true,
}) {
  final metadata = _metadataBytes(note);
  if (pdf.length > 256 * 1024 * 1024) {
    throw const FormatException('The note file is too large (maximum 256 MB).');
  }
  if (note.isMarkdown) MarkdownDocument.decode(pdf);
  if (ink == null &&
      preserveInk &&
      !note.isMarkdown &&
      File(path).existsSync()) {
    ink = LocalNotebookRepository.decodeWithInk(
      File(path).readAsBytesSync(),
    ).$3;
  }
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', metadata.length, metadata))
    ..addFile(
      ArchiveFile(
        note.isMarkdown ? 'document.markdown.zip' : 'document.pdf',
        pdf.length,
        pdf,
      )..compression = CompressionType.none,
    );
  if (ink != null) {
    final bytes = ink.encode();
    if (bytes.length > InkDocument.maxBytes || note.isMarkdown) {
      throw const FormatException('Invalid or oversized ink layer.');
    }
    archive.addFile(ArchiveFile('ink.json', bytes.length, bytes));
  }
  final file = File(path), temporary = File('$path.tmp');
  file.parent.createSync(recursive: true);
  final output = OutputFileStream(temporary.path);
  try {
    ZipEncoder().encodeStream(archive, output);
  } finally {
    output.closeSync();
  }
  if (temporary.lengthSync() > 256 * 1024 * 1024) {
    temporary.deleteSync();
    throw const FormatException('The note file is too large (maximum 256 MB).');
  }
  final handle = temporary.openSync(mode: FileMode.append);
  try {
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
  temporary.renameSync(file.path);
}

Future<Uint8List> _exportNotebook(String path, Map<String, String> folders) =>
    Isolate.run(() {
      _checkpointInkJournal(path);
      final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(
        File(path).readAsBytesSync(),
      );
      return LocalNotebookRepository.encode(
        note.copy(
          folderName: folders[note.folderId],
          clearFolder: note.folderId == null,
        ),
        pdf,
        ink: ink,
      );
    }, debugName: 'noter:export-archive');

Future<({Uint8List raw, Uint8List archive})?> _snapshotNotebook(
  String path,
  Map<String, String> folders,
) => Isolate.run(() {
  _checkpointInkJournal(path);
  final file = File(path);
  if (!file.existsSync()) return null;
  final raw = file.readAsBytesSync();
  final (note, pdf, ink) = LocalNotebookRepository.decodeWithInk(raw);
  if (note.id != p.basenameWithoutExtension(path)) {
    throw const FormatException('Incorrect note ID.');
  }
  return (
    raw: raw,
    archive: LocalNotebookRepository.encode(
      note.copy(
        folderName: folders[note.folderId],
        clearFolder: note.folderId == null,
      ),
      pdf,
      ink: ink,
    ),
  );
}, debugName: 'noter:sync-snapshot');

Future<void> _applySyncNotebook(
  String path,
  TransferableTypedData? expected,
  Notebook? note,
  TransferableTypedData? bytes,
  DateTime now,
  InkDocument? ink,
) => Isolate.run(() {
  final file = File(path);
  final current = file.existsSync() ? file.readAsBytesSync() : null;
  if (!listEquals(current, expected?.materialize().asUint8List())) {
    throw StateError('The note changed during sync. Please sync again.');
  }
  if (note == null) {
    if (current != null) _moveToTrash(path);
  } else {
    _checkpoint(path, now, force: true);
    _writeNotebook(
      path,
      note,
      bytes!.materialize().asUint8List(),
      ink: ink,
      preserveInk: false,
    );
    _pruneHistory(path);
  }
  final journal = File(
    p.join(
      p.dirname(path),
      '.ink',
      '${p.basenameWithoutExtension(path)}.jsonl',
    ),
  );
  if (journal.existsSync()) journal.deleteSync();
}, debugName: 'noter:sync-apply');

Future<Uint8List> _encodeTransferred(
  Notebook note,
  TransferableTypedData bytes,
  InkDocument? ink,
) => Isolate.run(
  () => LocalNotebookRepository.encode(
    note,
    bytes.materialize().asUint8List(),
    ink: ink,
  ),
  debugName: 'noter:encode-archive',
);

Future<(InkDocument, String, int)> _loadInkNotebook(
  String path,
  String journal,
) => Isolate.run(() => _readInk(path, journal), debugName: 'noter:recover-ink');

(InkDocument, String, int) _readInk(
  String path,
  String journalPath, {
  (Notebook, Uint8List, InkDocument?)? content,
}) {
  final file = File(path);
  final decoded =
      content ??
      (file.existsSync()
          ? LocalNotebookRepository.decodeWithInk(file.readAsBytesSync())
          : null);
  // Generation matches are sufficient for ordinary replay. Do not hash a
  // potentially 256-MB unchanged PDF on every open just for a fallback path.
  var base = '';
  var ink =
      decoded?.$3 ??
      InkDocument(
        generation: decoded == null
            ? newInkId()
            : _legacyInkGeneration(decoded.$1),
      );
  final saved = ink.sequence;
  final journal = File(journalPath);
  if (!journal.existsSync() || journal.lengthSync() == 0) {
    return (ink, base, saved);
  }
  if (journal.lengthSync() > InkDocument.maxBytes) {
    throw const FormatException('The ink journal is too large.');
  }
  final text = journal.readAsStringSync();
  if (!text.endsWith('\n')) {
    final end = text.lastIndexOf('\n');
    if (end < 0) {
      journal.deleteSync();
      return (ink, base, saved);
    }
    journal.writeAsStringSync(text.substring(0, end + 1), flush: true);
  }
  final lines = text.split('\n')
    ..removeLast(); // Ignore an incomplete final write.
  if (lines.isEmpty) throw const FormatException('Corrupted ink journal.');
  final header = jsonDecode(lines.first) as Map<String, dynamic>;
  if (header['generation'] != ink.generation) {
    base = sha256.convert(decoded?.$2 ?? const <int>[]).toString();
    if (decoded?.$3 != null || header['base'] != base) {
      throw const FormatException(
        'The ink journal belongs to a different document version.',
      );
    }
    ink = InkDocument(generation: header['generation'] as String);
  }
  final controller = InkController(ink);
  try {
    for (final line in lines.skip(1)) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final sequence = json['sequence'] as int;
      if (sequence <= controller.sequence) continue;
      if (sequence != controller.sequence + 1) {
        throw const FormatException('Incomplete ink journal.');
      }
      final add = [
        for (final s in json['add'] as List)
          InkStroke.fromJson(s as Map<String, dynamic>),
      ];
      final remove = [
        for (final id in json['remove'] as List)
          controller.index[id as String] ??
              (throw const FormatException('Invalid ink journal.')),
      ];
      controller.apply(InkEdit(add: add, remove: remove));
    }
    final snapshot = controller.snapshot();
    return (snapshot, base, saved);
  } finally {
    controller.dispose();
  }
}

String _legacyInkGeneration(Notebook note) =>
    'legacy-${note.id}-${note.modified.microsecondsSinceEpoch}';

Future<void> _saveInkOnly(String path, Notebook note, InkDocument ink) =>
    Isolate.run(() {
      final (_, pdf, _) = LocalNotebookRepository.decodeWithInk(
        File(path).readAsBytesSync(),
      );
      _checkpoint(path, note.modified);
      _writeNotebook(path, note, pdf, ink: ink, preserveInk: false);
      _pruneHistory(path);
    }, debugName: 'noter:checkpoint-ink');

/// Close/recovery paths include already-flushed journal edits even when the
/// process died before its next archive checkpoint.
Future<void> _checkpointInkJournalAsync(String path) => Isolate.run(
  () => _checkpointInkJournal(path),
  debugName: 'noter:save-ink-checkpoint',
);

void _checkpointInkJournal(String path) {
  final file = File(path);
  final journal = File(
    p.join(
      p.dirname(path),
      '.ink',
      '${p.basenameWithoutExtension(path)}.jsonl',
    ),
  );
  if (!file.existsSync() || !journal.existsSync()) return;
  final (ink, _, _) = _readInk(path, journal.path);
  final (note, pdf, _) = LocalNotebookRepository.decodeWithInk(
    file.readAsBytesSync(),
  );
  _writeNotebook(
    path,
    note.copy(modified: journal.lastModifiedSync()),
    pdf,
    ink: ink,
    preserveInk: false,
  );
  journal.deleteSync();
}
