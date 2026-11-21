import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfEditTool;
import 'dart:io';
import 'dart:async';
import 'package:noter/ui/library.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/knowledge.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/workspace_navigation.dart';
import 'package:noter/ui/document_tab.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';

class _DelayedLibraryRepository extends LocalNotebookRepository {
  _DelayedLibraryRepository(super.directory);
  final pending = Completer<List<Notebook>>();
  bool requested = false;
  @override
  Future<List<Notebook>> list() {
    requested = true;
    return pending.future;
  }
}

void main() {
  testWidgets(
    'disposing the library during startup never starts a late UI action',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('noter-late-library-'),
      );
      final repo = _DelayedLibraryRepository(directory!);
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      for (var i = 0; i < 100 && !repo.requested; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(repo.requested, isTrue);
      await tester.pumpWidget(const SizedBox());
      repo.pending.complete([]);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'tabs preserve PDF zoom, unfinished ink and Markdown state at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = (await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'noter-tabs-',
          );
          final repo = LocalNotebookRepository(directory);
          final pdf = await repo.create(
            'PDF A',
            await createPaper('blank', pages: 3),
          );
          final other = await repo.create(
            'PDF B',
            await createPaper('grid', pages: 3),
          );
          final text = await MarkdownLibrary(repo).create('Text C');
          return (directory, repo, pdf, other, text);
        }))!;
        final (directory, repo, a, b, c) = fixture;
        final key = GlobalKey<DocumentWorkspaceState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            home: DocumentWorkspace(
              key: key,
              repository: repo,
              initialArea: WorkspaceArea.files,
            ),
          ),
        );
        Future<void> io([bool Function()? done]) async {
          for (var i = 0; i < 250; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            await tester.pump(const Duration(milliseconds: 16));
            if (done?.call() ?? i > 20) break;
          }
        }

        Future<void> open(Notebook note, {String? anchor}) async {
          var finished = false;
          key.currentState!
              .openNotebook(note, anchor: anchor)
              .then((_) => finished = true);
          await io(() => finished);
          await io();
        }

        await io();
        await open(a);
        final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
        expect(pane.widget.session.toolsReady, isTrue);
        expect(
          tester.widget<EditorPage>(find.byType(EditorPage)).workspaceSessions,
          isNotNull,
        );
        pane.viewer.jumpToPage(1);
        await io();
        pane.viewer.setZoom(1.8);
        await io();
        final zoom = pane.viewer.zoom;
        final tabsBar = find.byKey(const ValueKey('document-tabs-bar'));
        expect(tester.getSize(tabsBar).height, 44);
        // The tab strip consumes the status inset once. The editor must start
        // immediately below it rather than reserving another empty status bar.
        final header = find.byType(AppBar);
        expect(
          tester.getSize(header).height,
          NoterTheme.headerHeight(tester.element(header)),
        );
        expect(tester.getTopLeft(header).dy, tester.getBottomLeft(tabsBar).dy);
        await tester.tap(find.byTooltip('Hide document tabs'));
        await tester.pump();
        expect(find.byKey(ValueKey('document-tab-${a.id}')), findsNothing);
        expect(find.byTooltip('Show document tabs'), findsOneWidget);
        final restorePosition = tester.getTopLeft(
          find.byTooltip('Show document tabs'),
        );
        expect(restorePosition.dx, lessThan(50));
        expect(restorePosition.dy, lessThan(80));
        expect(
          tester.getTopLeft(find.byTooltip('Back to library')).dx,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.state<EditorPaneState>(find.byType(EditorPane)),
          same(pane),
        );
        await tester.tap(find.byTooltip('Show document tabs'));
        await io();
        expect(find.byKey(ValueKey('document-tab-${a.id}')), findsOneWidget);
        expect(pane.viewer.zoom, closeTo(zoom, .001));

        expect(pane.editing.tool, isNull);
        await tester.tap(find.byKey(const ValueKey('pdf-mode-draw')));
        await io();
        expect(pane.editing.tool, PdfEditTool.ink);
        expect(pane.viewer.zoom, closeTo(zoom, .001));

        final bounds = pane.viewer.globalRectOf(
          1,
          pane.editing.document.page(1).cropBox,
        )!;
        final start = bounds.center;
        pane.handleCustomInput(
          PointerDownEvent(
            pointer: 91,
            kind: PointerDeviceKind.stylus,
            position: start,
          ),
        );
        pane.handleCustomInput(
          PointerMoveEvent(
            pointer: 91,
            kind: PointerDeviceKind.stylus,
            position: start + const Offset(30, 20),
          ),
        );
        // Changing tabs must commit an in-progress contact rather than cancel it.
        await open(b, anchor: 'page=2');
        final linkedPane = tester.state<EditorPaneState>(
          find.byType(EditorPane),
        );
        expect(linkedPane.viewer.currentPage, 1);
        linkedPane.viewer.setZoom(1.6);
        await io();
        final linkedZoom = linkedPane.viewer.zoom;
        await open(a);
        await open(b, anchor: 'page=3');
        expect(
          tester.state<EditorPaneState>(find.byType(EditorPane)),
          same(linkedPane),
        );
        expect(linkedPane.viewer.currentPage, 2);
        expect(linkedPane.viewer.zoom, closeTo(linkedZoom, .001));
        expect(pane.widget.session.ink.index.strokes, isNotEmpty);
        expect(key.currentState!.openNotebookIds, [a.id, b.id]);
        await open(a);
        expect(
          tester.state<EditorPaneState>(find.byType(EditorPane)),
          same(pane),
        );
        expect(pane.viewer.currentPage, 1);
        expect(pane.viewer.zoom, closeTo(zoom, .001));
        await open(c);
        expect(find.byType(MarkdownEditorPage), findsOneWidget);
        final source = find.byKey(
          const ValueKey('markdown-source'),
          skipOffstage: false,
        );
        await tester.enterText(
          source,
          '# Ungespeichert\n\nInhalt bleibt im Tab.',
        );
        await tester.pump();
        final sourceWidget = tester.widget<TextField>(source);
        final controller = sourceWidget.controller!;
        await open(a);
        await open(c, anchor: 'ungespeichert');
        expect(find.text('Ungespeichert'), findsOneWidget);
        expect(tester.widget<TextField>(source).controller, same(controller));
        expect(controller.text, contains('Ungespeichert'));
        // Completing a task from the hub must update the mounted editor too.
        controller.text += '\n- [ ] A task in an open tab';
        final taskOffset = controller.text.lastIndexOf('[ ]') + 1;
        final task = KnowledgeTask(
          c,
          taskOffset,
          5,
          'A task in an open tab',
          markdownRevision(controller.text),
        );
        var taskSaved = false;
        FileGateway.changeKnowledgeTask!(task).then((_) => taskSaved = true);
        await io(() => taskSaved);
        expect(taskSaved, isTrue);
        expect(controller.text, contains('- [x] A task in an open tab'));
        // Closing an inactive PDF must not dispose the active Markdown editor.
        var closed = false;
        key.currentState!.closeNotebook(b.id).then((value) => closed = value);
        await io(() => closed);
        expect(closed, isTrue);
        expect(key.currentState!.activeNotebookId, c.id);
        expect(controller.text, contains('Ungespeichert'));
        var saved = false;
        FileGateway.prepareClose().then((value) => saved = value);
        await io(() => saved);
        expect(saved, isTrue);
        final persisted = await tester.runAsync(
          () async => MarkdownDocument.decode(await repo.load(c.id)),
        );
        expect(persisted!.source, contains('Ungespeichert'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(FileGateway.workspaceBeforeClose, isNull);
        await tester.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
  testWidgets(
    'a failed save keeps the tab open and cancels application close',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'noter-tab-failure-',
        );
        final repo = LocalNotebookRepository(directory);
        final note = await repo.create(
          'Nicht verlieren',
          await createPaper('blank'),
        );
        return (directory, repo, note);
      }))!;
      final (directory, repo, note) = fixture;
      final key = GlobalKey<DocumentWorkspaceState>();
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentWorkspace(
            key: key,
            repository: repo,
            initialArea: WorkspaceArea.files,
          ),
        ),
      );
      var opened = false;
      key.currentState!.openNotebook(note).then((_) => opened = true);
      for (var i = 0; i < 100 && !opened; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pump();
      final tab = tester
          .widget<EditorPage>(find.byType(EditorPage))
          .tabController!;
      tab.attach(Object(), save: () async => false);
      expect(await key.currentState!.closeNotebook(note.id), isFalse);
      expect(key.currentState!.openNotebookIds, [note.id]);
      expect(await FileGateway.prepareClose(), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );

  test(
    'PDF sessions are shared and live until their last pane is released',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'noter-tab-pool-',
      );
      final repo = LocalNotebookRepository(directory);
      final bytes = await createPaper('blank');
      final note = await repo.create('Gemeinsam', bytes);
      final pool = WorkspacePdfSessions(repo);
      final first = pool.acquire(note, bytes),
          second = pool.acquire(note, bytes);
      expect(second, same(first));
      await first.ready;
      await first.toolReady;
      pool.release(first);
      expect(pool.contains(note.id), isTrue);
      expect(second.editing.document.pageCount, 1);
      pool.release(second);
      expect(pool.contains(note.id), isFalse);
      pool.dispose();
      await repo.flush();
      await directory.delete(recursive: true);
    },
  );
}
