import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'package:path/path.dart' as p;

import 'markdown_document.dart';
import 'notebook.dart';

/// Portable paths are independent of titles and UI folders. Renaming/moving a
/// note therefore cannot break its incoming links.
class MarkdownLibrary {
  MarkdownLibrary(this.repository);
  final NotebookRepository repository;

  Future<Notebook> create(String title, {bool checklist = false}) =>
      repository.create(
        title,
        MarkdownDocument(checklist ? '- [ ] First task\n' : '').encode(),
        paper: 'markdown',
      );

  static Notebook? target(List<Notebook> notes, Notebook from, String href) {
    final path = resolveMarkdownPath(from.documentPath, href);
    final matches = notes.where((note) => note.documentPath == path).toList();
    return matches.length == 1 ? matches.single : null;
  }

  static String linkTo(Notebook from, Notebook to) => Uri(
    path: p.posix.relative(
      to.documentPath,
      from: p.posix.dirname(from.documentPath),
    ),
  ).toString();

  Future<List<Notebook>> backlinks(Notebook targetNote) async {
    final notes = await repository.list();
    final result = <Notebook>[];
    for (final note in notes.where(
      (n) => n.isMarkdown && n.id != targetNote.id,
    )) {
      final document = await decodeMarkdownAsync(
        await repository.load(note.id),
      );
      if (markdownLinks(document.source).any(
        (link) =>
            !link.image && target(notes, note, link.href)?.id == targetNote.id,
      )) {
        result.add(note);
      }
    }
    return result;
  }

  Future<Notebook> importText(String filename, Uint8List bytes) async {
    if (bytes.length > MarkdownDocument.maxTextBytes) {
      throw const FormatException('Markdown is too large (maximum 4 MB).');
    }
    final source = utf8.decode(bytes);
    final id = LocalNotebookRepository.newId();
    final path = '$id/${p.basename(filename)}';
    if (!MarkdownDocument.safePath(path)) {
      throw const FormatException('Unsupported Markdown filename.');
    }
    final now = DateTime.now();
    return repository.save(
      Notebook(
        id: id,
        title: _title(source, p.basenameWithoutExtension(filename)),
        created: now,
        modified: now,
        paper: 'markdown',
        linkPath: path,
      ),
      MarkdownDocument(source).encode(),
    );
  }

  /// No ZIP entry is extracted to the host filesystem. Validate everything
  /// before the first save, including paths, duplicate entries and size bounds.
  Future<List<Notebook>> importBundle(Uint8List bytes) async {
    final documents = await Isolate.run(() => _readBundle(bytes));
    final namespace = LocalNotebookRepository.newId();
    final now = DateTime.now();
    final result = <Notebook>[];
    for (final document in documents) {
      final note = Notebook(
        id: LocalNotebookRepository.newId(),
        title: document.title,
        created: now,
        modified: now,
        paper: document.markdown ? 'markdown' : 'pdf',
        linkPath: '$namespace/${document.path}',
      );
      result.add(await repository.save(note, document.bytes));
    }
    return result;
  }

  /// Follow note links transitively; preserve relative paths and local images.
  Future<Uint8List> exportBundle(Notebook start) async {
    final notes = await repository.list();
    final pending = <Notebook>[start];
    final visited = <String>{};
    final files = <String, Uint8List>{};
    var total = 0;
    void add(String path, Uint8List bytes) {
      if (!MarkdownDocument.safePath(path)) {
        throw const FormatException('Unsafe export path.');
      }
      final previous = files[path];
      if (previous != null) {
        if (base64Encode(previous) != base64Encode(bytes)) {
          throw FormatException('Ambiguous export path: $path');
        }
        return;
      }
      total += bytes.length;
      if (total > 128 * 1024 * 1024 || files.length >= 1000) {
        throw const FormatException(
          'Export is too large (128 MB / 1000 files).',
        );
      }
      files[path] = bytes;
    }

    while (pending.isNotEmpty) {
      final note = pending.removeLast();
      if (!visited.add(note.id)) continue;
      final source = repository;
      final bytes = !note.isMarkdown && source is LocalNotebookRepository
          ? await source.loadPdf(note.id)
          : await source.load(note.id);
      if (!note.isMarkdown) {
        add(note.documentPath, bytes);
        continue;
      }
      final document = await decodeMarkdownAsync(bytes);
      add(note.documentPath, Uint8List.fromList(utf8.encode(document.source)));
      final referencedAssets = markdownLinks(document.source)
          .where((link) => link.image)
          .map((link) => Uri.tryParse(link.href))
          .whereType<Uri>()
          .map(markdownAssetPath)
          .whereType<String>()
          .toSet();
      for (final asset in document.assets.entries.where(
        (entry) => referencedAssets.contains(entry.key),
      )) {
        add(
          p.posix.normalize(
            p.posix.join(p.posix.dirname(note.documentPath), asset.key),
          ),
          asset.value,
        );
      }
      for (final link in markdownLinks(
        document.source,
      ).where((l) => !l.image)) {
        final linked = target(notes, note, link.href);
        if (linked != null) pending.add(linked);
      }
    }
    return Isolate.run(() {
      final archive = Archive();
      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      return ZipEncoder().encodeBytes(archive);
    });
  }
}

