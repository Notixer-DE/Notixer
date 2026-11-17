import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';

void main() {
  test('pen preset imports reject non-finite styles and invalid colors', () {
    final valid = const PenPreset('Writing', 'ink', 0xff123456, 2, 1).toJson();
    for (final changes in [
      {'width': double.nan},
      {'width': double.infinity},
      {'opacity': double.nan},
      {'opacity': double.infinity},
      {'color': -1},
      {'color': 0x100000000},
      {'name': ' '},
    ]) {
      expect(
        () => PenPreset.fromJson({...valid, ...changes}),
        throwsFormatException,
      );
    }
    expect(PenPreset.fromJson(valid).name, 'Writing');
  });
}
