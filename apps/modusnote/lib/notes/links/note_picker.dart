import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../journal/journal_days.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../note_title.dart';
import '../../theme/modus_palette.dart';

/// The note the person picked to link to, and what it is called.
typedef PickedNote = ({EntryId id, String title});

/// Lets the person search [notes] and pick one; null when dismissed.
Future<PickedNote?> showNotePicker(
  BuildContext context, {
  required List<DynamicEntry> notes,
  required SchemaDefinition? Function(DynamicEntry) schemaOf,
}) => showModalBottomSheet<PickedNote>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _NotePicker(notes: notes, schemaOf: schemaOf),
);

class _NotePicker extends StatefulWidget {
  const _NotePicker({required this.notes, required this.schemaOf});

  final List<DynamicEntry> notes;
  final SchemaDefinition? Function(DynamicEntry) schemaOf;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  var _search = EntrySearch('');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shown = [
      for (final note in widget.notes)
        if (_search.matches(note)) note,
    ];
    return SafeArea(
      child: Padding(
        // Above the keyboard, which the search field brings up.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * LayoutSplit.primary,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.l,
                  0,
                  Spacing.l,
                  Spacing.s,
                ),
                child: Text(
                  l10n.pickNoteToLink,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.l),
                child: TextField(
                  key: const ValueKey('note-picker-search'),
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.searchHint,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (query) =>
                      setState(() => _search = EntrySearch(query)),
                ),
              ),
              const SizedBox(height: Spacing.s),
              if (widget.notes.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Spacing.l),
                  child: Text(
                    l10n.noNotesToLink,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium,
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final note in shown)
                        _row(context, note, widget.schemaOf(note)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    DynamicEntry note,
    SchemaDefinition? schema,
  ) {
    final l10n = AppLocalizations.of(context);
    final title = NoteTitle.of(note, schema, day: JournalDays.longIn(context));
    return ListTile(
      key: ValueKey('pick-note-${note.id.value}'),
      leading: Icon(
        NoteAppearance.icon(schema?.icon),
        color: ModusPalette.of(context).tint(schema?.tint),
      ),
      title: Text(
        title.isEmpty ? l10n.untitled : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () =>
          Navigator.of(context)
              .pop((id: note.id, title: title.isEmpty ? l10n.untitled : title)),
    );
  }
}
