import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../../theme/modus_palette.dart';

/// What the person picked: a category, or none ([id] null). A dismissed
/// picker returns null instead of a choice.
typedef CategoryChoice = ({CategoryId? id});

/// Lets the person pick where a note goes, or ([moving] set) where a
/// category goes: only the places [CategoryTree.canPlace] allows are
/// offered. [current] is marked.
Future<CategoryChoice?> showCategoryPicker(
  BuildContext context, {
  required CategoryTree tree,
  required CategoryId? current,
  CategoryId? moving,
}) {
  final l10n = AppLocalizations.of(context);
  final places = [
    for (final category in tree.ordered)
      if (moving == null || tree.canPlace(category.id, moving: moving))
        category,
  ];
  return showModalBottomSheet<CategoryChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      Widget row({
        required CategoryId? id,
        required IconData icon,
        required Color? color,
        required String label,
        int depth = 1,
      }) => ListTile(
        key: ValueKey('pick-${id?.value ?? 'none'}'),
        contentPadding: EdgeInsetsDirectional.only(
          start: Spacing.l * depth,
          end: Spacing.l,
        ),
        leading: Icon(icon, color: color),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: id == current ? const Icon(Icons.check) : null,
        onTap: () => Navigator.of(context).pop((id: id)),
      );

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * LayoutSplit.primary,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.l,
                  0,
                  Spacing.l,
                  Spacing.s,
                ),
                child: Text(
                  moving == null ? l10n.fileNote : l10n.moveCategory,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              row(
                id: null,
                icon: moving == null ? Icons.folder_off_outlined : Icons.home,
                color: null,
                label: moving == null ? l10n.noCategory : l10n.topLevel,
              ),
              for (final category in places)
                row(
                  id: category.id,
                  icon: CategoryAppearance.icon(category.icon),
                  color: ModusPalette.of(context).tint(category.tint),
                  label: category.name.value,
                  depth: tree.depthOf(category.id),
                ),
            ],
          ),
        ),
      );
    },
  );
}
