import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/sync/sync_revision.dart';
import 'package:noter/ui/sync_page.dart';

import 'sync_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository a, b;
  late MemoryRemote remote;
  late Uint8List paper;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-single-sync-');
    a = LocalNotebookRepository(Directory('${directory.path}/a'));
    b = LocalNotebookRepository(Directory('${directory.path}/b'));
    remote = MemoryRemote();
    paper = await createPaper('grid');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Map<String, dynamic>> state(LocalNotebookRepository repo) async {
    final file = await repo.directory
        .list()
        .where((entry) => entry.path.contains('.sync-state-'))
        .cast<File>()
        .single;
    return (jsonDecode(await file.readAsString())
            as Map<String, dynamic>)['notes']
        as Map<String, dynamic>;
  }

  test('settings sync defaults on and is saved per device', () async {
    await a.directory.create(recursive: true);
    await File('${a.directory.path}/.server-sync.json').writeAsString(
      jsonEncode({'server': '', 'automatic': true, 'enabled': false}),
    );
    final first = SyncController(a);
    final reloaded = SyncController(a);
    final other = SyncController(b);
    addTearDown(first.dispose);
    addTearDown(reloaded.dispose);
    addTearDown(other.dispose);
    await first.load();
    expect(first.settingsSync, isTrue);
    await first.setSettingsSync(false);
    expect(first.error, isNull);
    await reloaded.load();
    await other.load();
    expect(reloaded.settingsSync, isFalse);
    expect(reloaded.automatic, isTrue);
    expect(other.settingsSync, isTrue);
    await reloaded.setSettingsSync(true);
    final enabledAgain = SyncController(a);
    addTearDown(enabledAgain.dispose);
    await enabledAgain.load();
    expect(enabledAgain.settingsSync, isTrue);
  });

  test(
    'selection uploads only one note; omitted selection still syncs all',
    () async {
      final selected = await a.create('Selected', paper);
      final other = await a.create('Other', paper);
      await b.create('Remote only', paper);
      await NotebookSync(b, remote).run();
      final report = await NotebookSync(a, remote).run(noteId: selected.id);
      expect(report.uploaded, 1);
      expect(report.downloaded, 0);
      expect((await a.list()).length, 2);
      expect(remote.revisions.values.any((r) => r.noteId == other.id), false);
      expect((await state(a)).keys, [selected.id]);
      final full = await NotebookSync(a, remote).run();
      expect(full.uploaded, 1);
      expect(full.downloaded, 1);
      expect((await a.list()).length, 3);
    },
  );

  test(
    'selection downloads edits without processing other edits or deletions',
    () async {
      final selected = await a.create('Selected', paper);
      final other = await a.create('Other', paper);
      final deleted = await a.create('Deleted later', paper);
      await NotebookSync(a, remote).run();
      await NotebookSync(b, remote).run();
      final before = await state(a);
      await b.save(selected.copy(title: 'Remote edit'), paper);
      await b.save(other.copy(title: 'Other remote edit'), paper);
      await b.delete(deleted.id);
      await NotebookSync(b, remote).run();
      await a.save(other.copy(title: 'Local unsynced edit'), paper);
      final revisionsBefore = remote.revisions.length;
      final report = await NotebookSync(a, remote).run(noteId: selected.id);
      expect(report.downloaded, 1);
      expect(report.uploaded, 0);
      expect(remote.revisions.length, revisionsBefore);
      final notes = {for (final note in await a.list()) note.id: note};
      expect(notes[selected.id]!.title, 'Remote edit');
      expect(notes[other.id]!.title, 'Local unsynced edit');
      expect(notes.containsKey(deleted.id), true);
      final after = await state(a);
      expect(after[other.id], before[other.id]);
      expect(after[deleted.id], before[deleted.id]);
      await NotebookSync(a, remote).run();
      expect((await a.list()).any((note) => note.id == deleted.id), false);
      expect(
        (await a.list()).length,
        3,
      ); // Selected, other and its conflict copy.
    },
  );

  test(
    'selection handles incoming deletion without deleting another note',
    () async {
      final selected = await a.create('Selected', paper);
      final other = await a.create('Other', paper);
      await NotebookSync(a, remote).run();
      await NotebookSync(b, remote).run();
      await b.delete(selected.id);
      await b.delete(other.id);
      await NotebookSync(b, remote).run();
      final report = await NotebookSync(a, remote).run(noteId: selected.id);
      expect(report.deleted, 1);
      expect((await a.list()).single.id, other.id);
    },
  );

  test('selected conflict creates and downloads its conflict copy', () async {
    final selected = await a.create('Selected', paper);
    await NotebookSync(a, remote).run();
    await NotebookSync(b, remote).run();
    await a.create('Not selected', paper);
    await a.save(selected.copy(title: 'Local version'), paper);
    await b.save(selected.copy(title: 'Remote version'), paper);
    await NotebookSync(b, remote).run();
    final report = await NotebookSync(a, remote).run(noteId: selected.id);
    expect(report.conflicts, 1);
    final notes = await a.list();
    expect(notes.length, 3);
    expect(notes.any((note) => note.title.startsWith('Local version')), true);
    expect(notes.any((note) => note.title.startsWith('Remote version')), true);
    expect(
      remote.revisions.values.every(
        (r) => r.noteId == selected.id || r.noteId.startsWith('conflict_'),
      ),
      true,
    );
    expect(
      (await NotebookSync(a, remote).run(noteId: selected.id)).uploaded,
      0,
    );
  });

  test(
    'missing, empty and invalid selections fail without fallback or state changes',
    () async {
      final selected = await a.create('Selected', paper);
      final other = await a.create('Other', paper);
      await NotebookSync(a, remote).run();
      final before = await state(a);
      await a.delete(selected.id);
      await a.save(other.copy(title: 'Pending'), paper);
      final count = remote.revisions.length;
      for (final id in [selected.id, '', '../invalid', 'unknown']) {
        await expectLater(
          NotebookSync(a, remote).run(noteId: id),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.message,
              'message',
              contains('select it again'),
            ),
          ),
        );
        expect(remote.revisions.length, count);
        expect(await state(a), before);
      }
    },
  );

  testWidgets('manual selection is forwarded and can be cleared', (
    tester,
  ) async {
    final selected = (await tester.runAsync(() => a.create('My note', paper)))!;
    final controller = _RecordingController(a)..enabled = true;
    await tester.pumpWidget(
      MaterialApp(home: SyncPage(controller: controller)),
    );
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(controller.selections, [null]);
    await tester.tap(find.text('Sync note (optional)'));
    final option = find.widgetWithText(SimpleDialogOption, selected.title);
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      if (option.evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync selected note'));
    for (var i = 0; i < 150 && controller.selections.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(controller.selections, [null, selected.id]);
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(controller.selections, [null, selected.id, null]);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('pausing settings hides an existing notice from manual sync', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026);
    const title = 'Existing settings conflict';
    await tester.runAsync(() async {
      await a.save(
        Notebook(
          id: 'settings_extra_conflict_${'a' * 40}',
          title: title,
          paper: 'markdown',
          created: now,
          modified: now,
        ),
        MarkdownDocument('Conflict').encode(),
      );
      await a.create('Regular note', paper);
    });
    final controller = _RecordingController(a)..enabled = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: SyncPage(controller: controller)),
    );

    Future<void> openPicker() async {
      await tester.tap(find.text('Sync note (optional)'));
      for (var i = 0; i < 150; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text('Regular note').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
    }

    await openPicker();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(find.text('Sync selected note'), findsOneWidget);

    final settingsSwitch = find.widgetWithText(
      SwitchListTile,
      'Sync settings on this device',
    );
    await tester.ensureVisible(settingsSwitch);
    await tester.tap(settingsSwitch);
    for (var i = 0; i < 150 && controller.busy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(controller.settingsSync, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(find.text(title), findsNothing);
    expect(find.text('Sync now'), findsOneWidget);
    await openPicker();
    expect(find.text('Regular note'), findsOneWidget);
    expect(find.text(title), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _RecordingController extends SyncController {
  _RecordingController(super.repository);
  final selections = <String?>[];

  @override
  Future<void> synchronize({String? noteId, bool onlyIfChanged = false}) async {
    selections.add(noteId);
  }
}
