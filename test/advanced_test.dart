import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'advanced_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Noter 1.1 document, organization, lasso and export scenarios',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'noter-advanced-',
      );
      try {
        await verifyAdvanced(directory);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
