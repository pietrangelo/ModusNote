import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'categories/categories_screen.dart';
import 'categories/category_picker.dart';
import 'command_palette.dart';
import 'note_appearance.dart';
import 'note_editor.dart';
import 'note_store.dart';
import 'note_title.dart';
import 'schema_text.dart';
import 'trash_screen.dart';

/// Every note at a glance: search, categories, a chip per note type, a
/// card per note, each opening on a page of its own. A window at least
/// [wideFrom] wide shows three columns instead, as a desktop notes app
/// does: note types, categories and the trash; the list of notes; and the
/// open note beside it.
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

  /// The narrowest window that shows the three columns.
  static const wideFrom = Extents.xxxl;

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

  /// Three columns only: the open note, as its id or a [_NewNote].
  Object? _opened;
  var _editor = GlobalKey<NoteEditorScreenState>();
  var _showTrash = false;

  /// Three columns only: the notes picked to act on together, or null
  /// while none are being picked. Only those the list shows are acted on.
  Set<EntryId>? _picks;

  /// Where a Shift+click range starts: the note picked last.
  EntryId? _anchor;

  /// The notes the filters let through: type, category and its
  /// subcategories, search.
  List<DynamicEntry> _shown() {
    final store = widget.store;
    final selected = _selected;
    final within = selected == null ? null : store.categories.subtree(selected);
    return [
      for (final entry in store.entries)
        if ((_type == null || entry.schemaId == _type!.id) &&
            (within == null || within.contains(store.categoryOf(entry.id))) &&
            _search.matches(entry))
          entry,
    ];
  }

  /// Shows [opened] beside the list, once the open note is saved; a note
  /// that cannot be saved, kept by the user, stays.
  Future<void> _openBeside(Object? opened, {bool trash = false}) async {
    if (opened != null && opened == _opened) return;
    if (_editor.currentState case final editor?) {
      if (!await editor.settle() || !mounted) return;
    }
    setState(() {
      _opened = opened;
      _showTrash = trash;
      _editor = GlobalKey();
      if (trash) _picks = null;
    });
  }

  /// A click on a row of the list: opens the note, or with Ctrl (⌘) or
  /// while picking adds it to the picks or takes it out, and with Shift
  /// picks every note from the last one picked.
  void _click(DynamicEntry entry, List<DynamicEntry> shown) {
    final keys = HardwareKeyboard.instance;
    final anchor = shown.indexWhere((e) => e.id == _anchor);
    if (keys.isShiftPressed && anchor >= 0) {
      final at = shown.indexOf(entry);
      final (from, to) = anchor < at ? (anchor, at) : (at, anchor);
      setState(() {
        _picks = {
          ...?_picks,
          for (final e in shown.sublist(from, to + 1)) e.id,
        };
        _anchor = entry.id;
      });
    } else if (_picks != null ||
        keys.isControlPressed ||
        keys.isMetaPressed ||
        keys.isShiftPressed) {
      _toggle(entry.id);
    } else {
      unawaited(_openBeside(entry.id));
    }
  }

  void _toggle(EntryId id) => setState(() {
    final picks = _picks ??= {};
    if (!picks.remove(id)) picks.add(id);
    _anchor = id;
  });

  void _endPicking() => setState(() {
    _picks = null;
    _anchor = null;
  });

  /// The picks the list shows: a note a filter or search hides is never
  /// acted on unseen.
  List<EntryId> _pickedShown() {
    final picks = _picks ?? const <EntryId>{};
    return [
      for (final entry in _shown())
        if (picks.contains(entry.id)) entry.id,
    ];
  }

  Future<void> _trashPicked() async {
    final ids = _pickedShown();
    if (ids.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // The open note is saved first, so nothing written in it is lost; a
    // note that cannot be saved, kept by the user, stops it all.
    if (_opened case final EntryId open when ids.contains(open)) {
      await _openBeside(null);
      if (!mounted || _opened != null) return;
    }
    final store = widget.store;
    for (final id in ids) {
      await store.moveToTrash(id);
    }
    if (!mounted) return;
    _endPicking();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.notesTrashed(ids.length)),
          action: SnackBarAction(
            label: l10n.undo,
            onPressed: () => unawaited(() async {
              for (final id in ids) {
                await store.restore(id);
              }
            }()),
          ),
        ),
      );
  }

  Future<void> _filePicked() async {
    final ids = _pickedShown();
    if (ids.isEmpty) return;
    final store = widget.store;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final now = {for (final id in ids) store.categoryOf(id)};
    final choice = await showCategoryPicker(
      context,
      tree: store.categories,
      current: now.length == 1 ? now.single : null,
    );
    if (choice == null) return;
    for (final id in ids) {
      await store.file(id, choice.id);
    }
    if (!mounted) return;
    _endPicking();
    final name = switch (choice.id) {
      final id? => store.categories[id]?.name.value,
      null => null,
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            name == null
                ? l10n.notesUnfiled(ids.length)
                : l10n.notesFiled(ids.length, name),
          ),
        ),
      );
  }

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in widget.schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  void _open({DynamicEntry? entry, SchemaDefinition? schema}) {
    schema = entry == null
        ? schema ?? _type ?? widget.schemas.last
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

  bool get _isWide =>
      MediaQuery.sizeOf(context).width >= NoteLibraryScreen.wideFrom;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      CommandPalette.activator: _showPalette,
      if (_picks != null)
        const SingleActivator(LogicalKeyboardKey.escape): _endPicking,
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= NoteLibraryScreen.wideFrom
            ? _wide(context)
            : _narrow(context),
      ),
    ),
  );

  void _showPalette() => unawaited(CommandPalette.show(context, _commands));

  /// What the palette offers for [query]: with nothing typed the latest
  /// notes come first, otherwise the commands whose name matches.
  List<PaletteCommand> _commands(String query) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final wide = _isWide;
    final terms = EntrySearch.fold(query)
        .split(' ')
        .where((term) => term.isNotEmpty)
        .toList();
    bool named(String label) {
      final folded = EntrySearch.fold(label);
      return terms.every(folded.contains);
    }

    final actions = [
      for (final schema in widget.schemas)
        PaletteCommand(
          icon: NoteAppearance.icon(schema.icon),
          color: NoteAppearance.tint(schema.tint),
          label: l10n.paletteNewNote(text.label(schema.label)),
          run: () => wide
              ? unawaited(_openBeside(_NewNote(schema)))
              : _open(schema: schema),
        ),
      PaletteCommand(
        icon: Icons.folder_outlined,
        label: l10n.categories,
        run: _openCategories,
      ),
      PaletteCommand(
        icon: Icons.delete_outline,
        label: l10n.trash,
        run: () =>
            wide ? unawaited(_openBeside(null, trash: true)) : _openTrash(),
      ),
      if (widget.onLock case final onLock?)
        PaletteCommand(
          icon: Icons.lock_outline,
          label: l10n.lockVault,
          run: onLock,
        ),
    ].where((command) => named(command.label));
    final search = EntrySearch(query);
    final dates = MaterialLocalizations.of(context);
    final notes = [
      for (final entry in widget.store.entries)
        if (search.matches(entry))
          () {
            final schema = _schemaOf(entry);
            final title = NoteTitle.of(entry, schema);
            return PaletteCommand(
              icon: NoteAppearance.icon(schema?.icon),
              color: NoteAppearance.tint(schema?.tint),
              label: title.isEmpty ? l10n.untitled : title,
              detail: dates.formatMediumDate(entry.audit.updatedAt.toLocal()),
              run: () =>
                  wide ? unawaited(_openBeside(entry.id)) : _open(entry: entry),
            );
          }(),
    ];
    return terms.isEmpty ? [...notes, ...actions] : [...actions, ...notes];
  }

  List<Widget> _actions(AppLocalizations l10n, {bool trash = true}) => [
    ?widget.cloud,
    IconButton(
      onPressed: _openCategories,
      tooltip: l10n.categories,
      icon: const Icon(Icons.folder_outlined),
    ),
    if (trash)
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
  ];

  Widget _searchField(AppLocalizations l10n) => TextField(
    decoration: InputDecoration(
      hintText: l10n.searchHint,
      prefixIcon: const Icon(Icons.search),
    ),
    onChanged: (query) => setState(() => _search = EntrySearch(query)),
  );

  /// A filter picked in the side column; the trash, if open, gives way to
  /// the notes.
  void _filter(void Function() change) {
    setState(change);
    if (_showTrash) unawaited(_openBeside(null));
  }

  Widget _wide(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    final divider = Border(right: BorderSide(color: theme.dividerColor));
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              key: const ValueKey('pane-types'),
              color: theme.colorScheme.surface,
              shape: divider,
              child: SizedBox(
                width: Extents.l,
                child: ListenableBuilder(
                  listenable: widget.store,
                  builder: (context, _) => _SideColumn(
                    schemas: widget.schemas,
                    tree: widget.store.categories,
                    text: text,
                    type: _type,
                    category: _selected,
                    trash: _showTrash,
                    onAll: () => _filter(() {
                      _type = null;
                      _category = null;
                    }),
                    onType: (type) => _filter(() => _type = type),
                    onCategory: (id) => _filter(() => _category = id),
                    onTrash: () => unawaited(_openBeside(null, trash: true)),
                    actions: [
                      IconButton(
                        onPressed: _showPalette,
                        tooltip: CommandPalette.tooltip(l10n),
                        icon: const Icon(Icons.search),
                      ),
                      ..._actions(l10n, trash: false),
                    ],
                  ),
                ),
              ),
            ),
            if (_showTrash)
              Expanded(
                child: TrashScreen(
                  schemas: widget.schemas,
                  store: widget.store,
                ),
              )
            else ...[
              DecoratedBox(
                key: const ValueKey('pane-notes'),
                decoration: BoxDecoration(border: divider),
                child: SizedBox(
                  width: Extents.xl,
                  child: _noteColumn(context, l10n),
                ),
              ),
              Expanded(child: _openNote(l10n)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _noteColumn(BuildContext context, AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.m,
          Spacing.m,
          Spacing.m,
          Spacing.s,
        ),
        child: _searchField(l10n),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(_openBeside(_NewNote())),
                icon: const Icon(Icons.add),
                label: Text(l10n.newNote),
              ),
            ),
            IconButton(
              onPressed: _picks == null
                  ? () => setState(() => _picks = {})
                  : _endPicking,
              isSelected: _picks != null,
              tooltip: l10n.selectNotes,
              icon: const Icon(Icons.checklist),
            ),
          ],
        ),
      ),
      const SizedBox(height: Spacing.s),
      Expanded(
        child: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) {
            final shown = _shown();
            final picks = _picks;
            if (shown.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(Spacing.l),
                child: Text(
                  widget.store.entries.isEmpty
                      ? l10n.emptyLibrary
                      : l10n.noResults,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              );
            }
            final list = ListView.builder(
              padding: const EdgeInsets.only(bottom: Spacing.xxl),
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final entry = shown[index];
                return _NoteRow(
                  key: ValueKey('note-row-${entry.id.value}'),
                  entry: entry,
                  schema: _schemaOf(entry),
                  selected: entry.id == _opened,
                  picked: picks?.contains(entry.id),
                  onTap: () => _click(entry, shown),
                  onPick: () => _toggle(entry.id),
                  onLongPress: () => _file(entry),
                );
              },
            );
            if (picks == null) return list;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PickBar(
                  count: _pickedShown().length,
                  onEnd: _endPicking,
                  onAll: () => setState(
                    () => _picks = {...picks, for (final e in shown) e.id},
                  ),
                  onFile: () => unawaited(_filePicked()),
                  onTrash: () => unawaited(_trashPicked()),
                ),
                Expanded(child: list),
              ],
            );
          },
        ),
      ),
    ],
  );

  /// The note open beside the list, or a word on how to open one.
  Widget _openNote(AppLocalizations l10n) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final opened = _opened;
      DynamicEntry? entry;
      SchemaDefinition? schema;
      if (opened is EntryId) {
        entry = widget.store.entries
            .where((entry) => entry.id == opened)
            .firstOrNull;
        schema = entry == null ? null : _schemaOf(entry);
      } else if (opened is _NewNote) {
        schema = opened.schema ?? _type ?? widget.schemas.last;
      }
      if (schema == null) {
        return Center(
          child: Text(
            l10n.pickANote,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        );
      }
      return NoteEditorScreen(
        key: _editor,
        schemas: widget.schemas,
        store: widget.store,
        initialSchema: schema,
        entry: entry,
        category: _selected,
        onClose: () => setState(() {
          _opened = null;
          _editor = GlobalKey();
        }),
      );
    },
  );

  Widget _narrow(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.notesTitle), actions: _actions(l10n)),
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
          final shown = _shown();
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
                    _searchField(l10n),
                    if (!tree.isEmpty) ...[
                      const SizedBox(height: Spacing.s),
                      _CategoryBar(
                        tree: tree,
                        selected: selected,
                        onSelect: (id) => setState(() => _category = id),
                      ),
                    ],
                    const SizedBox(height: Spacing.m),
                    // One scrolling line: with a book's four types there
                    // are too many to wrap above the notes on a phone.
                    SingleChildScrollView(
                      key: const ValueKey('note-types'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        spacing: Spacing.s,
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

/// A new note not saved yet, open beside the list.
final class _NewNote {
  _NewNote([this.schema]);

  /// The type it starts as; null for the one the filters suggest.
  final SchemaDefinition? schema;
}

/// The first column: every note, each type, the categories as a tree, the
/// trash, and the vault's buttons at the foot.
class _SideColumn extends StatelessWidget {
  const _SideColumn({
    required this.schemas,
    required this.tree,
    required this.text,
    required this.type,
    required this.category,
    required this.trash,
    required this.onAll,
    required this.onType,
    required this.onCategory,
    required this.onTrash,
    required this.actions,
  });

  final List<SchemaDefinition> schemas;
  final CategoryTree tree;
  final SchemaText text;
  final SchemaDefinition? type;
  final CategoryId? category;
  final bool trash;
  final VoidCallback onAll;
  final ValueChanged<SchemaDefinition> onType;
  final ValueChanged<CategoryId> onCategory;
  final VoidCallback onTrash;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.l,
        Spacing.m,
        Spacing.l,
        Spacing.xs,
      ),
      child: Semantics(
        header: true,
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.l,
            Spacing.l,
            Spacing.l,
            Spacing.m,
          ),
          child: Semantics(
            header: true,
            child: Text(l10n.notesTitle, style: theme.textTheme.headlineSmall),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                key: const ValueKey('nav-all'),
                leading: const Icon(Icons.notes),
                title: Text(l10n.allNotes),
                selected: !trash && type == null && category == null,
                onTap: onAll,
              ),
              heading(l10n.noteType),
              for (final schema in schemas)
                ListTile(
                  key: ValueKey('nav-${schema.id.name}'),
                  leading: Icon(
                    NoteAppearance.icon(schema.icon),
                    color: NoteAppearance.tint(schema.tint),
                  ),
                  title: Text(text.label(schema.label)),
                  selected: !trash && type?.id == schema.id,
                  onTap: () => onType(schema),
                ),
              if (!tree.isEmpty) ...[
                heading(l10n.categories),
                for (final node in tree.ordered)
                  ListTile(
                    key: ValueKey('nav-category-${node.id.value}'),
                    contentPadding: EdgeInsetsDirectional.only(
                      start: Spacing.m * tree.depthOf(node.id),
                      end: Spacing.m,
                    ),
                    leading: Icon(
                      CategoryAppearance.icon(node.icon),
                      color: CategoryAppearance.tint(node.tint),
                    ),
                    title: Text(
                      node.name.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: !trash && category == node.id,
                    onTap: () => onCategory(node.id),
                  ),
              ],
              const Divider(),
              ListTile(
                key: const ValueKey('nav-trash'),
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.trash),
                selected: trash,
                onTap: onTrash,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(Spacing.s),
          child: Wrap(spacing: Spacing.xs, children: actions),
        ),
      ],
    );
  }
}

