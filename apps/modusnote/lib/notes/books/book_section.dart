import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../note_title.dart';
import '../schema_text.dart';
import 'book_outline.dart';
import '../../theme/modus_palette.dart';

/// Under a book: how far the writing has come, and its chapters,
/// characters and places, each one tap away, with a button to write a
/// new one in the book's category.
class BookSection extends StatelessWidget {
  const BookSection({
    required this.outline,
    required this.goal,
    required this.schemas,
    required this.onOpen,
    required this.onAdd,
    super.key,
  });

  /// Null when the book is in no category.
  final BookOutline? outline;

  /// The words the book should reach, if it says.
  final int? goal;
  final List<SchemaDefinition> schemas;
  final ValueChanged<DynamicEntry> onOpen;

  /// Writes a new note of this type in the book.
  final ValueChanged<SchemaDefinition> onAdd;

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  SchemaDefinition? _current(String name) {
    for (final schema in schemas) {
      if (schema.id.name == name) return schema;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final outline = this.outline;
    if (outline == null) {
      return Padding(
        padding: const EdgeInsets.only(top: Spacing.l),
        child: Text(l10n.bookNotFiled, style: muted),
      );
    }
    final goal = this.goal;
    final words = outline.words;

    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
      child: Text(label, style: theme.textTheme.labelMedium),
    );

    Widget row(DynamicEntry entry, {Widget? leading, String? subtitle}) {
      final schema = _schemaOf(entry);
      final title = NoteTitle.of(entry, schema);
      return ListTile(
        key: ValueKey('book-${entry.id.value}'),
        contentPadding: EdgeInsets.zero,
        leading:
            leading ??
            Icon(
              NoteAppearance.icon(schema?.icon),
              color: ModusPalette.of(context).tint(schema?.tint),
            ),
        title: Text(
          title.isEmpty ? l10n.untitled : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: () => onOpen(entry),
      );
    }

    Widget add(String name, String label) {
      final schema = _current(name);
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          icon: const Icon(Icons.add, size: IconSizes.inline),
          label: Text(label),
          onPressed: schema == null ? null : () => onAdd(schema),
        ),
      );
    }

    String chapterLine(OutlinedChapter chapter) {
      final schema = _schemaOf(chapter.entry);
      final status = schema?.fieldFor(FieldKey('status'));
      final state = switch (chapter.entry.valueOf(FieldKey('status'))) {
        ChoiceValue(:final option) when status != null => text.option(
          status,
          option,
        ),
        _ => null,
      };
      final count = l10n.wordCount(chapter.words);
      return state == null ? count : '$state · $count';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading(l10n.bookChapters),
        Text(
          goal == null ? l10n.wordCount(words) : l10n.bookProgress(words, goal),
          key: const ValueKey('book-words'),
          style: theme.textTheme.bodyMedium,
        ),
        if (goal != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: LinearProgressIndicator(
              value: (words / goal).clamp(0, 1).toDouble(),
              borderRadius: BorderRadius.circular(Radii.small),
            ),
          ),
        for (final chapter in outline.chapters)
          row(
            chapter.entry,
            leading: chapter.number == null
                ? null
                : SizedBox(
                    width: IconSizes.prominent,
                    child: Text(
                      '${chapter.number}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
            subtitle: chapterLine(chapter),
          ),
        add(BookOutline.chapter, l10n.addChapter),
        heading(l10n.bookCharacters),
        for (final character in outline.characters) row(character),
        add(BookOutline.character, l10n.addCharacter),
        heading(l10n.bookPlaces),
        for (final place in outline.places) row(place),
        add(BookOutline.place, l10n.addPlace),
      ],
    );
  }
}
