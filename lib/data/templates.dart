import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart';
import 'notebook.dart';
import 'starter_templates.dart';
import 'ink.dart';
import 'ink_pages.dart';

enum TemplateKind { page, notebook }

class NoteTemplate {
  const NoteTemplate({
    required this.id,
    required this.name,
    required this.kind,
    required this.pageCount,
    this.builtIn = false,
  });
  final String id, name;
  final TemplateKind kind;
  final int pageCount;
  final bool builtIn;

  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'kind': kind.name,
    'pages': pageCount,
  };

  factory NoteTemplate.fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'], pages = json['pages'];
    if (json['version'] != 1 ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        id.startsWith('starter_') ||
        name is! String ||
        name != templateName(name) ||
        pages is! int ||
        pages < 1 ||
        pages > 10000 ||
        !['page', 'notebook'].contains(json['kind']) ||
        (json['kind'] == 'page' && pages != 1)) {
      throw const FormatException('Ungültige Vorlage.');
    }
    return NoteTemplate(
      id: id,
      name: name,
      kind: TemplateKind.values.byName(json['kind'] as String),
      pageCount: pages,
    );
  }
}

String templateName(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 120 ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(name)) {
    throw const FormatException('Vorlagennamen mit 1 bis 120 Zeichen angeben.');
  }
  return name;
}

const starterTemplates = [
  NoteTemplate(
    id: 'starter_cornell',
    name: 'Cornell-Notizen',
    kind: TemplateKind.page,
    pageCount: 1,
    builtIn: true,
  ),
  NoteTemplate(
    id: 'starter_meeting',
    name: 'Besprechung',
    kind: TemplateKind.page,
    pageCount: 1,
    builtIn: true,
  ),
  NoteTemplate(
    id: 'starter_week',
    name: 'Wochenplanung',
    kind: TemplateKind.page,
    pageCount: 1,
    builtIn: true,
  ),
];

/// One atomic archive per template, separate from notes and sync state.
/// Mutations are serialized; ZIP/PDF/file work runs outside the UI isolate.
class TemplateRepository {
  TemplateRepository(this.directory);
  final Directory directory;
  static const maxBytes = 256 * 1024 * 1024;
  final List<String> readErrors = [];
  Future<void> _queue = Future.value();
  Future<void> flush() => _queue;

  String _path(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        id.startsWith('starter_')) {
      throw const FormatException('Ungültige eigene Vorlagen-ID.');
    }
    return p.join(directory.path, '$id.template');
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<NoteTemplate>> list() async {
    await _queue;
    final path = directory.path;
    final result = await Isolate.run(() {
      Directory(path).createSync(recursive: true);
      final entries = <NoteTemplate>[], errors = <String>[];
      for (final file in Directory(path).listSync()) {
        if (file is! File || !file.path.endsWith('.template')) continue;
        try {
          final entry = _readTemplate(file.path, metadataOnly: true).$1;
          entries.add(entry);
        } catch (_) {
          errors.add(p.basename(file.path));
        }
      }
      entries.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return (entries, errors);
    }, debugName: 'noter:template-list');
    readErrors
      ..clear()
      ..addAll(result.$2);
    return [...result.$1, ...starterTemplates];
  }

  Future<NoteTemplate> save(
    String name,
    Uint8List pdf, {
    int? page,
    InkDocument? ink,
  }) {
    name = templateName(name);
    if (pdf.length > maxBytes) {
      throw const FormatException('Vorlage zu groß (maximal 256 MB).');
    }
    final transfer = TransferableTypedData.fromList([pdf]);
    final id = LocalNotebookRepository.newId();
    final path = _path(id);
    return _serialize(
      () => Isolate.run(() {
        final original = transfer.materialize().asUint8List();
        final bytes = _freshTemplatePdf(original, page: page);
        final count = PdfDocument.open(bytes).pageCount;
        final entry = NoteTemplate(
          id: id,
          name: name,
          kind: page == null ? TemplateKind.notebook : TemplateKind.page,
          pageCount: count,
        );
        final source = PdfDocument.open(original);
        final sidecar = ink == null
            ? null
            : InkDocument(
                generation: newInkId(),
                strokes: copiedPageInk(
                  ink,
                  source,
                  page == null
                      ? List.generate(source.pageCount, (i) => i)
                      : [page],
                  PdfDocument.open(bytes),
                ),
              );
        _writeTemplate(path, entry, bytes, ink: sidecar);
        return entry;
      }, debugName: 'noter:template-save'),
    );
  }

  /// Preview does not mutate the template. Instantiation below renews PDF-local
  /// annotation identities every time, even when inserting twice in one note.
  Future<Uint8List> preview(String id) async {
    await _queue;
    if (starterTemplates.any((entry) => entry.id == id)) {
      return Isolate.run(
        () => createStarterTemplate(id),
        debugName: 'noter:starter-template',
      );
    }
    final path = _path(id);
    return Isolate.run(() {
      final (_, bytes, ink) = _readTemplate(path);
      return ink == null ? bytes! : pdfWithInk(bytes!, ink);
    }, debugName: 'noter:template-read');
  }

  Future<Uint8List> instantiate(String id) async {
    final pages = await instantiateEditable(id);
    return pdfWithInk(pages.bytes, pages.ink);
  }

