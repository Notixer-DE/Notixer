import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/media_page.dart';
import 'package:noter/ui/noter_theme.dart';
import 'media_test.dart' show samplePng;

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('media opens in a workspace tab and fits width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'notixer-media-ui-',
        );
        final repo = LocalNotebookRepository(directory);
        final note = await repo.create(
          'Camera photo',
          samplePng,
          paper: 'media:png',
        );
        return (directory, repo, note);
      }))!;
      final (directory, repo, note) = fixture;
      final key = GlobalKey<DocumentWorkspaceState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: DocumentWorkspace(key: key, repository: repo),
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('Camera photo').evaluate().isNotEmpty) break;
      }
      await tester.runAsync(() => key.currentState!.openNotebook(note));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(MediaPage).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MediaPage), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byTooltip('Organize file'), findsOneWidget);
      expect(find.byTooltip('Export media'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repo.flush();
        await directory.delete(recursive: true);
      });
    });
  }
}
