import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/modus_colors.dart';
import 'package:modusnote/theme/modus_palette.dart';
import 'package:modusnote/theme/modus_theme.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

void main() {
  group('the Modus palette', () {
    const palette = ModusPalette.modus;

    test('is the brand palette, role by role', () {
      expect(palette.brightness, Brightness.dark);
      expect(palette.background, ModusColors.deepVoid);
      expect(palette.surface, ModusColors.abyssalSlate);
      expect(palette.text, ModusColors.pureMist);
      expect(palette.muted, ModusColors.dustSilver);
      expect(palette.primary, ModusColors.aureoGold);
      expect(palette.gold, ModusColors.aureoGold);
      expect(palette.onAccent, ModusColors.deepVoid);
      expect(palette.violetFill, ModusColors.rhythmViolet);
      expect(palette.violet, ModusColors.rhythmVioletText);
      expect(palette.success, ModusColors.cadenceCyan);
      expect(palette.rose, ModusColors.lucidRose);
      expect(palette.sage, ModusColors.freshSage);
    });

    test('gives each note tint its accent, silver for none', () {
      expect(palette.tint(NoteTint.gold), palette.gold);
      expect(palette.tint(NoteTint.violet), palette.violet);
      expect(palette.tint(NoteTint.cyan), palette.success);
      expect(palette.tint(NoteTint.rose), palette.rose);
      expect(palette.tint(NoteTint.sage), palette.sage);
      expect(palette.tint(NoteTint.silver), palette.muted);
      expect(palette.tint(null), palette.muted);
    });

    test('washes a card with its tint at 1/φ⁴ over the surface', () {
      for (final tint in [...NoteTint.values, null]) {
        expect(
          palette.wash(tint),
          Color.alphaBlend(
            palette.tint(tint).withValues(alpha: ModusPalette.washStrength),
            palette.surface,
          ),
        );
      }
      expect(ModusPalette.washStrength, closeTo(0.1459, 1e-4));
    });

    test('is what the theme carries, and what widgets read', () {
      final theme = ModusTheme.dark();
      expect(theme.extension<ModusPalette>(), same(ModusPalette.modus));
      expect(theme.scaffoldBackgroundColor, palette.background);
      expect(theme.colorScheme.surface, palette.surface);
      expect(theme.colorScheme.primary, palette.primary);
      expect(theme.colorScheme.onSurfaceVariant, palette.muted);
    });

    testWidgets('of(context) finds the palette of the nearest theme', (
      tester,
    ) async {
      late ModusPalette found;
      await tester.pumpWidget(
        MaterialApp(
          theme: ModusTheme.dark(),
          home: Builder(
            builder: (context) {
              found = ModusPalette.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(found, same(ModusPalette.modus));
    });
  });

  test('outside lib/theme no widget names a colour by hand', () {
    // A theme can only change what widgets read from it: a brand colour
    // or a literal written in a widget would stay the same in every theme.
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.startsWith('lib/theme/')) continue;
      if (file.path.startsWith('lib/l10n/')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'ModusColors\.|Color\(0x|Colors\.').hasMatch(lines[i]) &&
            !lines[i].contains('Colors.transparent')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
