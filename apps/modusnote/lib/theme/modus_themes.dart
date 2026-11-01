import 'dart:math';
import 'dart:ui';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'golden_ratio.dart';
import 'modus_palette.dart';
import 'oklch.dart';

/// The themes a person can pick for the whole app (2026-10-15).
enum AppTheme {
  /// The brand: dark, Deep Void and Aureo Gold.
  modus,

  /// Dark and restful: no pure black or white, low chroma, warm text.
  restful,

  /// Light, like warm paper, for daylight reading.
  paper,
}

/// What a note type is for, which the page of the note reflects: books,
/// dreams and songs invite imagination; quick notes and documents ask for
/// concentration; to-dos and credentials for order.
enum NoteMood {
  imagination,
  concentration,
  order;

  /// By the type's name, so a newer version of a type keeps its mood; a
  /// type made by the person, or unknown, is for concentration.
  static NoteMood of(SchemaDefinition? schema) => switch (schema?.id.name) {
    'book' ||
    'book_chapter' ||
    'book_character' ||
    'book_place' ||
    'dream_log' ||
    'song_sketch' ||
    'journal' => imagination,
    'task' || 'credential' => order,
    _ => concentration,
  };
}

/// The palettes of every theme, for the app ([palette] with no mood) and
/// for the page of a note in each mood. All derived with φ in OKLCH:
///
/// * a surface sits 1/φ⁴ of the background's lightness above it (dark) or
///   1/φ of the way to white (light);
/// * secondary text is the text's lightness divided by √φ (dark) or times
///   φ (light);
/// * the accents share one lightness and one chroma, their hues those of
///   the brand, so every type tint stays AA on every background.
abstract final class ModusThemes {
  /// How long one theme or mood takes to become another: 377 ms, a
  /// Fibonacci number like every extent of the app.
  static const transition = Duration(milliseconds: 377);

  static ModusPalette palette(AppTheme theme, [NoteMood? mood]) =>
      _cache[(theme, mood)] ??= switch (theme) {
        AppTheme.modus => _modus(mood),
        AppTheme.restful => _derive(dark: true, mood: mood),
        AppTheme.paper => _derive(dark: false, mood: mood),
      };

  static final _cache = <(AppTheme, NoteMood?), ModusPalette>{};

  static final _phi2 = GoldenRatio.phi * GoldenRatio.phi;
  static final _phi4 = _phi2 * _phi2;

  /// The brand, with the page of a note washed by its mood at 1/φ⁶: the
  /// same identity, a hint of the note's purpose. Only the background:
  /// violet text on Abyssal Slate is already at the edge of AA.
  static ModusPalette _modus(NoteMood? mood) {
    const brand = ModusPalette.modus;
    final accent = switch (mood) {
      null || NoteMood.concentration => null,
      NoteMood.imagination => brand.violet,
      NoteMood.order => brand.success,
    };
    if (accent == null) return brand;
    final wash = accent.withValues(alpha: 1 / (_phi4 * _phi2));
    return brand.copyWith(background: Color.alphaBlend(wash, brand.background));
  }

  // Hues of the brand's accents, in OKLCH degrees.
  static const _gold = 85.0;
  static const _violet = 305.0;
  static const _cyan = 230.0;
  static const _rose = 355.0;
  static const _sage = 150.0;
  static const _red = 25.0;

  /// Background hue and chroma, text hue: per mood, then for the app.
  static (double, double, double) _tones({
    required bool dark,
    required NoteMood? mood,
  }) => dark
      ? switch (mood) {
          null => (250, 0.020, 80),
          NoteMood.imagination => (300, 0.028, 85),
          NoteMood.concentration => (250, 0.028, 80),
          NoteMood.order => (215, 0.028, 200),
        }
      : switch (mood) {
          null || NoteMood.concentration => (75, 0.022, 250),
          NoteMood.imagination => (60, 0.026, 300),
          NoteMood.order => (200, 0.022, 215),
        };

  static ModusPalette _derive({required bool dark, required NoteMood? mood}) {
    final (bgHue, bgChroma, textHue) = _tones(dark: dark, mood: mood);
    // Dark: a deep background, text far from white. Light: warm paper,
    // text far from black.
    final bgLight = dark ? 0.19 : 0.955;
    final textLight = dark ? 0.90 : 0.30;
    final accentLight = dark ? 0.80 : 0.48;
    final accentChroma = dark ? 0.09 : 0.10;
    final background = oklch(bgLight, bgChroma, bgHue);
    final surface = dark
        ? oklch(bgLight + bgLight / _phi4, bgChroma * 1.15, bgHue)
        : oklch(
            bgLight + (1 - bgLight) / GoldenRatio.phi,
            bgChroma / GoldenRatio.phi,
            bgHue,
          );
    final text = oklch(textLight, dark ? 0.018 : 0.020, textHue);
    final muted = oklch(
      dark ? textLight / sqrt(GoldenRatio.phi) : textLight * GoldenRatio.phi,
      0.020,
      textHue,
    );
    Color accent(double hue) => oklch(accentLight, accentChroma, hue);
    final gold = accent(_gold);
    final violet = accent(_violet);
    final cyan = accent(_cyan);
    final rose = accent(_rose);
    return ModusPalette(
      brightness: dark ? Brightness.dark : Brightness.light,
      background: background,
      surface: surface,
      text: text,
      muted: muted,
      primary: switch (mood) {
        NoteMood.imagination => rose,
        NoteMood.order => cyan,
        null || NoteMood.concentration => gold,
      },
      onAccent: background,
      violetFill: dark
          ? oklch(accentLight / GoldenRatio.phi, 0.13, _violet)
          : violet,
      onVioletFill: dark ? text : background,
      violet: violet,
      gold: gold,
      success: cyan,
      rose: rose,
      sage: accent(_sage),
      error: oklch(dark ? 0.80 : 0.48, dark ? 0.12 : 0.14, _red),
    );
  }
}