String _title(String source, String fallback) {
  final match = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(source);
  final title = match?.group(1)?.trim() ?? fallback;
  return title.isEmpty
      ? 'Text note'
      : String.fromCharCodes(title.runes.take(120));
}

typedef _ImportedDocument = ({
  String path,
  String title,
  bool markdown,
  Uint8List bytes,
});

List<_ImportedDocument> _readBundle(Uint8List bytes) {
  if (bytes.length > 128 * 1024 * 1024) {
    throw const FormatException('The ZIP archive is too large (128 MB).');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  if (archive.files.length > 1000) {
    throw const FormatException('Too many files.');
  }
  final files = <String, Uint8List>{};
  var total = 0;
  for (final file in archive.files) {
    final path = file.isFile
        ? file.name
        : file.name.replaceFirst(RegExp(r'/$'), '');
    if (!MarkdownDocument.safePath(path)) {
      throw const FormatException('Unsafe ZIP path.');
    }
    if (!file.isFile) continue;
    if (files.containsKey(path)) {
      throw const FormatException('Duplicate ZIP path.');
    }
    total += file.size;
    if (total > 128 * 1024 * 1024 ||
        file.size > MarkdownDocument.maxTotalBytes) {
      throw const FormatException('Extracted content is too large.');
    }
    files[path] = file.content;
  }
  final result = <_ImportedDocument>[];
  final consumed = <String>{};
  for (final entry in files.entries) {
    final extension = p.posix.extension(entry.key).toLowerCase();
    if (extension != '.md' && extension != '.pdf') continue;
    consumed.add(entry.key);
    if (extension == '.pdf') {
      validatePdf(entry.value);
      result.add((
        path: entry.key,
        title: p.posix.basenameWithoutExtension(entry.key),
        markdown: false,
        bytes: entry.value,
      ));
      continue;
    }
    if (entry.value.length > MarkdownDocument.maxTextBytes) {
      throw const FormatException('Markdown is too large.');
    }
    final source = utf8.decode(entry.value);
    final assets = <String, Uint8List>{};
    for (final link in markdownLinks(source).where((l) => l.image)) {
      final path = resolveMarkdownPath(entry.key, link.href);
      if (path == null || !files.containsKey(path)) continue;
      final relative = p.posix.relative(path, from: p.posix.dirname(entry.key));
      if (!relative.startsWith('assets/')) {
        throw const FormatException(
          'Local images must be stored under assets/.',
        );
      }
      assets[relative] = files[path]!;
      consumed.add(path);
    }
    result.add((
      path: entry.key,
      title: _title(source, p.posix.basenameWithoutExtension(entry.key)),
      markdown: true,
      bytes: MarkdownDocument(source, assets).encode(),
    ));
  }
  if (result.isEmpty) {
    throw const FormatException('No Markdown notes in the ZIP archive.');
  }
  if (consumed.length != files.length) {
    throw const FormatException(
      'The ZIP archive contains unsupported or unreferenced files.',
    );
  }
  return result;
}

/// Isolate only the PDF bytes; editor/widget state must never be captured.
Future<int> markdownPdfPageCount(Uint8List bytes) =>
    Isolate.run(() => pdf.PdfDocument.open(bytes).pageCount);
