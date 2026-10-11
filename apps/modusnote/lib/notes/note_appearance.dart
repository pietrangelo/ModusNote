import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

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
    null => Icons.description_outlined,
  };

  /// Safe as text and icon colour on Deep Void and Abyssal Slate.
  static Color tint(NoteTint? tint) => switch (tint) {
    NoteTint.gold => ModusColors.aureoGold,
    NoteTint.violet => ModusColors.rhythmVioletText,
    NoteTint.cyan => ModusColors.cadenceCyan,
    NoteTint.rose => ModusColors.lucidRose,
    null => ModusColors.dustSilver,
  };
}
