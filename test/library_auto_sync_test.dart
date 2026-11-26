import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/ui/library.dart';
import 'package:noter/ui/markdown_editor.dart';
import 'package:noter/ui/noter_theme.dart';

import 'markdown_widget_test.dart' show markdownIo;

class _RecordingSync extends SyncController {
  _RecordingSync(super.repository);
  final calls = <String?>[];

  @override
  Future<void> load() async {
    enabled = true;
    automatic = true;
  }

  @override
  Future<void> synchronize({
    String? noteId,
    bool onlyIfChanged = false,
  }) async => calls.add(noteId);
}

void main() {
  testWidgets('closing an editor syncs only saved changes, not viewed notes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('noter-library-sync-'),
    ))!;
    final repository = LocalNotebookRepository(root);
    final sync = _RecordingSync(repository);
    addTearDown(() async {
      FileGateway.beforeClose = null;
      sync.dispose();
      await root.delete(recursive: true);
    });
    final a = await tester.runAsync(
      () => MarkdownLibrary(repository).create('Edit this note'),
    );
    await tester.runAsync(
      () => MarkdownLibrary(repository).create('Leave this note alone'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NoterTheme.light,
        home: LibraryPage(repository: repository, syncController: sync),
      ),
    );
    await markdownIo(tester, () => sync.calls.isNotEmpty);
    expect(sync.calls, [null]); // Startup still performs a full sync.
    sync.calls.clear();

    Future<void> open() async {
      await tester.tap(find.text('Edit this note'));
      await markdownIo(
        tester,
        () => find.byType(MarkdownEditorPage).evaluate().isNotEmpty,
      );
    }

    Future<void> close() async {
      await tester.tap(find.byTooltip('Back to library'));
      await markdownIo(
        tester,
        () => find.byType(MarkdownEditorPage).evaluate().isEmpty,
      );
    }

    await open();
    await close();
    expect(sync.calls, isEmpty);

    await open();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('markdown-source')),
      '# Changed content',
    );
    await close();
    expect(sync.calls, [a!.id]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
