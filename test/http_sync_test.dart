import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/sync/sync_controller.dart';
import 'package:noter/sync/sync_crypto.dart';
import 'package:noter/ui/noter_theme.dart';
import 'package:noter/ui/sync_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-http-');
    repository = LocalNotebookRepository(directory);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'HTTP consent survives configuration reload and can be revoked without deleting credentials',
    () async {
      final storage = const FlutterSecureStorage();
      final key = await SyncCrypto.generateRecoveryKey();
      final crypto = await SyncCrypto.create(key, 'http-test');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.headers.value('authorization'), 'Bearer ${'a' * 64}');
        if (request.uri.path == '/api/v1/session') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'version': 1,
              'account': 'http-test',
              'key_check': crypto.keyCheck,
            }),
          );
        } else if (request.uri.path == '/api/v1/key-check') {
          final body = await utf8.decoder.bind(request).join();
          expect(jsonDecode(body)['value'], crypto.keyCheck);
          expect(body, isNot(contains(key)));
          request.response.statusCode = 204;
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final controller = SyncController(repository, storage: storage);
      try {
        await HttpOverrides.runWithHttpOverrides(
          () => controller.connect(
            'http://127.0.0.1:${server.port}',
            'a' * 64,
            key,
            allowHttp: true,
          ),
          _RealNetwork(),
        );
        expect(controller.error, isNull);
        expect(controller.enabled, true);
        expect(controller.usesHttp, true);
        expect(requests, 2);
        final file = File('${directory.path}/.server-sync.json');
        final config =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(config['allowInsecureHttp'], true);
        expect(config.toString(), isNot(contains(key)));
        final secret =
            jsonDecode((await storage.read(key: 'noter.sync.credentials'))!)
                as Map<String, dynamic>;
        // Simulate a previously confirmed LAN origin; loading must not contact it.
        config['server'] = 'http://sync.example.org:5150';
        secret['server'] = config['server'];
        config['automatic'] = true;
        await file.writeAsString(jsonEncode(config));
        await storage.write(
          key: 'noter.sync.credentials',
          value: jsonEncode(secret),
        );
        final reopened = SyncController(repository, storage: storage);
        await reopened.load();
        expect(reopened.enabled, true);
        expect(reopened.allowInsecureHttp, true);
        expect(reopened.automatic, true);
        expect(requests, 2);
        await reopened.disableHttp();
        expect(reopened.enabled, false);
        expect(reopened.allowInsecureHttp, false);
        expect(reopened.automatic, false);
        expect(await storage.read(key: 'noter.sync.credentials'), isNotNull);
        final disabled =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(disabled['allowInsecureHttp'], false);
        expect(disabled['enabled'], false);
        await reopened.synchronize();
        expect(reopened.error, isNotNull);
        expect(requests, 2);
        reopened.dispose();
        // An old or edited config cannot silently grant remote HTTP permission.
        config.remove('allowInsecureHttp');
        await file.writeAsString(jsonEncode(config));
        final legacy = SyncController(repository, storage: storage);
        await legacy.load();
        expect(legacy.enabled, false);
        legacy.dispose();
      } finally {
        controller.dispose();
        await server.close(force: true);
      }
    },
  );

  test(
    'connecting to a different HTTP origin never inherits saved consent',
    () async {
      final controller = SyncController(repository);
      controller.allowInsecureHttp = true;
      await controller.connect('http://192.0.2.1:5150', 'a' * 64, 'not-a-key');
      expect(controller.enabled, false);
      expect(controller.error, contains('explicitly allow HTTP'));
      controller.dispose();
    },
  );

  testWidgets(
    'HTTP warning requires confirmation and address changes reset form consent',
    (tester) async {
      final controller = _FormController(repository);
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: SyncPage(controller: controller),
        ),
      );
      final address = find.widgetWithText(TextField, 'Server address');
      await tester.ensureVisible(address);
      await tester.enterText(address, 'http://192.168.1.20:5150');
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Allow HTTP for this new connection',
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('192.168.1.20', findRichText: true),
        findsWidgets,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow HTTP anyway'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      await tester.ensureVisible(address);
      await tester.enterText(address, 'http://192.168.1.21:5150');
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow HTTP anyway'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Connect to server'));
      await tester.tap(find.text('Connect to server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Safely saved'));
      await tester.pumpAndSettle();
      expect(controller.confirmedHttp, true);
      expect(controller.connectedUrl, 'http://192.168.1.21:5150');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'active HTTP warning and disable action fit a phone with large text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = _FormController(repository)
        ..enabled = true
        ..allowInsecureHttp = true
        ..automatic = true
        ..serverUrl = 'http://192.168.1.20:5150';
      await tester.pumpWidget(
        MaterialApp(
          theme: NoterTheme.light,
          home: SyncPage(controller: controller),
        ),
      );
      final disable = find.text('Disable HTTP connection');
      await tester.scrollUntilVisible(
        disable,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(disable);
      await tester.pumpAndSettle();
      expect(controller.usesHttp, false);
      expect(controller.automatic, false);
      expect(find.text('HTTP active – connection without TLS'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

class _RealNetwork extends HttpOverrides {}

class _FormController extends SyncController {
  _FormController(super.repository);
  bool? confirmedHttp;
  String? connectedUrl;
  @override
  Future<void> connect(
    String url,
    String token,
    String recoveryKey, {
    bool allowHttp = false,
  }) async {
    confirmedHttp = allowHttp;
    connectedUrl = url;
  }

  @override
  Future<void> disableHttp() async {
    enabled = false;
    automatic = false;
    allowInsecureHttp = false;
    notifyListeners();
  }
}
