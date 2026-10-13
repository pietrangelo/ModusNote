import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'categories/categories_screen.dart';
import 'categories/category_picker.dart';
import 'note_appearance.dart';
import 'note_editor.dart';
import 'note_store.dart';
import 'note_title.dart';
import 'schema_text.dart';
import 'trash_screen.dart';

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

  /// The category being looked at; null for every note. It may name one
  /// that is gone, which shows every note.
  CategoryId? _category;

  CategoryId? get _selected => widget.store.categories.resolve(_category);

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
    _push(
      NoteEditorScreen(
        schemas: widget.schemas,
        store: widget.store,
        initialSchema: schema,
        entry: entry,
        category: _selected,
      ),
    );
  }

  void _openCategories() => _push(CategoriesScreen(store: widget.store));

  Future<void> _file(DynamicEntry entry) async {
    final store = widget.store;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final choice = await showCategoryPicker(
      context,
      tree: store.categories,
      current: store.categoryOf(entry.id),
    );
    if (choice == null) return;
    await store.file(entry.id, choice.id);
    final name = switch (choice.id) {
      final id? => store.categories[id]?.name.value,
      null => null,
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(name == null ? l10n.noteUnfiled : l10n.noteFiled(name)),
        ),
      );
  }

  void _openTrash() =>
      _push(TrashScreen(schemas: widget.schemas, store: widget.store));

  void _push(Widget screen) {
    // A pushed route sits beside the library, not under it: it gets the
    // vault's auto-lock passed along explicitly.
    final autoLock = AutoLockScope.maybeOf(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => autoLock == null
            ? screen
            : AutoLockScope(autoLock: autoLock, child: screen),
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
          IconButton(
            onPressed: _openCategories,
            tooltip: l10n.categories,
            icon: const Icon(Icons.folder_outlined),
          ),
          IconButton(
            onPressed: _openTrash,
            tooltip: l10n.trash,
            icon: const Icon(Icons.delete_outline),
          ),
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
          final store = widget.store;
          final all = store.entries;
          final tree = store.categories;
          final selected = _selected;
          final within = selected == null ? null : tree.subtree(selected);
          final shown = [
            for (final entry in all)
              if ((_type == null || entry.schemaId == _type!.id) &&
                  (within == null ||
                      within.contains(store.categoryOf(entry.id))) &&
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
                    if (!tree.isEmpty) ...[
                      const SizedBox(height: Spacing.s),
                      _CategoryBar(
                        tree: tree,
                        selected: selected,
                        onSelect: (id) => setState(() => _category = id),
                      ),
                    ],
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
                        onLongPress: () => _file(entry),
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

/// Where the library is looking: the path from every note down to the
/// selected category, each step a way back up, then the categories inside
/// it, one tap to go in.
class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.tree,
    required this.selected,
    required this.onSelect,
  });

  final CategoryTree tree;
  final CategoryId? selected;
  final ValueChanged<CategoryId?> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final path = selected == null
        ? const <NoteCategory>[]
        : tree.pathTo(selected!);
    final inside = selected == null ? tree.roots : tree.childrenOf(selected!);
    Widget step(CategoryId? id, String label, {required bool last}) =>
        TextButton(
          key: ValueKey('path-${id?.value ?? 'all'}'),
          onPressed: last ? null : () => onSelect(id),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrapped, not scrolled: every step stays in sight and in reach.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            step(null, l10n.allNotes, last: path.isEmpty),
            for (final (index, category) in path.indexed) ...[
              Icon(
                Icons.chevron_right,
                size: IconSizes.inline,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              step(
                category.id,
                category.name.value,
                last: index == path.length - 1,
              ),
            ],
          ],
        ),
        if (inside.isNotEmpty)
          Wrap(
            spacing: Spacing.s,
            runSpacing: Spacing.s,
            children: [
              for (final category in inside)
                ActionChip(
                  key: ValueKey('category-${category.id.value}'),
                  avatar: Icon(
                    CategoryAppearance.icon(category.icon),
                    size: IconSizes.inline,
                    color: CategoryAppearance.tint(category.tint),
                  ),
                  label: Text(category.name.value),
                  onPressed: () => onSelect(category.id),
                ),
            ],
          ),
      ],
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
    required this.onLongPress,
  });

  final DynamicEntry entry;
  final SchemaDefinition? schema;
  final SchemaText text;
  final VoidCallback onTap;

  /// Files the note in a category.
  final VoidCallback onLongPress;

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
    final tasks = entry.attributes.values.whereType<ChecklistValue>().toList();
    final title = NoteTitle.of(entry, schema);
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
        onLongPress: onLongPress,
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