/// A note in the middle column: its type, title and date. A long press
/// files it in a category, as on a card.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.entry,
    required this.schema,
    required this.selected,
    required this.picked,
    required this.onTap,
    required this.onPick,
    required this.onLongPress,
    super.key,
  });

  final DynamicEntry entry;
  final SchemaDefinition? schema;
  final bool selected;

  /// Whether the note is picked; null while none are being picked.
  final bool? picked;
  final VoidCallback onTap;
  final VoidCallback onPick;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = NoteTitle.of(entry, schema);
    final picked = this.picked;
    return ListTile(
      leading: picked == null
          ? Icon(
              NoteAppearance.icon(schema?.icon),
              color: NoteAppearance.tint(schema?.tint),
            )
          : Checkbox(value: picked, onChanged: (_) => onPick()),
      title: Text(
        title.isEmpty ? l10n.untitled : title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        MaterialLocalizations.of(context)
            .formatMediumDate(entry.audit.updatedAt.toLocal()),
        maxLines: 1,
      ),
      selected: selected || (picked ?? false),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// Above the list while notes are being picked: how many, and what can be
/// done with them together.
class _PickBar extends StatelessWidget {
  const _PickBar({
    required this.count,
    required this.onEnd,
    required this.onAll,
    required this.onFile,
    required this.onTrash,
  });

  final int count;
  final VoidCallback onEnd;
  final VoidCallback onAll;
  final VoidCallback onFile;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final some = count > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('selection-clear'),
            onPressed: onEnd,
            tooltip: l10n.endPicking,
            icon: const Icon(Icons.close),
          ),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.notesPicked(count),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('selection-all'),
            onPressed: onAll,
            tooltip: l10n.pickAll,
            icon: const Icon(Icons.select_all),
          ),
          IconButton(
            key: const ValueKey('selection-file'),
            onPressed: some ? onFile : null,
            tooltip: l10n.fileNotes,
            icon: const Icon(Icons.drive_file_move_outline),
          ),
          IconButton(
            key: const ValueKey('selection-trash'),
            onPressed: some ? onTrash : null,
            tooltip: l10n.moveToTrash,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
