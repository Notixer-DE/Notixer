import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/document_task.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/linked_tasks.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/quick_todos.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/workspace_navigation.dart';

Future<void> _waitForIo(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (ready() &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Markdown file operation did not finish.');
}

Future<String> _waitForPersistedSource(
  WidgetTester tester,
  LocalNotebookRepository repository,
  String noteId,
  String expectedSubstring,
) async {
  // Read the disk snapshot independently of the editor's pending writes so
  // the widget test can keep pumping while the editor's write queue drains.
  final reader = LocalNotebookRepository(repository.directory);
  var latest = '';
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final bytes = await tester.runAsync(() => reader.load(noteId));
    if (bytes != null) {
      latest = MarkdownDocument.decode(bytes).source;
      if (latest.contains(expectedSubstring)) {
        return latest;
      }
    }
  }
  fail(
    'Persisted source for $noteId did not contain "$expectedSubstring". Latest: $latest',
  );
}

void main() {
  group('document_task linked helpers', () {
    test(
      'preserves linkId across check, uncheck, and timer updates without leaking timer metadata into copies',
      () {
        final now = DateTime.utc(2026, 11, 24, 10);
        const raw = '- [ ] Buy milk\r\n- [x] Send report\r\n';
        final offsets = markdownTaskOffsets(raw);

        var source = updateDocumentTask(
          raw,
          offsets.first,
          timer: TodoTimerAction.start,
          now: now,
        );
        var nextId = 1;
        final copied = copyLinkedDocumentTask(
          source,
          offsets.first,
          generateId: () => 'link-${nextId++}',
        );
        expect(copied.linkId, 'link-1');
        expect(
          documentTaskLinkId(
            copied.source,
            markdownTaskOffsets(copied.source).first,
          ),
          'link-1',
        );
        expect(
          copied.clipboard,
          startsWith('- [ ] Buy milk <!-- notixer-task '),
        );
        expect(
          documentTask(
            copied.clipboard,
            markdownTaskOffsets(copied.clipboard).single,
            'Buy milk',
            fallback: now,
          ).timerStartedAt,
          isNull,
        );
        expect(
          documentTaskLinkId(
            copied.clipboard,
            markdownTaskOffsets(copied.clipboard).single,
          ),
          'link-1',
        );

        // Checking and unchecking preserves linkId even when no timer exists.
        final checked = updateDocumentTask(
          copied.source,
          markdownTaskOffsets(copied.source).first,
          done: true,
          now: now.add(const Duration(minutes: 5)),
        );
        expect(
          documentTaskLinkId(checked, markdownTaskOffsets(checked).first),
          'link-1',
        );
        final unchecked = updateDocumentTask(
          checked,
          markdownTaskOffsets(checked).first,
          done: false,
          now: now.add(const Duration(minutes: 6)),
        );
        expect(
          documentTaskLinkId(unchecked, markdownTaskOffsets(unchecked).first),
          'link-1',
        );
        expect(unchecked.split('\r\n').length, 3);
      },
    );

    test(
      'copyLinkedMarkdownSelection links task lines and ignores plain text or code blocks',
      () {
        const source =
            'Plain text\r\n'
            '- [ ] First task\r\n'
            '\r\n'
            '```\r\n'
            '- [ ] Code task\r\n'
            '```\r\n'
            '- [x] Second task\r\n';
        var seq = 1;

        final plain = copyLinkedMarkdownSelection(
          source,
          0,
          10,
          generateId: () => 'id-${seq++}',
        );
        expect(plain.linked, isFalse);
        expect(plain.source, source);
        expect(plain.clipboard, 'Plain text');

        final codeStart = source.indexOf('- [ ] Code task');
        final code = copyLinkedMarkdownSelection(
          source,
          codeStart,
          codeStart + '- [ ] Code task'.length,
          generateId: () => 'id-${seq++}',
        );
        expect(code.linked, isFalse);
        expect(code.source, source);

        final firstStart = source.indexOf('- [ ] First task');
        final secondEnd =
            source.indexOf('- [x] Second task') + '- [x] Second task'.length;
        final multi = copyLinkedMarkdownSelection(
          source,
          firstStart,
          secondEnd,
          generateId: () => 'id-${seq++}',
        );
        expect(multi.linked, isTrue);
        expect(seq, 3);
        expect(
          linkedDocumentTasks(multi.source).map((t) => (t.text, t.linkId)),
          [('First task', 'id-1'), ('Second task', 'id-2')],
        );
        expect(
          linkedDocumentTasks(
            multi.clipboard,
          ).map((t) => (t.text, t.done, t.linkId)),
          [('First task', false, 'id-1'), ('Second task', true, 'id-2')],
        );
        expect(multi.clipboard, contains('\r\n'));
        expect(multi.selectionStart, firstStart);
        expect(multi.selectionEnd, lessThanOrEqualTo(multi.source.length));
        // Copying again reuses existing linkIds without changing source.
        final repeat = copyLinkedMarkdownSelection(
          multi.source,
          multi.selectionStart,
          multi.selectionEnd,
          generateId: () => 'id-${seq++}',
        );
        expect(repeat.linked, isTrue);
        expect(repeat.source, multi.source);
        expect(seq, 3);
      },
    );
  });

  group('cross-note lookup and sync', () {
    late Directory directory;
    late LocalNotebookRepository repository;
    late MarkdownLibrary library;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('noter-linked-tasks-');
      repository = LocalNotebookRepository(directory);
      library = MarkdownLibrary(repository);
    });

    tearDown(() async {
      FileGateway.syncLinkedTask = null;
      await directory.delete(recursive: true);
    });

    test(
      'syncLinkedTaskStatus synchronizes completion and reopening across multiple notes',
      () async {
        final noteA = await library.create('Alpha');
        final noteB = await library.create('Beta');
        final noteC = await library.create('Gamma');

        final copied = copyLinkedDocumentTask(
          '- [ ] Write tests\n',
          3,
          generateId: () => 'shared-1',
        );
        await repository.save(noteA, MarkdownDocument(copied.source).encode());
        await repository.save(
          noteB,
          MarkdownDocument('# Beta\n\n${copied.clipboard}\n').encode(),
        );
        await repository.save(
          noteC,
          MarkdownDocument('# Gamma\n\n${copied.clipboard}\n').encode(),
        );

        final groupsInB = await findLinkedTaskGroups(
          repository,
          noteB,
          '# Beta\n\n${copied.clipboard}\n',
        );
        expect(groupsInB, hasLength(1));
        expect(
          groupsInB.single.others.map((o) => (o.note.title, o.line, o.anchor)),
          [('Alpha', 1, 'line=1'), ('Gamma', 3, 'line=3')],
        );

        // Closing in B closes A and C.
        await syncLinkedTaskStatus(
          repository,
          'shared-1',
          done: true,
          excludeNoteId: noteB.id,
        );
        expect(
          MarkdownDocument.decode(await repository.load(noteA.id)).source,
          contains('- [x] Write tests'),
        );
        expect(
          MarkdownDocument.decode(await repository.load(noteC.id)).source,
          contains('- [x] Write tests'),
        );

        // Reopening in A reopens B and C.
        await syncLinkedTaskStatus(
          repository,
          'shared-1',
          done: false,
          excludeNoteId: noteA.id,
        );
        expect(
          MarkdownDocument.decode(await repository.load(noteC.id)).source,
          contains('- [ ] Write tests'),
        );
      },
    );

    test(
      'KnowledgeStore.changeTask propagates linked task state across notes',
      () async {
        final noteA = await library.create('Origin');
        final noteB = await library.create('Target');
        final copied = copyLinkedDocumentTask(
          '- [ ] Call vendor\n',
          3,
          generateId: () => 'vendor-1',
        );
        await repository.save(noteA, MarkdownDocument(copied.source).encode());
        await repository.save(
          noteB,
          MarkdownDocument('${copied.clipboard}\n').encode(),
        );

        final store = KnowledgeStore(repository);
        final scan = await store.scan(const KnowledgeView('', openTasks: true));
        final taskInB = scan.tasks.singleWhere((t) => t.note.id == noteB.id);
        await store.changeTask(taskInB);

        expect(
          MarkdownDocument.decode(await repository.load(noteA.id)).source,
          contains('- [x] Call vendor'),
        );
        expect(
          MarkdownDocument.decode(await repository.load(noteB.id)).source,
          contains('- [x] Call vendor'),
        );
      },
    );
  });

  group('widget integration', () {
    late Directory directory;
    late LocalNotebookRepository repository;
    late MarkdownLibrary library;
    String? mockClipboard;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('noter-linked-ui-');
      repository = LocalNotebookRepository(directory);
      library = MarkdownLibrary(repository);
      mockClipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              mockClipboard = (call.arguments as Map)['text'] as String?;
              return null;
            }
            if (call.method == 'Clipboard.getData') {
              return mockClipboard == null
                  ? null
                  : <String, dynamic>{'text': mockClipboard};
            }
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      FileGateway.beforeClose = null;
      FileGateway.workspaceBeforeClose = null;
      FileGateway.openDocument = null;
      FileGateway.changeKnowledgeTask = null;
      FileGateway.refreshOpenDocuments = null;
      FileGateway.openMarkdownSources = null;
      FileGateway.syncLinkedTask = null;
      await directory.delete(recursive: true);
    });

    testWidgets(
      'read-mode copy links tasks, shows Linked to-dos in footer, opens target, and syncs open tabs bidirectionally',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final notes = await tester.runAsync(() async {
          final source = await library.create('Source note');
          final target = await library.create('Target note');
          await repository.save(
            source,
            MarkdownDocument('## Tasks\n\n- [ ] Shared errand\n').encode(),
          );
          await repository.save(
            target,
            MarkdownDocument('## Target heading\n\n').encode(),
          );
          return (source, target);
        });
        final (noteA, noteB) = notes!;

        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            home: DocumentWorkspace(
              repository: repository,
              initialArea: WorkspaceArea.files,
            ),
          ),
        );
        await _waitForIo(
          tester,
          () => find.text('Source note').evaluate().isNotEmpty,
        );

        // Open Source note and copy the task via the Read-mode copy button.
        await tester.tap(find.text('Source note'));
        await _waitForIo(
          tester,
          () => find
              .text('Shared errand', findRichText: true)
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.byTooltip('Copy linked to-do'));
        await tester.pumpAndSettle();
        expect(mockClipboard, isNotNull);
        expect(mockClipboard, contains('Shared errand'));
        expect(mockClipboard, contains('<!-- notixer-task '));
        expect(
          find.textContaining('notixer-task', findRichText: true),
          findsNothing,
        );

        // Open Target note, paste the copied task in Edit mode, switch to Read.
        await tester.tap(find.byTooltip('Open library and another note'));
        await _waitForIo(
          tester,
          () => find.text('Target note').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Target note'));
        await _waitForIo(
          tester,
          () => find
              .text('Target heading', findRichText: true)
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        final sourceField = find.byKey(const ValueKey('markdown-source'));
        await tester.enterText(
          sourceField,
          '## Target heading\n\n$mockClipboard\n',
        );
        await tester.tap(find.text('Read'));
        await _waitForIo(
          tester,
          () => find.text('Linked to-dos').evaluate().isNotEmpty,
        );

        // Verify footer lists Source note with line number.
        expect(find.text('Linked to-dos'), findsOneWidget);
        expect(find.text('Source note · Line 3'), findsOneWidget);

        // Toggle checkbox in Target note -> closes Source note tab & disk too.
        await tester.tap(find.byType(Checkbox).last);
        final savedASource = await _waitForPersistedSource(
          tester,
          repository,
          noteA.id,
          '- [x] Shared errand',
        );
        expect(savedASource, contains('- [x] Shared errand'));
        await _waitForPersistedSource(
          tester,
          repository,
          noteB.id,
          '- [x] Shared errand',
        );

        // Tap footer link to jump to Source note, verify checked, then uncheck.
        await tester.ensureVisible(find.text('Source note · Line 3'));
        await tester.tap(find.text('Source note · Line 3'));
        await _waitForIo(
          tester,
          () => find.text('Target note · Line 3').evaluate().isNotEmpty,
        );
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox).first).value,
          isTrue,
        );
        await tester.tap(find.byType(Checkbox).first);
        final savedBSource = await _waitForPersistedSource(
          tester,
          repository,
          noteB.id,
          '- [ ] Shared errand',
        );
        expect(savedBSource, contains('- [ ] Shared errand'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Ctrl+C in Markdown Edit mode links task and syncs with pasted copy',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final notes = await tester.runAsync(() async {
          final source = await library.create('Edit source');
          final target = await library.create('Paste target');
          await repository.save(
            source,
            MarkdownDocument('- [ ] Keyboard copied\n').encode(),
          );
          return (source, target);
        });
        final (noteA, noteB) = notes!;

        final bytesA = await tester.runAsync(() => repository.load(noteA.id));
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            home: MarkdownEditorPage(
              key: ValueKey(noteA.id),
              note: noteA,
              bytes: bytesA!,
              repository: repository,
            ),
          ),
        );
        await _waitForIo(
          tester,
          () => find
              .text('Keyboard copied', findRichText: true)
              .evaluate()
              .isNotEmpty,
        );

        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('markdown-source'));
        await tester.tap(field);
        final controller = tester.widget<TextField>(field).controller!;
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: '- [ ] Keyboard copied'.length,
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(mockClipboard, contains('Keyboard copied'));
        expect(mockClipboard, contains('<!-- notixer-task '));
        expect(controller.text, contains('<!-- notixer-task '));

        bool? saved;
        FileGateway.beforeClose!().then((ok) => saved = ok);
        await _waitForIo(tester, () => saved != null);
        expect(saved, isTrue);
        final bytesB = await tester.runAsync(() async {
          await repository.save(
            noteB,
            MarkdownDocument('$mockClipboard\n').encode(),
          );
          return repository.load(noteB.id);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            home: MarkdownEditorPage(
              key: ValueKey(noteB.id),
              note: noteB,
              bytes: bytesB!,
              repository: repository,
            ),
          ),
        );
        await _waitForIo(
          tester,
          () => find.text('Edit source · Line 1').evaluate().isNotEmpty,
        );

        await tester.tap(find.byType(Checkbox).first);
        final persistedASource = await _waitForPersistedSource(
          tester,
          repository,
          noteA.id,
          '- [x] Keyboard copied',
        );
        expect(persistedASource, contains('- [x] Keyboard copied'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  });
}
