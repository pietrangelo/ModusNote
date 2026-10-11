import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import '../vault/auto_lock.dart';
import 'markdown/markdown_document.dart';
import 'note_editor.dart';
import 'note_store.dart';
import 'schema_text.dart';

/// Every note at a glance: search, a chip per note type, a card per note.
class NoteLibraryScreen extends StatefulWidget {
  const NoteLibraryScreen({
    required this.schemas,
    required this.store,
    this.onLock,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteStore store;

  /// Locks the vault; without it (no vault, e.g. the web preview) the
  /// library shows no lock button.
  final VoidCallback? onLock;

  @override
  State<NoteLibraryScreen> createState() => _NoteLibraryScreenState();
}

class _NoteLibraryScreenState extends State<NoteLibraryScreen> {
  var _search = EntrySearch('');
  SchemaDefinition? _type;

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in widget.schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  void _open({DynamicEntry? entry}) {
    final schema = entry == null
        ? _type ?? widget.schemas.last
        : _schemaOf(entry);
    if (schema == null) return;
    // A pushed route sits beside the library, not under it: it gets the
    // vault's auto-lock passed along explicitly.
    final autoLock = AutoLockScope.maybeOf(context);
    final editor = NoteEditorScreen(
      schemas: widget.schemas,
      store: widget.store,
      initialSchema: schema,
      entry: entry,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => autoLock == null
            ? editor
            : AutoLockScope(autoLock: autoLock, child: editor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.notesTitle),
        actions: [
          if (widget.onLock case final onLock?)
            IconButton(
              onPressed: onLock,
              tooltip: l10n.lockVault,
              icon: const Icon(Icons.lock_outline),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _open,
        icon: const Icon(Icons.add),
        label: Text(l10n.newNote),
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final all = widget.store.entries;
          final shown = [
            for (final entry in all)
              if ((_type == null || entry.schemaId == _type!.id) &&
                  _search.matches(entry))
                entry,
          ];
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.l,
                  Spacing.s,
                  Spacing.l,
                  Spacing.m,
                ),
                sliver: SliverList.list(
                  children: [
                    Text(
                      l10n.previewNotSaved,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: Spacing.m),
                    TextField(
                      decoration: InputDecoration(
                        hintText: l10n.searchHint,
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (query) =>
                          setState(() => _search = EntrySearch(query)),
                    ),
                    const SizedBox(height: Spacing.m),
                    Wrap(
                      spacing: Spacing.s,
                      runSpacing: Spacing.s,
                      children: [
                        ChoiceChip(
                          label: Text(l10n.allNoteTypes),
                          selected: _type == null,
                          onSelected: (_) => setState(() => _type = null),
                        ),
                        for (final schema in widget.schemas)
                          ChoiceChip(
                            label: Text(text.label(schema.label)),
                            selected: _type?.id == schema.id,
                            onSelected: (_) => setState(() => _type = schema),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (shown.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Center(
                      child: Text(
                        all.isEmpty ? l10n.emptyLibrary : l10n.noResults,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.m,
                    0,
                    Spacing.m,
                    Spacing.xxl,
                  ),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: Extents.xl,
                          childAspectRatio: GoldenRatio.phi,
                        ),
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final entry = shown[index];
                      return _NoteCard(
                        entry: entry,
                        schema: _schemaOf(entry),
                        text: text,
                        onTap: () => _open(entry: entry),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.entry,
    required this.schema,
    required this.text,
    required this.onTap,
  });

  final DynamicEntry entry;
  final SchemaDefinition? schema;
  final SchemaText text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final primary = schema?.primaryTextField;
    final title = switch (primary == null ? null : entry.valueOf(primary.key)) {
      // A Markdown title shows its words, not its markup.
      TextValue(:final text) when primary!.type is MarkdownFieldType =>
        MarkdownDocument.parse(text).plainText,
      TextValue(:final text) => text.trim(),
      _ => '',
    };
    final done = entry.attributes.values.any(
      (value) => value == const BooleanValue(true),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      schema == null ? '' : text.label(schema!.label),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: ModusColors.rhythmVioletText,
                      ),
                    ),
                  ),
                  if (done)
                    Icon(
                      Icons.check_circle,
                      size: IconSizes.inline,
                      color: theme.colorScheme.tertiary,
                    ),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Expanded(
                child: Text(
                  title.isEmpty ? l10n.untitled : title,
                  style: theme.textTheme.titleMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                MaterialLocalizations.of(context)
                    .formatMediumDate(entry.audit.updatedAt.toLocal()),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
