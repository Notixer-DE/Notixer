import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'performance_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'large PDF metadata, background storage and deferred stylus autosave',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'noter-performance-test-',
      );
      try {
        await verifyPerformance(directory);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
