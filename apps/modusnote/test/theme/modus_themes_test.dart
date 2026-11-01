import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:modusnote/theme/modus_palette.dart';
import 'package:modusnote/theme/modus_theme.dart';
import 'package:modusnote/theme/modus_themes.dart';
import 'package:modusnote/theme/oklch.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../theme_test.dart' show contrast;

final moods = <NoteMood?>[null, ...NoteMood.values];

void main() {
  test('Modus for the app is the brand itself', () {
    expect(ModusThemes.palette(AppTheme.modus), same(ModusPalette.modus));
    expect(
      ModusThemes.palette(AppTheme.modus, NoteMood.concentration),
      same(ModusPalette.modus),
    );
  });

  test('Paper is light, the others dark', () {
    for (final mood in moods) {
      expect(
        ModusThemes.palette(AppTheme.paper, mood).brightness,
        Brightness.light,
      );
      expect(
        ModusThemes.palette(AppTheme.restful, mood).brightness,
        Brightness.dark,
      );
    }
    expect(
      ModusTheme.of(ModusThemes.palette(AppTheme.paper)).colorScheme.brightness,
      Brightness.light,
    );
  });

  test('each mood gives the page its own background', () {
    for (final theme in AppTheme.values) {
      final pages = {
        for (final mood in NoteMood.values)
          ModusThemes.palette(theme, mood).background,
      };
      expect(pages.length, greaterThanOrEqualTo(2), reason: '$theme');
    }
  });

  for (final theme in AppTheme.values) {
    for (final mood in moods) {
      final palette = ModusThemes.palette(theme, mood);
      final name = '${theme.name} ${mood?.name ?? 'app'}';

      test('$name: every text colour is AA on background and surface', () {
        for (final background in [palette.background, palette.surface]) {
          for (final text in [
            palette.text,
            palette.muted,
            palette.primary,
            palette.violet,
            palette.error,
            for (final tint in [...NoteTint.values, null]) palette.tint(tint),
          ]) {
            expect(
              contrast(text, background),
              greaterThanOrEqualTo(4.5),
              reason: '$text on $background',
            );
          }
        }
      });

      test('$name: text on the accents and on violet is AA', () {
        for (final fill in [
          palette.primary,
          palette.gold,
          palette.success,
          palette.rose,
          palette.sage,
        ]) {
          expect(
            contrast(palette.onAccent, fill),
            greaterThanOrEqualTo(4.5),
            reason: 'on $fill',
          );
        }
        expect(
          contrast(palette.onVioletFill, palette.violetFill),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('$name: a card washed by its type keeps text at AA', () {
        for (final tint in [...NoteTint.values, null]) {
          final card = palette.wash(tint);
          for (final text in [palette.text, palette.muted, palette.success]) {
            expect(
              contrast(text, card),
              greaterThanOrEqualTo(4.5),
              reason: '$text on the $tint card',
            );
          }
          expect(
            contrast(palette.tint(tint), card),
            greaterThanOrEqualTo(3),
            reason: 'icon on the $tint card',
          );
        }
      });
    }
  }

  group('restful by construction', () {
    for (final theme in [AppTheme.restful, AppTheme.paper]) {
      for (final mood in moods) {
        final palette = ModusThemes.palette(theme, mood);
        final name = '${theme.name} ${mood?.name ?? 'app'}';

        test('$name: text never reaches the glare of black on white', () {
          final ratio = contrast(palette.text, palette.background);
          // AAA for body text, and far from the brand's 18.7:1.
          expect(ratio, greaterThanOrEqualTo(7));
          expect(ratio, lessThanOrEqualTo(15));
          expect(palette.background, isNot(Colors.black));
          expect(palette.background, isNot(Colors.white));
        });

        test('$name: lightness steps are golden', () {
          final background = oklchLightness(palette.background);
          final surface = oklchLightness(palette.surface);
          final text = oklchLightness(palette.text);
          final muted = oklchLightness(palette.muted);
          const phi = GoldenRatio.phi;
          // Whole RGB channels leave about 0.005 of OKLCH lightness.
          if (palette.brightness == Brightness.dark) {
            expect(
              surface - background,
              closeTo(background / pow(phi, 4), 0.006),
            );
            expect(muted, closeTo(text / sqrt(phi), 0.006));
          } else {
            expect(
              surface - background,
              closeTo((1 - background) / phi, 0.006),
            );
            expect(muted, closeTo(text * phi, 0.006));
          }
          final accents = [
            palette.gold,
            palette.violet,
            palette.success,
            palette.rose,
            palette.sage,
          ].map(oklchLightness);
          for (final accent in accents) {
            expect(accent, closeTo(accents.first, 0.01));
          }
        });
      }
    }
  });

  test('OKLCH lightness round-trips through sRGB', () {
    expect(oklchLightness(oklch(0.5, 0, 0)), closeTo(0.5, 0.005));
    expect(oklchLightness(oklch(0.9, 0.02, 80)), closeTo(0.9, 0.005));
  });

  group('the mood of a note type', () {
    test('books, dreams, songs and the journal invite imagination', () {
      for (final schema in [
        SeedSchemas.bookV1,
        SeedSchemas.bookChapterV1,
        SeedSchemas.bookCharacterV1,
        SeedSchemas.bookPlaceV1,
        SeedSchemas.dreamLogV1,
        SeedSchemas.songSketchV1,
      ]) {
        expect(
          NoteMood.of(schema),
          NoteMood.imagination,
          reason: schema.id.name,
        );
      }
    });

    test('quick notes and documents ask for concentration', () {
      expect(NoteMood.of(SeedSchemas.quickNoteV1), NoteMood.concentration);
      expect(NoteMood.of(SeedSchemas.documentV1), NoteMood.concentration);
    });

    test('to-dos and credentials for order', () {
      expect(NoteMood.of(SeedSchemas.taskV2), NoteMood.order);
      expect(NoteMood.of(SeedSchemas.credentialV1), NoteMood.order);
    });

    test('an unknown type is for concentration', () {
      expect(NoteMood.of(null), NoteMood.concentration);
    });
  });
}
