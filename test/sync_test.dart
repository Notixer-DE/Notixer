import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'sync_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Two-way sync, conflicts, deletion, retry, corruption and racing edits',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'noter-sync-test-',
      );
      try {
        await verifySync(directory);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
