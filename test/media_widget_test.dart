import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/ui/document_workspace.dart';
import 'package:noter/ui/workspace_navigation.dart';
import 'package:noter/ui/media_page.dart';
import 'package:noter/ui/noter_theme.dart';
import 'media_test.dart' show samplePng;
import 'widget_test.dart' show settleFileIo;

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
          home: DocumentWorkspace(
            key: key,
            repository: repo,
            initialArea: WorkspaceArea.files,
          ),
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
      expect(find.byTooltip('File menu'), findsOneWidget);
      if (width == 390) {
        await tester.runAsync(() async {
          await repo.save(note.copy(title: 'Camera: photo.PNG'), samplePng);
          await FileGateway.refreshOpenDocuments!();
        });
        await tester.pump();
        expect(find.text('Camera: photo.PNG'), findsNWidgets(2));
        const picker = MethodChannel('plugins.flutter.io/file_selector');
        final messenger = tester.binding.defaultBinaryMessenger;
        final destination = File('${directory.path}/photo.png');
        messenger.setMockMethodCallHandler(picker, (call) async {
          expect(call.method, 'getSavePath');
          expect(call.arguments['suggestedName'], 'Camera_ photo.PNG');
          return destination.path;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
        await tester.tap(find.byTooltip('File menu'));
        await tester.pumpAndSettle();
        expect(find.text('Folders and tags'), findsOneWidget);
        await tester.tap(find.text('Save file to device'));
        await settleFileIo(tester, destination.existsSync);
        expect(await tester.runAsync(destination.readAsBytes), samplePng);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repo.flush();
        await directory.delete(recursive: true);
      });
    });
  }
}
