import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// How a note type is told apart at a glance: the icon its schema names
/// (the accent colour comes from the theme, `ModusPalette.tint`). A type
/// without one (or with a name from a newer app) gets a neutral page.
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
    NoteIcon.bookmark => Icons.bookmark_border,
    NoteIcon.person => Icons.person_outline,
    NoteIcon.place => Icons.place_outlined,
    NoteIcon.key => Icons.key_outlined,
    NoteIcon.calendar => Icons.calendar_today_outlined,
    NoteIcon.recipe => Icons.restaurant_menu_outlined,
    null => Icons.description_outlined,
  };
}

/// How a category is told apart: the icon it names, a folder when it
/// names none.
abstract final class CategoryAppearance {
  static IconData icon(NoteIcon? icon) =>
      icon == null ? Icons.folder_outlined : NoteAppearance.icon(icon);
}
