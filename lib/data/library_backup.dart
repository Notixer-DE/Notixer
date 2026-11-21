import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'markdown_document.dart';
import 'notebook.dart';
import 'quick_todos.dart';
import 'knowledge.dart';
import 'templates.dart';
import 'ink.dart';
import 'catalog.dart';

/// Complete, checksummed snapshots, separate from bounded per-note history.
/// Restore creates a namespaced collection of copies, never overwrites notes.
class LibraryBackup {
  LibraryBackup(this.repository);
  final LocalNotebookRepository repository;
  Directory get directory =>
      Directory(p.join(repository.directory.path, '.backups'));
  static const maxBytes = 512 * 1024 * 1024;

  Future<Uint8List> snapshot() async {
    await repository.flush();
    await repository.templates.flush();
    final files = <String, Uint8List>{};
    var total = 0;
    final notes = await repository.list();
    if (repository.readErrors.isNotEmpty) {
      throw const FormatException(
        'Backup aborted: some library files could not be read. Previous snapshots are preserved.',
      );
    }
    for (final note in notes) {
      final bytes = await repository.exportArchive(note);
      total += bytes.length;
      if (total > maxBytes) {
        throw const FormatException(
          'Backup exceeds 512 MB. Export collections separately.',
        );
      }
      files['notes/${note.id}.noter'] = bytes;
    }
    for (final name in [
      '.knowledge.json',
      '.library.json',
      QuickTodoStore.fileName,
    ]) {
      final file = File(p.join(repository.directory.path, name));
      if (await file.exists()) {
        files['settings/$name'] = await file.readAsBytes();
      }
    }
    final templates = Directory(
      p.join(repository.directory.path, '.templates'),
    );
    if (await templates.exists()) {
      await for (final file in templates.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is! File) continue;
        final relative = p
            .relative(file.path, from: templates.path)
            .split(p.separator)
            .join('/');
        files['templates/$relative'] = await file.readAsBytes();
      }
    }
    total = files.values.fold(0, (sum, bytes) => sum + bytes.length);
    if (total > maxBytes) throw const FormatException('Backup exceeds 512 MB.');
    return _encodeSnapshot(files);
  }

  Future<File> create() async {
    final bytes = await snapshot();
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        'library-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.zip',
      ),
    );
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    final backups = await list();
    for (final old in backups.skip(7)) {
      await old.delete();
    }
    return file;
  }

  Future<List<File>> list() async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list()
        .where((file) => file is File && file.path.endsWith('.zip'))
        .cast<File>()
        .toList();
    final dated = [
      for (final file in files) (file, (await file.stat()).modified),
    ];
    dated.sort((a, b) {
      final order = b.$2.compareTo(a.$2);
      return order == 0 ? b.$1.path.compareTo(a.$1.path) : order;
    });
    return dated.map((entry) => entry.$1).toList();
  }

  Future<List<Notebook>> restore(Uint8List bytes) async {
    if (bytes.length > maxBytes) {
      throw const FormatException('Backup exceeds 512 MB.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > 10000) {
      throw const FormatException('Too many backup entries.');
    }
    final files = <String, Uint8List>{};
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!MarkdownDocument.safePath(file.name) ||
          files.containsKey(file.name)) {
        throw const FormatException('Unsafe or duplicate backup path.');
      }
      total += file.size;
      if (total > maxBytes) {
        throw const FormatException('Extracted backup exceeds 512 MB.');
      }
      files[file.name] = Uint8List.fromList(file.content);
    }
    final manifestBytes = files.remove('backup.json');
    if (manifestBytes == null) {
      throw const FormatException('Not a Notixer library backup.');
    }
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    if (manifest['version'] != 1) {
      throw const FormatException('Unsupported backup version.');
    }
    final hashes = manifest['files'] as Map<String, dynamic>;
    if (hashes.length != files.length ||
        files.entries.any(
          (entry) =>
              hashes[entry.key] != sha256.convert(entry.value).toString(),
        )) {
      throw const FormatException('Backup checksum mismatch.');
    }
    // Validate the entire collection before writing the first restored note.
    final decoded = [
      for (final entry in files.entries.where(
        (entry) => entry.key.startsWith('notes/'),
      ))
        await LocalNotebookRepository.decodeInkValidated(entry.value),
    ];
    final paths = <String>{};
    for (final (note, _, _) in decoded) {
      if (!paths.add(note.documentPath)) {
        throw const FormatException('Ambiguous document paths in backup.');
      }
    }
    Map<String, dynamic>? settings;
    final knowledge = files['settings/.knowledge.json'];
    if (knowledge != null) {
      settings = jsonDecode(utf8.decode(knowledge)) as Map<String, dynamic>;
      validateKnowledgeSettings(settings);
    }
    final backupTodos = QuickTodoStore.decode(
      files['settings/${QuickTodoStore.fileName}'],
    );
    final pdfTemplates = <(String, Uint8List, InkDocument?)>[];
    for (final entry in files.entries.where(
      (entry) =>
          entry.key.startsWith('templates/') && entry.key.endsWith('.template'),
    )) {
      final archive = ZipDecoder().decodeBytes(entry.value, verify: true);
      final manifest = archive.find('manifest.json'),
          pdf = archive.find('document.pdf'),
          ink = archive.find('ink.json');
      if (manifest == null ||
          pdf == null ||
          archive.files.length != (ink == null ? 2 : 3)) {
        throw const FormatException('Invalid PDF template.');
      }
      final metadata = NoteTemplate.fromJson(
        jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>,
      );
      final bytes = Uint8List.fromList(pdf.content);
      validatePdf(bytes);
      pdfTemplates.add((
        metadata.name,
        bytes,
        ink == null ? null : InkDocument.decode(ink.content),
      ));
    }
    final backupFolders = <NoteFolder>[];
    final catalogBytes = files['settings/.library.json'];
    if (catalogBytes != null) {
      final catalog =
          jsonDecode(utf8.decode(catalogBytes)) as Map<String, dynamic>;
      if (catalog['version'] != 1 ||
          catalog['folders'] is! List ||
          catalog['presets'] is! List) {
        throw const FormatException('Invalid backup catalog.');
      }
      for (final row in catalog['folders']) {
        if (row is! Map ||
            row['id'] is! String ||
            row['name'] is! String ||
            (row['name'] as String).trim().isEmpty) {
          throw const FormatException('Invalid backup folder.');
        }
        backupFolders.add(
          NoteFolder(row['id'] as String, row['name'] as String),
        );
      }
      for (final row in catalog['presets']) {
        PenPreset.fromJson(Map<String, dynamic>.from(row));
      }
    }
    final wasEmpty = (await repository.list()).isEmpty;
    final store = KnowledgeStore(repository);
    await store.load();
    final namespace = 'restored-${LocalNotebookRepository.newId()}';
    final result = <Notebook>[];
    final folderIds = <String, String>{};
    for (final folder in backupFolders) {
      folderIds[folder.id] = (await repository.catalog.ensureFolder(
        folder.name,
      )).id;
    }
    for (final (note, payload, ink) in decoded) {
      final folder = note.folderName == null
          ? null
          : await repository.catalog.ensureFolder(note.folderName!);
      if (note.folderId != null && folder != null) {
        folderIds[note.folderId!] = folder.id;
      }
      final copy = Notebook(
        id: LocalNotebookRepository.newId(),
        title: note.title,
        created: note.created,
        modified: note.modified,
        paper: note.paper,
        lineColor: note.lineColor,
        folderId: folder?.id,
        folderName: folder?.name,
        tags: note.tags,
        learning: note.learning,
        linkPath: '$namespace/${note.documentPath}',
      );
      result.add(
        ink == null
            ? await repository.save(copy, payload)
            : await repository.saveWithInk(copy, payload, ink),
      );
    }
    if (backupTodos.isNotEmpty) {
      await QuickTodoStore(repository.directory).change((tasks) {
        for (final todo in backupTodos.values) {
          final current = tasks[todo.id];
          if (current == null || todo.supersedes(current)) {
            tasks[todo.id] = todo.withProject(folderIds[todo.project]);
          }
        }
      });
    }
    if (settings != null) {
      final templateIds = <String, String>{};
      for (final row in settings['templates']) {
        final identical = store.templates.where(
          (t) => t.name == row['name'] && t.source == row['source'],
        );
        if (identical.isNotEmpty) {
          templateIds[row['id'] as String] = identical.first.id;
          continue;
        }
        final id = LocalNotebookRepository.newId();
        templateIds[row['id'] as String] = id;
        store.templates.add(
          MarkdownTemplate(id, row['name'] as String, row['source'] as String),
        );
      }
      for (final row in settings['views']) {
        final view = KnowledgeView.fromJson(Map<String, dynamic>.from(row));
        final folder = view.folder.isEmpty
            ? ''
            : folderIds[view.folder] ??
                  'missing:${sha256.convert(utf8.encode(view.folder))}';
        final restoredName = RegExp(
          '^${RegExp.escape(view.name)} '
          r'\(restored(?: [0-9]+)?\)$',
        );
        final duplicate = store.views.any(
          (existing) =>
              (existing.name == view.name ||
                  restoredName.hasMatch(existing.name)) &&
              existing.query == view.query &&
              existing.tag.toLowerCase() == view.tag.toLowerCase() &&
              existing.folder == folder &&
              existing.kind == view.kind &&
              existing.openTasks == view.openTasks &&
              existing.completedTasks == view.completedTasks,
        );
        if (duplicate) continue;
        var name = view.name;
        for (
          var suffix = 1;
          store.views.any((existing) => existing.name == name);
          suffix++
        ) {
          name = '${view.name} (restored${suffix == 1 ? '' : ' $suffix'})';
        }
        store.views.add(
          KnowledgeView(
            name,
            query: view.query,
            tag: view.tag,
            folder: folder,
            kind: view.kind,
            openTasks: view.openTasks,
            completedTasks: view.completedTasks,
          ),
        );
      }
      if (wasEmpty) {
        store.journalTemplate = templateIds[settings['journalTemplate']];
        store.automaticBackups = settings['automaticBackups'] as bool? ?? true;
      } else {
        store.journalTemplate ??= templateIds[settings['journalTemplate']];
      }
      await store.save();
    }
    for (final (name, bytes, ink) in pdfTemplates) {
      await repository.templates.save(name, bytes, ink: ink);
    }
    return result;
  }
}

