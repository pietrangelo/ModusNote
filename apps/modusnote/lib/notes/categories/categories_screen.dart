import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../note_store.dart';
import 'category_dialog.dart';
import 'category_picker.dart';

/// The category tree, to create, rename, restyle, move and delete
/// categories. Deleting one never deletes notes: they move up.
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({required this.store, super.key});

  final NoteStore store;

  Future<void> _create(BuildContext context, {CategoryId? parent}) async {
    final created = await showCategoryDialog(context, parent: parent);
    if (created != null) await store.saveCategory(created);
  }

  Future<void> _edit(BuildContext context, NoteCategory category) async {
    final changed = await showCategoryDialog(context, existing: category);
    // Another device may have moved it while the dialog was open.
    final latest = store.categories[category.id];
    if (changed == null || latest == null) return;
    await store.saveCategory(
      latest
          .renamed(changed.name)
          .styled(icon: changed.icon, tint: changed.tint),
    );
  }

  Future<void> _move(BuildContext context, NoteCategory category) async {
    final tree = store.categories;
    final choice = await showCategoryPicker(
      context,
      tree: tree,
      current: tree.parentOf(category.id),
      moving: category.id,
    );
    if (choice == null) return;
    // The tree may have changed while the picker was open.
    final latest = store.categories[category.id];
    if (latest != null &&
        latest.parent != choice.id &&
        store.categories.canPlace(choice.id, moving: latest.id)) {
      await store.saveCategory(latest.movedTo(choice.id));
    }
  }

  Future<void> _delete(BuildContext context, NoteCategory category) async {
    final l10n = AppLocalizations.of(context);
    final tree = store.categories;
    final parent = switch (tree.parentOf(category.id)) {
      final id? => tree[id],
      null => null,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.folder_delete_outlined),
        title: Text(l10n.deleteCategoryTitle(category.name.value)),
        content: Text(
          parent == null
              ? l10n.deleteCategoryToTop
              : l10n.deleteCategoryInto(parent.name.value),
        ),
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
    if (confirmed ?? false) await store.deleteCategory(category.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tree = store.categories;
        final ordered = tree.ordered;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.categories)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _create(context),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: Text(l10n.newCategory),
          ),
          body: ordered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Text(
                      l10n.categoriesEmpty,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: Extents.xxl),
                    child: ListView(
                      padding: const EdgeInsets.only(
                        top: Spacing.s,
                        bottom: Spacing.xxl + Spacing.xl,
                      ),
                      children: [
                        for (final category in ordered)
                          _CategoryRow(
                            key: ValueKey(category.id),
                            category: category,
                            depth: tree.depthOf(category.id),
                            canNest: tree.canPlace(category.id),
                            onEdit: () => _edit(context, category),
                            onNest: () => _create(context, parent: category.id),
                            onMove: () => _move(context, category),
                            onDelete: () => _delete(context, category),
                          ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

enum _Action { nest, edit, move, delete }

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.depth,
    required this.canNest,
    required this.onEdit,
    required this.onNest,
    required this.onMove,
    required this.onDelete,
    super.key,
  });

  final NoteCategory category;
  final int depth;
  final bool canNest;
  final VoidCallback onEdit;
  final VoidCallback onNest;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsetsDirectional.only(
        start: Spacing.l * depth,
        end: Spacing.s,
      ),
      leading: Icon(
        CategoryAppearance.icon(category.icon),
        color: CategoryAppearance.tint(category.tint),
      ),
      title: Text(
        category.name.value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onEdit,
      trailing: PopupMenuButton<_Action>(
        onSelected: (action) => switch (action) {
          _Action.nest => onNest(),
          _Action.edit => onEdit(),
          _Action.move => onMove(),
          _Action.delete => onDelete(),
        },
        itemBuilder: (context) => [
          if (canNest)
            PopupMenuItem(
              value: _Action.nest,
              child: Text(l10n.newSubcategory),
            ),
          PopupMenuItem(value: _Action.edit, child: Text(l10n.editCategory)),
          PopupMenuItem(value: _Action.move, child: Text(l10n.moveCategory)),
          PopupMenuItem(value: _Action.delete, child: Text(l10n.delete)),
        ],
      ),
    );
  }
}
