import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../../theme/modus_palette.dart';
import '../markdown/markdown_document.dart';
import '../note_title.dart';
import '../schema_text.dart';
import 'journal_days.dart';

/// Under a journal page: the pages of the same day in earlier years, the
/// latest first, each with how long ago, its first line and its mood; one
/// tap opens it. Nothing shows when there are none.
class OnThisDaySection extends StatelessWidget {
  const OnThisDaySection({
    required this.day,
    required this.pages,
    required this.schemaOf,
    required this.onOpen,
    super.key,
  });

  /// The day of the page open.
  final DateValue day;

  /// [Journal.onThisDay] of [day].
  final List<DynamicEntry> pages;
  final SchemaDefinition? Function(DynamicEntry) schemaOf;
  final ValueChanged<DynamicEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    return Column(
      key: const ValueKey('on-this-day'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
          child: Text(l10n.onThisDay, style: theme.textTheme.labelMedium),
        ),
        for (final page in pages)
          () {
            final schema = schemaOf(page);
            final when = Journal.dayOf(page)!;
            final title = NoteTitle.of(
              page,
              schema,
              day: JournalDays.longIn(context),
            );
            final mood = switch ((
              Journal.moodOf(page),
              schema?.fieldFor(Journal.mood),
            )) {
              (final mood?, final field?) => text.option(field, mood),
              _ => null,
            };
            final first = _firstLine(page);
            return ListTile(
              key: ValueKey('on-this-day-${page.id.value}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.history, color: palette.tint(schema?.tint)),
              title: Text(
                [l10n.yearsAgo(day.year - when.year), title].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: first.isEmpty && mood == null
                  ? null
                  : Text(
                      [?mood, if (first.isNotEmpty) first].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => onOpen(page),
            );
          }(),
      ],
    );
  }

  /// The first line of the page's words, without its markup.
  static String _firstLine(DynamicEntry page) {
    final text = switch (page.valueOf(Journal.page)) {
      TextValue(:final text) => MarkdownDocument.parse(text).plainText,
      _ => '',
    };
    for (final line in text.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return '';
  }
}
