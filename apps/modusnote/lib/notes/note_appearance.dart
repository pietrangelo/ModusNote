import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';

/// How a note type is told apart at a glance: the icon and accent colour
/// its schema names. A type without them (or with names from a newer
/// app) gets a neutral page in muted silver.
abstract final class NoteAppearance {
  static IconData icon(NoteIcon? icon) => switch (icon) {
    NoteIcon.note => Icons.edit_note,
    NoteIcon.music => Icons.music_note,
    NoteIcon.moon => Icons.bedtime_outlined,
    NoteIcon.checklist => Icons.checklist,
    NoteIcon.star => Icons.star_outline,
    NoteIcon.lightbulb => Icons.lightbulb_outline,
    NoteIcon.book => Icons.menu_book_outlined,
    NoteIcon.heart => Icons.favorite_border,
    NoteIcon.page => Icons.article_outlined,
    null => Icons.description_outlined,
  };

  /// Safe as text and icon colour on Deep Void and Abyssal Slate.
  static Color tint(NoteTint? tint) => switch (tint) {
    NoteTint.gold => ModusColors.aureoGold,
    NoteTint.violet => ModusColors.rhythmVioletText,
    NoteTint.cyan => ModusColors.cadenceCyan,
    NoteTint.rose => ModusColors.lucidRose,
    NoteTint.silver || null => ModusColors.dustSilver,
  };

  /// How much of the tint colours a card: 1/φ⁴, the most that keeps every
  /// text colour on the card at AA.
  static const washStrength =
      1 /
      (GoldenRatio.phi * GoldenRatio.phi * GoldenRatio.phi * GoldenRatio.phi);

  /// The background of a note's card: Abyssal Slate washed with its tint.
  static Color wash(NoteTint? tint) => Color.alphaBlend(
    NoteAppearance.tint(tint).withValues(alpha: washStrength),
    ModusColors.abyssalSlate,
  );
}

/// How a category is told apart: the icon and tint it names, a folder in
/// muted silver when it names none.
abstract final class CategoryAppearance {
  static IconData icon(NoteIcon? icon) =>
      icon == null ? Icons.folder_outlined : NoteAppearance.icon(icon);

  static Color tint(NoteTint? tint) => NoteAppearance.tint(tint);
}
