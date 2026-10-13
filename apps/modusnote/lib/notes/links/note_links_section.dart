import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../note_title.dart';

/// Under a note: the notes it links to and the notes that link to it,
/// each one tap away. A link to a note that is gone (deleted, or in the
/// trash) stays visible, greyed, so the text still makes sense.
class NoteLinksSection extends StatelessWidget {
  const NoteLinksSection({
    required this.links,
    required this.backlinks,
    required this.find,
    required this.schemaOf,
    required this.onOpen,
    super.key,
  });

  /// The notes this one links to, in the order the text names them.
  final List<EntryId> links;

  /// The notes that link to this one.
  final List<DynamicEntry> backlinks;

  /// A note in the library, or null when it is not there.
  final DynamicEntry? Function(EntryId) find;
  final SchemaDefinition? Function(DynamicEntry) schemaOf;
  final ValueChanged<DynamicEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
      child: Text(text, style: theme.textTheme.labelMedium),
    );
    Widget row(String kind, EntryId id, DynamicEntry? note) {
      final schema = note == null ? null : schemaOf(note);
      final title = note == null ? '' : NoteTitle.of(note, schema);
      return ListTile(
        key: ValueKey('$kind-${id.value}'),
        contentPadding: EdgeInsets.zero,
        enabled: note != null,
        leading: Icon(
          note == null ? Icons.link_off : NoteAppearance.icon(schema?.icon),
          color: note == null ? null : NoteAppearance.tint(schema?.tint),
        ),
        title: Text(
          note == null
              ? l10n.linkUnavailable
              : (title.isEmpty ? l10n.untitled : title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: note == null ? null : () => onOpen(note),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (links.isNotEmpty) ...[
          heading(l10n.linksTitle),
          for (final id in links) row('link', id, find(id)),
        ],
        if (backlinks.isNotEmpty) ...[
          heading(l10n.backlinksTitle),
          for (final note in backlinks) row('backlink', note.id, note),
        ],
      ],
    );
  }
}
