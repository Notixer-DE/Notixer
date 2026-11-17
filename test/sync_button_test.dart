import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/sync_button.dart';

class _SyncController extends SyncController {
  _SyncController(super.repository);

  int calls = 0;
  Completer<void>? pending;

  @override
  Future<void> synchronize({String? noteId, bool onlyIfChanged = false}) async {
    calls++;
    busy = true;
    error = null;
    pending = Completer<void>();
    notifyListeners();
    await pending!.future;
    busy = false;
    if (error == null) lastSyncedAt = DateTime.now();
    notifyListeners();
  }
}

void main() {
  late Directory directory;
  late _SyncController controller;
  var refreshes = 0;
  var detailsOpened = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-sync-button-');
    controller = _SyncController(LocalNotebookRepository(directory));
    refreshes = 0;
    detailsOpened = 0;
  });

  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> showButton(WidgetTester tester, {bool disabled = false}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Noter'),
              actions: [
                SyncButton(
                  controller: controller,
                  disabled: disabled,
                  onSynchronized: () async => refreshes++,
                  onOpenDetails: () => detailsOpened++,
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('only appears once sync is configured', (tester) async {
    await showButton(tester);
    expect(find.byType(IconButton), findsNothing);
    controller.enabled = true;
    controller.notifyListeners();
    await tester.pump();
    expect(find.byTooltip('Sync now'), findsOneWidget);
    controller.enabled = false;
    controller.notifyListeners();
    await tester.pump();
    expect(find.byType(IconButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'syncs once, shows progress and success, and refreshes the library',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.enabled = true;
      await showButton(tester);
      final button = find.byType(IconButton);
      // Even before the next rebuild the controller lock prevents a second call.
      await tester.tap(button);
      await tester.tap(button);
      expect(controller.calls, 1);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      controller.pending!.complete();
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
      expect(find.text('Sync completed successfully.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('errors offer sync details and allow retry', (tester) async {
    controller.enabled = true;
    await showButton(tester);
    await tester.tap(find.byTooltip('Sync now'));
    controller.error =
        'Server nicht erreichbar. Lokale Notes bleiben erhalten.';
    controller.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
    expect(find.text(controller.error!), findsOneWidget);
    await tester.tap(find.text('Sync details'));
    await tester.pumpAndSettle();
    expect(detailsOpened, 1);
    await tester.tap(find.byType(IconButton));
    expect(controller.calls, 2);
    controller.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reflects sync started elsewhere and respects library lock', (
    tester,
  ) async {
    controller.enabled = true;
    await showButton(tester, disabled: true);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await showButton(tester);
    final sync = controller.synchronize();
    await tester.pump();
    expect(find.byTooltip('Sync in progress'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    controller.pending!.complete();
    await sync;
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(refreshes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('can be removed while a sync is running', (tester) async {
    controller.enabled = true;
    await showButton(tester);
    await tester.tap(find.byType(IconButton));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.pending!.complete();
    await tester.pump();
    expect(refreshes, 0);
    expect(tester.takeException(), isNull);
  });
}
