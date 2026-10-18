import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'journal/journal_days.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import 'note_appearance.dart';
import 'note_store.dart';
import 'note_title.dart';
import 'schema_text.dart';
import '../theme/modus_palette.dart';

/// Notes moved to the trash: each can go back to the library or be
/// deleted for good, recordings included, on every device.
class TrashScreen extends StatelessWidget {
  const TrashScreen({required this.schemas, required this.store, super.key});

  final List<SchemaDefinition> schemas;
  final NoteStore store;

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  /// Asks before anything is deleted for good: nothing brings it back.
  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _empty(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    if (await _confirm(
      context,
      title: l10n.emptyTrashTitle,
      body: l10n.emptyTrashBody,
    )) {
      await store.emptyTrash();
    }
  }

  Future<void> _delete(BuildContext context, EntryId id) async {
    final l10n = AppLocalizations.of(context);
    if (await _confirm(
      context,
      title: l10n.deleteForeverTitle,
      body: l10n.deleteForeverBody,
    )) {
      await store.deleteForever(id);
    }
  }

  Future<void> _restore(BuildContext context, EntryId id) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    await store.restore(id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.noteRestored)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final trash = store.trash;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.trash),
            actions: [
              TextButton(
                onPressed: trash.isEmpty ? null : () => _empty(context),
                child: Text(l10n.emptyTrash),
              ),
              const SizedBox(width: Spacing.s),
            ],
          ),
          body: trash.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Text(
                      l10n.trashIsEmpty,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: Extents.xxl),
                    child: ListView.builder(
                      // Edge to edge: the end scrolls clear of the
                      // system navigation bar.
                      padding: const EdgeInsets.all(Spacing.m).copyWith(
                        bottom:
                            Spacing.m + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: trash.length,
                      itemBuilder: (context, index) {
                        final note = trash[index];
                        final id = note.entry.id;
                        return _TrashedCard(
                          key: ValueKey(id),
                          note: note,
                          schema: _schemaOf(note.entry),
                          onRestore: () => _restore(context, id),
                          onDelete: () => _delete(context, id),
                        );
                      },
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _TrashedCard extends StatelessWidget {
  const _TrashedCard({
    required this.note,
    required this.schema,
    required this.onRestore,
    required this.onDelete,
    super.key,
  });

  final RecordedNote note;
  final SchemaDefinition? schema;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = NoteTitle.of(
      note.entry,
      schema,
      day: JournalDays.longIn(context),
    );
    final type = schema == null ? '' : SchemaText(l10n).label(schema!.label);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.m,
          Spacing.s,
          Spacing.xs,
          Spacing.s,
        ),
        child: Row(
          children: [
            Icon(
              NoteAppearance.icon(schema?.icon),
              size: IconSizes.inline,
              color: ModusPalette.of(context).tint(schema?.tint),
            ),
            const SizedBox(width: Spacing.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? l10n.untitled : title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    [
                      if (type.isNotEmpty) type,
                      l10n.trashedOn(note.trashedAt!.toLocal()),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onRestore,
              tooltip: l10n.restoreNote,
              icon: const Icon(Icons.restore_from_trash),
            ),
            IconButton(
              onPressed: onDelete,
              tooltip: l10n.deleteForever,
              icon: const Icon(Icons.delete_forever),
            ),
          ],
        ),
      ),
    );
  }
}
