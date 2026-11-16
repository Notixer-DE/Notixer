import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/sync/notebook_sync.dart';
import 'package:noter/sync/server_remote.dart';
import 'package:noter/sync/sync_crypto.dart';

// Only this opt-in integration test bypasses Flutter's default mock HTTP
// override. Unit/widget tests retain their normal isolated networking.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Platform.environment['NOTER_TEST_SERVER'];
  test(
    'Two real devices sync E2EE through Loco and PostgreSQL',
    () async {
      final root = await Directory.systemTemp.createTemp('noter-live-');
      final key = await SyncCrypto.generateRecoveryKey();
      final account = Platform.environment['NOTER_TEST_ACCOUNT']!;
      final a = LocalNotebookRepository(Directory('${root.path}/a'));
      final b = LocalNotebookRepository(Directory('${root.path}/b'));
      final crypto = await SyncCrypto.create(key, account);
      ServerRemote remote(String device, String token) => ServerRemote(
        server: Uri.parse(url!),
        token: token,
        crypto: crypto,
        client: IOClient(_RealNetwork().createHttpClient(null)),
        cache: Directory('${root.path}/cache-$device'),
      );
      final ra = remote('a', Platform.environment['NOTER_TEST_TOKEN_A']!);
      final rb = remote('b', Platform.environment['NOTER_TEST_TOKEN_B']!);
      try {
        await ra.verifyKey();
        await rb.verifyKey();
        var note = await a.create(
          'E2EE secret title',
          await createPaper('grid'),
        );
        await NotebookSync(a, ra).run();
        await NotebookSync(b, rb).run();
        expect((await b.list()).single.title, note.title);
        final other = (await b.list()).single;
        note = await a.save(
          note.copy(title: 'Tablet secret'),
          await a.load(note.id),
        );
        await b.save(
          other.copy(title: 'Laptop secret'),
          await b.load(other.id),
        );
        await NotebookSync(a, ra).run();
        final report = await NotebookSync(b, rb).run();
        expect(report.conflicts, 1);
        await NotebookSync(a, ra).run();
        expect((await a.list()).length, 2);
        expect((await b.list()).length, 2);
        await a.delete(note.id);
        await NotebookSync(a, ra).run();
        await NotebookSync(b, rb).run();
        expect((await b.list()).length, 1);
      } finally {
        ra.close();
        rb.close();
        await root.delete(recursive: true);
      }
    },
    skip: url == null
        ? 'Run tools/test-sync-server.py with FLUTTER_BIN'
        : false,
  );
}
