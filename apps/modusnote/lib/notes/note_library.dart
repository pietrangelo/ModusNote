import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'markdown/markdown_document.dart';
import 'note_appearance.dart';
import 'note_editor.dart';
import 'note_store.dart';
import 'schema_text.dart';

/// Every note at a glance: search, a chip per note type, a card per note.
class NoteLibraryScreen extends StatefulWidget {
  const NoteLibraryScreen({
    required this.schemas,
    required this.store,
    this.cloud,
    this.onLock,
    this.onPasskey,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteStore store;

  /// The sync status button; null in a build without a server.
  final Widget? cloud;

  /// Locks the vault; without it (no vault, e.g. the web preview) the
  /// library shows no lock button.
  final VoidCallback? onLock;

  /// Opens the passkey settings; null where passkeys are not offered.
  final VoidCallback? onPasskey;

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
          ?widget.cloud,
          if (widget.onPasskey case final onPasskey?)
            IconButton(
              onPressed: onPasskey,
              tooltip: l10n.passkeySettings,
              icon: const Icon(Icons.fingerprint),
            ),
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
                            avatar: Icon(
                              NoteAppearance.icon(schema.icon),
                              size: IconSizes.inline,
                              color: NoteAppearance.tint(schema.tint),
                            ),
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
                    gridDelegate: _CardGridDelegate(
                      minHeight: _NoteCard.minHeight(context),
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

/// Cards in φ : 1, unless the system text size needs them taller to show
/// the type, one line of the title and the date.
class _CardGridDelegate extends SliverGridDelegateWithMaxCrossAxisExtent {
  const _CardGridDelegate({required this.minHeight})
    : super(maxCrossAxisExtent: Extents.xl, childAspectRatio: GoldenRatio.phi);

  final double minHeight;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final golden = super.getLayout(constraints) as SliverGridRegularTileLayout;
    if (golden.childMainAxisExtent >= minHeight) return golden;
    return SliverGridRegularTileLayout(
      crossAxisCount: golden.crossAxisCount,
      mainAxisStride: minHeight,
      crossAxisStride: golden.crossAxisStride,
      childMainAxisExtent: minHeight,
      childCrossAxisExtent: golden.childCrossAxisExtent,
      reverseCrossAxis: golden.reverseCrossAxis,
    );
  }

  @override
  bool shouldRelayout(_CardGridDelegate oldDelegate) =>
      oldDelegate.minHeight != minHeight || super.shouldRelayout(oldDelegate);
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

  /// The least height that shows a card's type, a title line and its date
  /// at the current text size, margins included.
  static double minHeight(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: 'M', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final label = line(theme.textTheme.labelSmall);
    final margin = theme.cardTheme.margin?.vertical ?? 0;
    return margin +
        2 * Spacing.m +
        (label > IconSizes.inline ? label : IconSizes.inline) +
        Spacing.xs +
        line(theme.textTheme.titleMedium) +
        line(theme.textTheme.bodySmall);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final primary = schema?.primaryTextField;
    final tasks = entry.attributes.values.whereType<ChecklistValue>().toList();
    final named = switch (primary == null ? null : entry.valueOf(primary.key)) {
      // A Markdown title shows its words, not its markup.
      TextValue(:final text) when primary!.type is MarkdownFieldType =>
        MarkdownDocument.parse(text).plainText,
      TextValue(:final text) => text.trim(),
      _ => '',
    };
    // An untitled list is named by the tasks still to do.
    final title = named.isNotEmpty || tasks.isEmpty
        ? named
        : [
            for (final item in tasks.first.items)
              if (!item.done) item.text,
          ].join(', ');
    final done = tasks.isEmpty
        ? entry.attributes.values.any(
            (value) => value == const BooleanValue(true),
          )
        : tasks.every((list) => list.allDone);
    final tint = NoteAppearance.tint(schema?.tint);
    return Card(
      color: NoteAppearance.wash(schema?.tint),
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
                  Icon(
                    NoteAppearance.icon(schema?.icon),
                    size: IconSizes.inline,
                    color: tint,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      schema == null ? '' : text.label(schema!.label),
                      // Muted, not tinted: violet on a violet card is
                      // below AA, and the card already says the type.
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (tasks.isNotEmpty && !done)
                    Text(
                      l10n.taskProgress(
                        tasks.fold(0, (sum, list) => sum + list.done),
                        tasks.fold(0, (sum, list) => sum + list.total),
                      ),
                      style: theme.textTheme.labelSmall,
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
                child: _WholeLines(
                  title.isEmpty ? l10n.untitled : title,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(
                MaterialLocalizations.of(context)
                    .formatMediumDate(entry.audit.updatedAt.toLocal()),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Text that shows only the lines its box can hold, ending in an ellipsis,
/// instead of a last line cut in half: how many fit depends on the card's
/// width and on the system text size.
class _WholeLines extends StatelessWidget {
  const _WholeLines(this.text, {this.style});

  final String text;
  final TextStyle? style;

  static const maxLines = 3;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final line = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout(maxWidth: constraints.maxWidth);
      final fit = (constraints.maxHeight / line.height).floor();
      line.dispose();
      if (fit < 1) return const SizedBox.shrink();
      return Text(
        text,
        style: style,
        maxLines: fit < maxLines ? fit : maxLines,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}
