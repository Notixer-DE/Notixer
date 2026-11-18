import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;
import '../data/catalog.dart';
import '../data/drawing_preferences.dart';
import '../data/ink.dart';
import '../data/knowledge.dart';
import '../data/markdown_document.dart';
import '../data/notebook.dart';
import '../data/templates.dart';
import 'notebook_sync.dart';
import 'sync_revision.dart';

/// Reuse the encrypted revision/conflict protocol for individually addressable
/// templates and preferences. Staging archives never appear as user documents.
class LibraryExtrasSync {
  LibraryExtrasSync(this.repository, this.remote, {this.onProgress});
  final LocalNotebookRepository repository;
  final RevisionRemote remote;
  final void Function(String)? onProgress;
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  static String _id(String kind, String key) =>
      'extra_${sha256.convert(utf8.encode('$kind:$key'))}';
  static const _files = [
    '.knowledge.json',
    '.library.json',
    '.drawing-preferences.json',
    '.reading-positions.json',
    '.display-preferences.json',
  ];

  Future<SyncReport> run({bool onlyIfChanged = false}) async {
    final directory = Directory(
      p.join(repository.directory.path, '.sync-extras'),
    );
    await directory.create(recursive: true);
    final states = <String, Uint8List>{};
    await for (final file in directory.list()) {
      if (file is File &&
          p.basename(file.path).startsWith('.sync-state-') &&
          file.path.endsWith('.json')) {
        states[file.path] = await file.readAsBytes();
      }
    }
    try {
      return await _run(onlyIfChanged: onlyIfChanged);
    } catch (_) {
      // Committing staging heads before source files is not a completed sync.
      // Rewind the local baseline so a retry still detects concurrent edits.
      await for (final file in directory.list()) {
        if (file is File &&
            p.basename(file.path).startsWith('.sync-state-') &&
            file.path.endsWith('.json') &&
            !states.containsKey(file.path)) {
          await file.delete();
        }
      }
      for (final entry in states.entries) {
        final temporary = File('${entry.key}.tmp');
        await temporary.writeAsBytes(entry.value, flush: true);
        await temporary.rename(entry.key);
      }
      rethrow;
    }
  }

