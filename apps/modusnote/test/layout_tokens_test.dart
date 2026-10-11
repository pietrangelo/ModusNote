import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Widgets take sizes only from the golden-ratio tokens in lib/theme: a
/// number typed straight into a padding, gap, radius or font size is the
/// first step off the scale, so it is refused here.
void main() {
  final sizing = RegExp(
    r'(EdgeInsets\.\w+\([^)]*?\b\d'
    r'|SizedBox\([^)]*?\b(width|height):\s*\d'
    r'|Radius\.circular\(\s*\d'
    r'|BorderRadius\.circular\(\s*\d'
    r'|\b(fontSize|iconSize|size|spacing|runSpacing|elevation):\s*\d)',
  );

  test('widgets never write a size by hand', () {
    final offenders = <String>[];
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.startsWith('lib/theme/'))
        .where((file) => !file.path.contains('/generated/'));
    for (final file in sources) {
      final lines = file.readAsLinesSync();
      for (final (index, line) in lines.indexed) {
        if (sizing.hasMatch(line)) offenders.add('${file.path}:${index + 1}');
      }
    }

    expect(offenders, isEmpty);
  });
}
