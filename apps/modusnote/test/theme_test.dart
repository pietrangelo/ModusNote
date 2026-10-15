import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:modusnote/theme/modus_colors.dart';
import 'package:modusnote/theme/modus_theme.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:modusnote/theme/modus_palette.dart';

/// WCAG 2.x contrast ratio, computed independently of the theme.
double contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final (l1, l2) = (luminance(a), luminance(b));
  return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
}

bool onPhiScale(double value, double base) {
  final exponent = log(value / base) / log(GoldenRatio.phi);
  final nearest = base * pow(GoldenRatio.phi, exponent.roundToDouble());
  // Whole dp drift from 8·φⁿ: at most 1 dp, or 1 % on large extents.
  return (value - nearest).abs() <= max(1, nearest * 0.01);
}

void main() {
  group('GoldenRatio tokens', () {
    test('every spacing step is 8 dp times a power of φ', () {
      expect(Spacing.all, [3, 5, 8, 13, 21, 34, 55]);
      for (final value in Spacing.all) {
        expect(onPhiScale(value, 8), isTrue, reason: '$value');
      }
    });

    test('the type scale is 16 sp times a power of φ', () {
      expect(TypeScale.caption, 10);
      expect(TypeScale.body, 16);
      expect(TypeScale.title2, 26);
      expect(TypeScale.title1, 42);
      expect(TypeScale.display, 68);
      for (final size in TypeScale.all) {
        expect(onPhiScale(size, 16), isTrue, reason: '$size');
      }
    });

    test('content extents continue the same scale', () {
      expect(Extents.all, [89, 144, 233, 377, 610, 987, 1597]);
      for (final value in Extents.all) {
        expect(onPhiScale(value, 8), isTrue, reason: '$value');
      }
      expect(Extents.all.first, greaterThan(Spacing.all.last));
    });

    test('icons take their size from the spacing scale', () {
      expect(Spacing.all, contains(IconSizes.inline));
      expect(Spacing.all, contains(IconSizes.prominent));
    });

    test('layout splits are 61.8 % and 38.2 %', () {
      expect(LayoutSplit.primary + LayoutSplit.secondary, closeTo(1, 1e-9));
      expect(
        LayoutSplit.primary / LayoutSplit.secondary,
        closeTo(GoldenRatio.phi, 1e-9),
      );
    });

    test('corner radii come from the spacing scale', () {
      for (final radius in Radii.all) {
        expect(Spacing.all, contains(radius));
      }
    });
  });

  group('palette contrast (WCAG)', () {
    const backgrounds = [ModusColors.deepVoid, ModusColors.abyssalSlate];

    test('text colours reach AA (4.5:1) on both backgrounds', () {
      for (final background in backgrounds) {
        for (final text in [
          ModusColors.pureMist,
          ModusColors.dustSilver,
          ModusColors.aureoGold,
          ModusColors.cadenceCyan,
          ModusColors.rhythmVioletText,
          ModusColors.lucidRose,
        ]) {
          expect(
            contrast(text, background),
            greaterThanOrEqualTo(4.5),
            reason: '$text on $background',
          );
        }
      }
    });

    test('every note type tint is a safe text colour', () {
      for (final tint in [...NoteTint.values, null]) {
        for (final background in backgrounds) {
          expect(
            contrast(ModusPalette.modus.tint(tint), background),
            greaterThanOrEqualTo(4.5),
            reason: '$tint on $background',
          );
        }
      }
    });

    test('a card washed with its type\'s tint keeps its text at AA', () {
      for (final tint in [...NoteTint.values, null]) {
        final card = ModusPalette.modus.wash(tint);
        expect(card, isNot(ModusColors.abyssalSlate), reason: '$tint');
        // Title, label and date, progress, the done check.
        for (final text in [
          ModusColors.pureMist,
          ModusColors.dustSilver,
          ModusColors.cadenceCyan,
        ]) {
          expect(
            contrast(text, card),
            greaterThanOrEqualTo(4.5),
            reason: '$text on the $tint card',
          );
        }
        // The type icon is not text: 3:1 (WCAG 1.4.11).
        expect(
          contrast(ModusPalette.modus.tint(tint), card),
          greaterThanOrEqualTo(3),
          reason: 'icon on the $tint card',
        );
      }
    });

    test('Rhythm Violet itself is a fill colour: below AA as text', () {
      expect(
        contrast(ModusColors.rhythmViolet, ModusColors.abyssalSlate),
        lessThan(4.5),
      );
    });

    test('text on every accent fill reaches AA', () {
      final scheme = ModusTheme.dark().colorScheme;
      for (final (fill, on) in [
        (scheme.primary, scheme.onPrimary),
        (scheme.secondary, scheme.onSecondary),
        (scheme.tertiary, scheme.onTertiary),
        (scheme.surface, scheme.onSurface),
      ]) {
        expect(
          contrast(on, fill),
          greaterThanOrEqualTo(4.5),
          reason: '$on on $fill',
        );
      }
    });
  });

  group('ModusTheme', () {
    final theme = ModusTheme.dark();

    test('is a dark theme on Deep Void with Aureo Gold as primary', () {
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, ModusColors.deepVoid);
      expect(theme.colorScheme.primary, ModusColors.aureoGold);
      expect(theme.colorScheme.secondary, ModusColors.rhythmViolet);
      expect(theme.colorScheme.tertiary, ModusColors.cadenceCyan);
      expect(theme.colorScheme.surface, ModusColors.abyssalSlate);
    });

    test('titles use Plus Jakarta Sans and body text uses Inter', () {
      final text = theme.textTheme;

      expect(text.displayLarge!.fontFamily, ModusTheme.titleFont);
      expect(text.headlineLarge!.fontFamily, ModusTheme.titleFont);
      expect(text.bodyLarge!.fontFamily, ModusTheme.bodyFont);
      expect(text.labelSmall!.fontFamily, ModusTheme.bodyFont);
    });

    test('text sizes are exactly the golden type scale', () {
      final text = theme.textTheme;

      expect(text.displayLarge!.fontSize, TypeScale.display);
      expect(text.headlineLarge!.fontSize, TypeScale.title1);
      expect(text.headlineMedium!.fontSize, TypeScale.title2);
      expect(text.bodyLarge!.fontSize, TypeScale.body);
      expect(text.labelSmall!.fontSize, TypeScale.caption);
      for (final style in [
        text.displayLarge,
        text.displayMedium,
        text.displaySmall,
        text.headlineLarge,
        text.headlineMedium,
        text.headlineSmall,
        text.titleLarge,
        text.titleMedium,
        text.titleSmall,
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
        text.labelLarge,
        text.labelMedium,
        text.labelSmall,
      ]) {
        expect(TypeScale.all, contains(style!.fontSize));
      }
    });
  });
}