  Future<String> _fingerprint() async {
    final parts = <String>[];
    for (final name in _files) {
      final file = File(p.join(repository.directory.path, name));
      parts.add(
        '$name:${await file.exists() ? sha256.convert(await file.readAsBytes()) : 'missing'}',
      );
    }
    final templates = repository.templates.directory;
    if (await templates.exists()) {
      await for (final file in templates.list()) {
        if (file is! File || !file.path.endsWith('.template')) continue;
        final stat = await file.stat();
        parts.add(
          '${p.basename(file.path)}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}',
        );
      }
    }
    parts.sort();
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  Future<SyncReport> _run({required bool onlyIfChanged}) async {
    onProgress?.call('Checking templates and preferences …');
    await repository.flush();
    await repository.catalog.readingPositions.flush();
    final staging = LocalNotebookRepository(
      Directory(p.join(repository.directory.path, '.sync-extras')),
      clock: () => _epoch,
    );
    final before = <String, Uint8List?>{};
    for (final name in _files) {
      final file = File(p.join(repository.directory.path, name));
      before[name] = await file.exists() ? await file.readAsBytes() : null;
    }
    final knowledge = KnowledgeStore(repository);
    await knowledge.load();
    await repository.catalog.load();
    final sessionRemote = remote is SyncSessionRemote
        ? remote
        : SyncSessionRemote(remote);
    final account = sha256.convert(
      utf8.encode(await sessionRemote.accountId()),
    );
    final fingerprintFile = File(
      p.join(staging.directory.path, '.local-fingerprint-$account'),
    );
    if (onlyIfChanged &&
        await fingerprintFile.exists() &&
        await fingerprintFile.readAsString() == await _fingerprint()) {
      return SyncReport();
    }
    final remoteIds = (await sessionRemote.list()).map((r) => r.noteId).toSet();
    final expected = <String>{};
    final old = {for (final note in await staging.list()) note.id: note};
    Future<void> stage(
      String kind,
      String key,
      String title,
      Uint8List bytes, {
      InkDocument? ink,
      String paper = 'markdown',
      bool preferRemote = false,
    }) async {
      final id = _id(kind, key);
      expected.add(id);
      if (preferRemote && !old.containsKey(id) && remoteIds.contains(id)) {
        return;
      }
      final note = Notebook(
        id: id,
        title: title,
        created: _epoch,
        modified: _epoch,
        paper: paper,
        tags: [
          jsonEncode({'kind': kind, 'key': key}),
        ],
      );
      final archive = await LocalNotebookRepository.encodeAsync(
        note,
        bytes,
        ink: ink,
      );
      final existing = old[id] == null
          ? null
          : await staging.snapshotForSync(id);
      if (existing != null &&
          await archiveDigestAsync(existing.archive) ==
              await archiveDigestAsync(archive)) {
        return;
      }
      if (ink == null) {
        await staging.save(note, bytes);
      } else {
        await staging.saveWithInk(note, bytes, ink);
      }
    }

    Future<void> value(
      String kind,
      String key,
      Object? data, {
      String? title,
      bool preferRemote = false,
    }) => stage(
      kind,
      key,
      title ?? '$kind: $key',
      MarkdownDocument(jsonEncode(data)).encode(),
      preferRemote: preferRemote,
    );
    if (before['.knowledge.json'] != null) {
      for (final template in knowledge.templates) {
        await stage(
          'markdown',
          template.id,
          template.name,
          MarkdownDocument(template.source).encode(),
          preferRemote:
              template.id == 'daily' &&
              template.source ==
                  KnowledgeStore(repository).templates.single.source,
        );
      }
      for (final view in knowledge.views) {
        final data = Map<String, dynamic>.from(view.toJson());
        if (view.folder.isNotEmpty) {
          data['folderName'] = repository.catalog.folderName(view.folder);
          data['folder'] = '';
          if (data['folderName'] == null) data['folder'] = view.folder;
        }
        await value('view', view.name, data);
      }
      await value(
        'knowledge',
        'journalTemplate',
        knowledge.journalTemplate,
        preferRemote: knowledge.journalTemplate == 'daily',
      );
      await value(
        'knowledge',
        'automaticBackups',
        knowledge.automaticBackups,
        preferRemote: knowledge.automaticBackups,
      );
    }
    if (before['.library.json'] != null) {
      for (final folder in repository.catalog.folders) {
        await value('folder', folder.name.toLowerCase(), folder.name);
      }
      for (var i = 0; i < repository.catalog.presets.length; i++) {
        await value(
          'preset',
          '$i',
          repository.catalog.presets[i].toJson(),
          preferRemote:
              i < 3 &&
              jsonEncode(repository.catalog.presets[i].toJson()) ==
                  jsonEncode(
                    LibraryCatalog(File('unused')).presets[i].toJson(),
                  ),
        );
      }
    }
    for (final name in [
      '.drawing-preferences.json',
      '.reading-positions.json',
      '.display-preferences.json',
    ]) {
      final bytes = before[name];
      if (bytes == null) continue;
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['version'] != 1) {
        throw const FormatException('Unsupported preference version.');
      }
      for (final section in json.entries.where(
        (entry) => entry.key != 'version',
      )) {
        final values = section.value as Map;
        for (final entry in values.entries) {
          if (section.key == 'values' && entry.key == 'pressureSensitive') {
            for (final pressure in (entry.value as Map).entries) {
              await value(
                name,
                'pressureSensitive.${pressure.key}',
                pressure.value,
              );
            }
          } else {
            await value(name, '${section.key}.${entry.key}', entry.value);
          }
        }
      }
    }
    final pdfBefore = <String, Uint8List>{};
    for (final template in (await repository.templates.list()).where(
      (t) => !t.builtIn,
    )) {
      final snapshot = await repository.templates.syncSnapshot(template.id);
      pdfBefore[template.id] = snapshot.$4;
      await stage(
        'pdf.${template.kind.name}',
        template.id,
        template.name,
        snapshot.$2,
        paper: 'pdf',
        ink: snapshot.$3,
      );
    }
    if (repository.templates.readErrors.isNotEmpty) {
      throw const SyncFailure(
        'Some templates are unreadable. Sync stopped without deleting them.',
      );
    }
    for (final note in old.values.where(
      (note) => !expected.contains(note.id),
    )) {
      await staging.delete(note.id);
    }
    final report = await NotebookSync(
      staging,
      sessionRemote,
      extras: true,
      onProgress: onProgress,
    ).run();
    // All incoming records are validated before applying any preference.
    final records =
        <
          ({
            Notebook note,
            String kind,
            String key,
            Uint8List bytes,
            InkDocument? ink,
          })
        >[];
    for (final note in await staging.list()) {
      final metadata = jsonDecode(note.tags.single) as Map;
      final kind = metadata['kind'] as String, key = metadata['key'] as String;
      final snapshot = await staging.snapshotForSync(note.id);
      final (_, bytes, ink) = await LocalNotebookRepository.decodeInkValidated(
        snapshot!.archive,
      );
      if (kind.startsWith('pdf.')) {
        if (!note.isPdf || !['pdf.page', 'pdf.notebook'].contains(kind)) {
          throw const FormatException('Invalid synced template.');
        }
        templateName(note.title);
        if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(key) ||
            key.startsWith('starter_')) {
          throw const FormatException('Invalid template identity.');
        }
      } else {
        if (!note.isMarkdown) {
          throw const FormatException('Invalid synced setting.');
        }
        final doc = await decodeMarkdownAsync(bytes);
        if (kind == 'markdown' && key.isEmpty) {
          throw const FormatException('Invalid Markdown template identity.');
        }
        if (kind != 'markdown') _validate(kind, key, jsonDecode(doc.source));
      }
      records.add((note: note, kind: kind, key: key, bytes: bytes, ink: ink));
    }
    // Remote I/O must not overwrite an external writer's changes.
    await repository.flush();
    for (final name in _files) {
      final file = File(p.join(repository.directory.path, name));
      final current = await file.exists() ? await file.readAsBytes() : null;
      if (!listEquals(current, before[name])) {
        throw const SyncFailure(
          'Preferences changed during sync. Sync again to preserve both edits.',
        );
      }
    }
    final nextTemplates = <MarkdownTemplate>[];
    final nextViews = <KnowledgeView>[];
    final settings = <String, Map<String, dynamic>>{
      for (final name in [
        '.drawing-preferences.json',
        '.reading-positions.json',
        '.display-preferences.json',
      ])
        if (before[name] != null)
          name: name == '.reading-positions.json'
              ? {
                  'version': 1,
                  'pages': <String, dynamic>{},
                  'markdown': <String, dynamic>{},
                }
              : {'version': 1, 'values': <String, dynamic>{}},
    };
    final livePdf = <String>{};
    final folderNames = <String>{};
    bool hasKnowledge = before['.knowledge.json'] != null;
    for (final record in records.where((r) => r.kind == 'folder')) {
      final name =
          jsonDecode((await decodeMarkdownAsync(record.bytes)).source)
              as String;
      folderNames.add(name.toLowerCase());
      await repository.catalog.ensureFolder(name);
    }
    for (final record in records) {
      final conflict = record.note.id != _id(record.kind, record.key);
      if (record.kind.startsWith('pdf.')) {
        final id = conflict ? record.note.id : record.key;
        livePdf.add(id);
        await repository.templates.applySynced(
          id,
          record.note.title,
          TemplateKind.values.byName(record.kind.substring(4)),
          record.bytes,
          record.ink,
          pdfBefore[id],
        );
        continue;
      }
      final document = await decodeMarkdownAsync(record.bytes);
      if (record.kind == 'markdown') {
        hasKnowledge = true;
        nextTemplates.add(
          MarkdownTemplate(
            conflict ? record.note.id : record.key,
            record.note.title,
            document.source,
          ),
        );
        continue;
      }
      final data = jsonDecode(document.source);
      if (record.kind == 'view') {
        hasKnowledge = true;
        final map = Map<String, dynamic>.from(data as Map);
        map['name'] = conflict ? record.note.title : record.key;
        final folderName = map.remove('folderName');
        if (folderName is String) {
          map['folder'] = (await repository.catalog.ensureFolder(
            folderName,
          )).id;
        }
        nextViews.add(KnowledgeView.fromJson(map));
      } else if (!conflict) {
        if (record.kind == 'knowledge') {
          hasKnowledge = true;
          if (record.key == 'journalTemplate') {
            knowledge.journalTemplate = data as String?;
          }
          if (record.key == 'automaticBackups') {
            knowledge.automaticBackups = data as bool;
          }
        } else if (record.kind == 'preset') {
          final index = int.parse(record.key);
          if (index < repository.catalog.presets.length) {
            await repository.catalog.setPreset(
              index,
              PenPreset.fromJson(Map<String, dynamic>.from(data as Map)),
            );
          }
        } else if (record.kind.startsWith('.')) {
          final target = settings.putIfAbsent(
            record.kind,
            () => record.kind == '.reading-positions.json'
                ? {
                    'version': 1,
                    'pages': <String, dynamic>{},
                    'markdown': <String, dynamic>{},
                  }
                : {'version': 1},
          );
          final split = record.key.indexOf('.');
          var section = record.key.substring(0, split);
          var key = record.key.substring(split + 1);
          if (section == 'pressureSensitive') {
            final values =
                target.putIfAbsent('values', () => <String, dynamic>{}) as Map;
            (values.putIfAbsent('pressureSensitive', () => <String, dynamic>{})
                    as Map)[key] =
                data;
          } else {
            (target.putIfAbsent(section, () => <String, dynamic>{})
                    as Map)[key] =
                data;
          }
        }
      } else if (record.kind != 'folder') {
        // Keep concurrent setting values visible and portable for manual review.
        final conflictId = 'settings_${record.note.id}';
        final current = (await repository.list()).any(
          (note) => note.id == conflictId,
        );
        if (!current) {
          await repository.save(
            Notebook(
              id: conflictId,
              title: 'Settings conflict: ${record.note.title}',
              created: _epoch,
              modified: _epoch,
              paper: 'markdown',
              tags: const ['Sync conflict'],
            ),
            MarkdownDocument(
              '# Sync setting conflict\n\nBoth versions were preserved. Review this alternative before changing the current setting.\n\n```json\n${const JsonEncoder.withIndent('  ').convert({'setting': record.kind, 'key': record.key, 'value': data})}\n```\n',
            ).encode(),
          );
        }
      }
    }
    for (final id in pdfBefore.keys.where((id) => !livePdf.contains(id))) {
      await repository.templates.applySynced(
        id,
        '',
        TemplateKind.page,
        null,
        null,
        pdfBefore[id],
      );
    }
    // Remove only folders which existed in this snapshot; note sync maps names.
    for (final folder
        in repository.catalog.folders
            .where((f) => !folderNames.contains(f.name.toLowerCase()))
            .toList()) {
      if (before['.library.json'] != null) {
        await repository.catalog.removeFolder(folder.id);
      }
    }
    if (hasKnowledge) {
      knowledge.templates = nextTemplates;
      knowledge.views = nextViews;
      if (!nextTemplates.any((t) => t.id == knowledge.journalTemplate)) {
        knowledge.journalTemplate = null;
      }
      await knowledge.save();
    }
    for (final entry in settings.entries) {
      final file = File(p.join(repository.directory.path, entry.key));
      final encoded = jsonEncode(entry.value);
      if (await file.exists() && await file.readAsString() == encoded) continue;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    }
    await repository.catalog.reload();
    final temporaryFingerprint = File('${fingerprintFile.path}.tmp');
    await temporaryFingerprint.writeAsString(await _fingerprint(), flush: true);
    await temporaryFingerprint.rename(fingerprintFile.path);
    return report;
  }

  static void _validate(String kind, String key, dynamic data) {
    if (kind == 'folder') {
      if (data is! String || data.trim().isEmpty || data.length > 1024) {
        throw const FormatException('Invalid folder.');
      }
    } else if (kind == 'view') {
      KnowledgeView.fromJson(Map<String, dynamic>.from(data as Map));
    } else if (kind == 'preset') {
      if (int.tryParse(key) == null ||
          int.parse(key) < 0 ||
          int.parse(key) > 20) {
        throw const FormatException('Invalid preset.');
      }
      PenPreset.fromJson(Map<String, dynamic>.from(data as Map));
    } else if (kind == 'knowledge') {
      if (!(key == 'journalTemplate' && (data == null || data is String) ||
          key == 'automaticBackups' && data is bool)) {
        throw const FormatException('Invalid knowledge setting.');
      }
    } else if (kind == '.drawing-preferences.json') {
      if (key == 'values.lastTool') {
        DrawingToolChoice.fromJson(Map<String, dynamic>.from(data as Map));
      } else if (![
            'values.wholeStrokeEraser',
            'values.straightStrokes',
            'pressureSensitive.ink',
            'pressureSensitive.highlight',
          ].contains(key) ||
          data is! bool) {
        throw const FormatException('Invalid drawing setting.');
      }
    } else if (kind == '.reading-positions.json') {
      if (!(key.startsWith('pages.') && data is int && data >= 0 ||
          key.startsWith('markdown.') &&
              data is num &&
              data.isFinite &&
              data >= 0)) {
        throw const FormatException('Invalid reading position.');
      }
    } else if (kind == '.display-preferences.json') {
      if (!key.startsWith('values.') ||
          (data is! bool &&
              (data is! num || !data.isFinite || data < .7 || data > 2.5))) {
        throw const FormatException('Invalid display setting.');
      }
    } else {
      throw const FormatException('Unknown synced preference.');
    }
  }
}
