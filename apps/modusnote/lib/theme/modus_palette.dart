import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'golden_ratio.dart';
import 'modus_colors.dart';

/// The colours of a theme, by role. Widgets read them from the theme
/// ([ModusPalette.of]) and never name a colour themselves, so that one
/// theme can replace another everywhere at once.
@immutable
final class ModusPalette extends ThemeExtension<ModusPalette> {
  const ModusPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.text,
    required this.muted,
    required this.primary,
    required this.onAccent,
    required this.violetFill,
    required this.onVioletFill,
    required this.violet,
    required this.success,
    required this.rose,
    required this.error,
  });

  /// The brand: dark, from the visual identity of 2026-10-11.
  static const modus = ModusPalette(
    brightness: Brightness.dark,
    background: ModusColors.deepVoid,
    surface: ModusColors.abyssalSlate,
    text: ModusColors.pureMist,
    muted: ModusColors.dustSilver,
    primary: ModusColors.aureoGold,
    onAccent: ModusColors.deepVoid,
    violetFill: ModusColors.rhythmViolet,
    onVioletFill: ModusColors.pureMist,
    violet: ModusColors.rhythmVioletText,
    success: ModusColors.cadenceCyan,
    rose: ModusColors.lucidRose,
    error: Color(0xFFFF8A80),
  );

  final Brightness brightness;

  /// Behind everything.
  final Color background;

  /// Cards, side menus, sheets.
  final Color surface;

  /// Titles and the text of notes.
  final Color text;

  /// Timestamps, subtitles, Markdown markers: secondary lines.
  final Color muted;

  /// Main actions, saved notes, focus (gold in the brand).
  final Color primary;

  /// Text and icons on [primary], [success] and [rose].
  final Color onAccent;

  /// Violet as a fill only: below AA as text.
  final Color violetFill;
  final Color onVioletFill;

  /// Violet text and icons, at AA on [background] and [surface].
  final Color violet;

  /// Ticked boxes, completed deadlines (cyan in the brand).
  final Color success;

  /// Dream notes.
  final Color rose;

  final Color error;

  /// How much of a type's tint colours its card: 1/φ⁴, the most that
  /// keeps every text colour on the card at AA.
  static const washStrength =
      1 /
      (GoldenRatio.phi * GoldenRatio.phi * GoldenRatio.phi * GoldenRatio.phi);

  static ModusPalette of(BuildContext context) =>
      Theme.of(context).extension<ModusPalette>() ?? modus;

  /// A note type's accent: safe as text and icon colour on [background]
  /// and [surface]. A type without one (or with a name from a newer app)
  /// is muted silver.
  Color tint(NoteTint? tint) => switch (tint) {
    NoteTint.gold => primary,
    NoteTint.violet => violet,
    NoteTint.cyan => success,
    NoteTint.rose => rose,
    NoteTint.silver || null => muted,
  };

  /// The background of a note's card: [surface] washed with its tint.
  Color wash(NoteTint? tint) => Color.alphaBlend(
    this.tint(tint).withValues(alpha: washStrength),
    surface,
  );

  @override
  ModusPalette copyWith() => this;

  @override
  ModusPalette lerp(ModusPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return ModusPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      primary: mix(primary, other.primary),
      onAccent: mix(onAccent, other.onAccent),
      violetFill: mix(violetFill, other.violetFill),
      onVioletFill: mix(onVioletFill, other.onVioletFill),
      violet: mix(violet, other.violet),
      success: mix(success, other.success),
      rose: mix(rose, other.rose),
      error: mix(error, other.error),
    );
  }
}