/// Runs only while the app is alive; no unsupported background-service promise.
class AutomaticBackupScheduler {
  AutomaticBackupScheduler(this.repository, {required this.prepare});
  final LocalNotebookRepository repository;
  final Future<bool> Function() prepare;
  Timer? _initial, _periodic;
  bool _running = false, _disposed = false;
  String? _fingerprint;
  void start() {
    _initial = Timer(const Duration(seconds: 30), check);
    _periodic = Timer.periodic(const Duration(minutes: 15), (_) => check());
  }

  Future<void> check() async {
    if (_disposed || _running) return;
    _running = true;
    final backup = LibraryBackup(repository);
    try {
      final store = KnowledgeStore(repository);
      await store.load();
      if (!store.automaticBackups || _disposed) return;
      if (!await prepare() || _disposed) {
        throw const FormatException(
          'Could not save open documents for backup.',
        );
      }
      final notes = await repository.list();
      if (repository.readErrors.isNotEmpty) {
        throw const FormatException(
          'Some library files could not be read; automatic backup was not replaced.',
        );
      }
      if (notes.isEmpty) return;
      final settings = await store.file.exists()
          ? await store.file.readAsString()
          : '';
      final catalogFile = repository.catalog.file;
      final catalog = await catalogFile.exists()
          ? await catalogFile.readAsString()
          : '';
      final templates = jsonEncode(
        (await repository.templates.list())
            .map((template) => template.toJson())
            .toList(),
      );
      final fingerprint = sha256
          .convert(
            utf8.encode(
              '${notes.map((n) => '${n.id}:${n.modified.toIso8601String()}').join('|')}:$settings:$catalog:$templates',
            ),
          )
          .toString();
      final status = await _readStatus(backup.directory);
      final savedFile = status['file'];
      final savedExists =
          savedFile is String &&
          p.basename(savedFile) == savedFile &&
          await File(p.join(backup.directory.path, savedFile)).exists();
      if ((_fingerprint == fingerprint ||
              status['fingerprint'] == fingerprint) &&
          savedExists) {
        if (status.containsKey('error')) {
          status.remove('error');
          status.remove('attempted');
          await _writeStatus(backup.directory, status);
        }
        return;
      }
      if (_disposed) return;
      final file = await backup.create();
      _fingerprint = fingerprint;
      await _writeStatus(backup.directory, {
        'fingerprint': fingerprint,
        'lastSuccess': DateTime.now().toUtc().toIso8601String(),
        'file': p.basename(file.path),
      });
    } catch (error) {
      try {
        await backup.directory.create(recursive: true);
        await _writeStatus(backup.directory, {
          ...await _readStatus(backup.directory),
          'error': '$error',
          'attempted': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {
        /* Storage failures must not crash or prevent note editing. */
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _initial?.cancel();
    _periodic?.cancel();
  }
}

Future<Uint8List> _encodeSnapshot(Map<String, Uint8List> files) =>
    Isolate.run(() {
      final archive = Archive();
      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value)
            ..compression = CompressionType.none,
        );
      }
      final manifest = utf8.encode(
        jsonEncode({
          'version': 1,
          'created': DateTime.now().toUtc().toIso8601String(),
          'files': {
            for (final entry in files.entries)
              entry.key: sha256.convert(entry.value).toString(),
          },
        }),
      );
      archive.addFile(ArchiveFile('backup.json', manifest.length, manifest));
      return Uint8List.fromList(ZipEncoder().encode(archive));
    });

Future<Map<String, dynamic>> _readStatus(Directory directory) async {
  try {
    return jsonDecode(
          await File(p.join(directory.path, 'status.json')).readAsString(),
        )
        as Map<String, dynamic>;
  } on Object {
    return {};
  }
}

Future<void> _writeStatus(
  Directory directory,
  Map<String, dynamic> value,
) async {
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, 'status.json'));
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(file.path);
}
