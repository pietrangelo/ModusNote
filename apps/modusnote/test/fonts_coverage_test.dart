import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/modus_theme.dart';

/// The code points a TrueType font maps, from its cmap table (formats 4
/// and 12, the ones our fonts use).
Set<int> codePointsOf(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    if (ascii.decode(bytes.sublist(record, record + 4)) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  expect(cmap, isNonNegative, reason: '$path has no cmap');
  final points = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = cmap + data.getUint32(cmap + 4 + i * 8 + 4);
    switch (data.getUint16(offset)) {
      case 4:
        final segments = data.getUint16(offset + 6) ~/ 2;
        final ends = offset + 14;
        final starts = ends + segments * 2 + 2;
        for (var s = 0; s < segments; s++) {
          final end = data.getUint16(ends + s * 2);
          final start = data.getUint16(starts + s * 2);
          if (start == 0xFFFF) continue;
          for (var c = start; c <= end; c++) {
            points.add(c);
          }
        }
      case 12:
        final groups = data.getUint32(offset + 12);
        for (var g = 0; g < groups; g++) {
          final group = offset + 16 + g * 12;
          for (
            var c = data.getUint32(group);
            c <= data.getUint32(group + 4);
            c++
          ) {
            points.add(c);
          }
        }
    }
  }
  return points;
}

void main() {
  test('every text style falls back to the bundled symbol font', () {
    final text = ModusTheme.dark().textTheme;
    for (final style in [
      text.displayLarge!,
      text.headlineMedium!,
      text.bodyLarge!,
      text.labelSmall!,
    ]) {
      expect(style.fontFamilyFallback, [ModusTheme.symbolFont]);
    }
  });

  // A character none of our fonts has makes Flutter on the web fetch a
  // Noto font from Google: the CSP blocks it (and it would tell Google
  // what the user reads), so the glyph would show as a box instead.
  test('the bundled fonts draw every character of the translations', () {
    final covered = {
      ...codePointsOf('assets/fonts/Inter-Variable.ttf'),
      ...codePointsOf('assets/fonts/PlusJakartaSans-Variable.ttf'),
      ...codePointsOf('assets/fonts/NotoSansSymbols-Music.ttf'),
    };
    final missing = <String>{};
    for (final arb in Directory('lib/l10n').listSync().whereType<File>()) {
      if (!arb.path.endsWith('.arb')) continue;
      final messages = jsonDecode(arb.readAsStringSync()) as Map;
      messages.forEach((key, value) {
        if (key.toString().startsWith('@') || value is! String) return;
        for (final rune in value.runes) {
          if (rune >= 0x20 && !covered.contains(rune)) {
            missing.add('U+${rune.toRadixString(16)} in $key');
          }
        }
      });
    }
    expect(missing, isEmpty);
  });

  test('the symbol font is declared in the pubspec with its licence', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('family: ${ModusTheme.symbolFont}'));
    expect(pubspec, contains('assets/fonts/NotoSansSymbols-Music.ttf'));
    expect(File('assets/fonts/NotoSansSymbols-OFL.txt').existsSync(), isTrue);
  });
}