  Future<InkPages> instantiateEditable(String id) async {
    await _queue;
    if (starterTemplates.any((entry) => entry.id == id)) {
      return Isolate.run(
        () async => InkPages(
          await createStarterTemplate(id),
          InkDocument(generation: newInkId()),
        ),
        debugName: 'noter:starter-template',
      );
    }
    final path = _path(id);
    return Isolate.run(() {
      final (_, original, ink) = _readTemplate(path);
      final source = PdfDocument.open(original!);
      final bytes = _freshTemplatePdf(original);
      return InkPages(
        bytes,
        InkDocument(
          generation: newInkId(),
          strokes: ink == null
              ? []
              : copiedPageInk(
                  ink,
                  source,
                  List.generate(source.pageCount, (i) => i),
                  PdfDocument.open(bytes),
                ),
        ),
      );
    }, debugName: 'noter:template-copy');
  }

  Future<void> rename(String id, String name) {
    name = templateName(name);
    final path = _path(id);
    return _serialize(
      () => Isolate.run(() {
        final (old, pdf, ink) = _readTemplate(path);
        _writeTemplate(
          path,
          NoteTemplate(
            id: old.id,
            name: name,
            kind: old.kind,
            pageCount: old.pageCount,
          ),
          pdf!,
          ink: ink,
        );
      }, debugName: 'noter:template-rename'),
    );
  }

  Future<void> delete(String id) {
    final path = _path(id);
    return _serialize(
      () => Isolate.run(
        () => File(path).deleteSync(),
        debugName: 'noter:template-delete',
      ),
    );
  }
}

/// Deliberately copy pages, not the source notebook or document-level state.
/// Fresh extraction drops document-level outlines, attachments, XMP and old
/// revisions; page content remains intact. This is not a general PDF redactor.
Uint8List _freshTemplatePdf(Uint8List bytes, {int? page}) {
  validatePdf(bytes);
  final source = PdfDocument.open(bytes);
  if (source.pageCount > 10000) {
    throw const FormatException('Zu viele Vorlagenseiten.');
  }
  final indices = page == null
      ? List.generate(source.pageCount, (i) => i)
      : [RangeError.checkValidIndex(page, null, 'page', source.pageCount)];
  source.cos.trailer.entries.remove('Info');
  for (final index in indices) {
    final selected = source.page(index);
    selected.dict.entries.remove('Metadata');
    selected.dict.entries.remove('PieceInfo');
    for (final annotation in selected.annotations) {
      annotation.dict['NM'] = CosString.fromText(
        LocalNotebookRepository.newId(),
      );
      for (final key in ['T', 'M', 'CreationDate']) {
        annotation.dict.entries.remove(key);
      }
    }
  }
  return source.extractPages(indices);
}

(NoteTemplate, Uint8List?, InkDocument?) _readTemplate(
  String path, {
  bool metadataOnly = false,
}) {
  final file = File(path);
  if (file.lengthSync() > TemplateRepository.maxBytes) {
    throw const FormatException('Vorlage zu groß.');
  }
  final stream = InputFileStream(path, bufferSize: 64 * 1024);
  try {
    final archive = ZipDecoder().decodeStream(stream, verify: true);
    final manifest = archive.find('manifest.json'),
        pdf = archive.find('document.pdf');
    final inkFile = archive.find('ink.json');
    if (archive.files.length != (inkFile == null ? 2 : 3) ||
        manifest == null ||
        pdf == null ||
        manifest.size > 65536 ||
        pdf.size > TemplateRepository.maxBytes ||
        (inkFile != null && inkFile.size > InkDocument.maxBytes)) {
      throw const FormatException('Ungültiges Vorlagenarchiv.');
    }
    final entry = NoteTemplate.fromJson(
      jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>,
    );
    if (p.basenameWithoutExtension(path) != entry.id) {
      throw const FormatException('Falsche Vorlagen-ID.');
    }
    if (metadataOnly) return (entry, null, null);
    final bytes = Uint8List.fromList(pdf.content);
    validatePdf(bytes);
    if (PdfDocument.open(bytes).pageCount != entry.pageCount) {
      throw const FormatException('Falsche Seitenzahl.');
    }
    return (
      entry,
      bytes,
      inkFile == null ? null : InkDocument.decode(inkFile.content),
    );
  } finally {
    stream.closeSync();
  }
}

void _writeTemplate(
  String path,
  NoteTemplate entry,
  Uint8List pdf, {
  InkDocument? ink,
}) {
  NoteTemplate.fromJson(entry.toJson());
  final metadata = utf8.encode(jsonEncode(entry.toJson()));
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', metadata.length, metadata))
    ..addFile(
      ArchiveFile('document.pdf', pdf.length, pdf)
        ..compression = CompressionType.none,
    );
  if (ink != null && ink.strokes.isNotEmpty) {
    final bytes = ink.encode();
    archive.addFile(ArchiveFile('ink.json', bytes.length, bytes));
  }
  final bytes = ZipEncoder().encodeBytes(archive);
  if (bytes.length > TemplateRepository.maxBytes) {
    throw const FormatException('Vorlage zu groß (maximal 256 MB).');
  }
  File(path).parent.createSync(recursive: true);
  final temp = File('$path.tmp');
  temp.writeAsBytesSync(bytes, flush: true);
  temp.renameSync(path);
}
