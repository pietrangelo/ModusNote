import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../random_id.dart';

/// Asks for a category's name, icon and colour. Returns the new or changed
/// category, or null when the person cancels. [parent] places a new one;
/// an existing one keeps its own.
Future<NoteCategory?> showCategoryDialog(
  BuildContext context, {
  NoteCategory? existing,
  CategoryId? parent,
}) => showDialog<NoteCategory>(
  context: context,
  builder: (_) => _CategoryDialog(existing: existing, parent: parent),
);

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.existing, required this.parent});

  final NoteCategory? existing;
  final CategoryId? parent;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _name = TextEditingController(
    text: widget.existing?.name.value ?? '',
  );
  late NoteIcon? _icon = widget.existing?.icon;
  late NoteTint? _tint = widget.existing?.tint;
  var _invalid = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final CategoryName name;
    try {
      name = CategoryName(_name.text);
    } on InvalidValueException {
      setState(() => _invalid = true);
      return;
    }
    final existing = widget.existing;
    Navigator.of(context).pop(
      existing == null
          ? NoteCategory(
              id: CategoryId(randomRecordId()),
              name: name,
              parent: widget.parent,
              icon: _icon,
              tint: _tint,
            )
          : existing.renamed(name).styled(icon: _icon, tint: _tint),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tint = CategoryAppearance.tint(_tint);
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? (widget.parent == null ? l10n.newCategory : l10n.newSubcategory)
            : l10n.editCategory,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('category-name'),
              controller: _name,
              autofocus: widget.existing == null,
              maxLength: CategoryName.maxLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.categoryName,
                errorText: _invalid ? l10n.categoryNameInvalid : null,
                errorMaxLines: 2,
              ),
              onChanged: (_) {
                if (_invalid) setState(() => _invalid = false);
              },
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: Spacing.m),
            Text(l10n.categoryIcon, style: theme.textTheme.labelMedium),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.xxs,
              runSpacing: Spacing.xxs,
              children: [
                for (final icon in <NoteIcon?>[null, ...NoteIcon.values])
                  IconButton(
                    isSelected: icon == _icon,
                    tooltip: _iconName(l10n, icon),
                    onPressed: () => setState(() => _icon = icon),
                    color: icon == _icon ? tint : null,
                    style: IconButton.styleFrom(
                      backgroundColor: icon == _icon
                          ? theme.colorScheme.surfaceContainerHighest
                          : null,
                    ),
                    icon: Icon(CategoryAppearance.icon(icon)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.m),
            Text(l10n.categoryColour, style: theme.textTheme.labelMedium),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.xxs,
              runSpacing: Spacing.xxs,
              children: [
                for (final choice in <NoteTint?>[null, ...NoteTint.values])
                  IconButton(
                    isSelected: choice == _tint,
                    tooltip: _tintName(l10n, choice),
                    onPressed: () => setState(() => _tint = choice),
                    color: CategoryAppearance.tint(choice),
                    icon: Icon(
                      choice == _tint ? Icons.check_circle : Icons.circle,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.categorySave)),
      ],
    );
  }

  static String _iconName(AppLocalizations l10n, NoteIcon? icon) =>
      switch (icon) {
        null => l10n.iconFolder,
        NoteIcon.note => l10n.iconNote,
        NoteIcon.music => l10n.iconMusic,
        NoteIcon.moon => l10n.iconMoon,
        NoteIcon.checklist => l10n.iconChecklist,
        NoteIcon.star => l10n.iconStar,
        NoteIcon.lightbulb => l10n.iconLightbulb,
        NoteIcon.book => l10n.iconBook,
        NoteIcon.heart => l10n.iconHeart,
      };

  static String _tintName(AppLocalizations l10n, NoteTint? tint) =>
      switch (tint) {
        null => l10n.tintNone,
        NoteTint.gold => l10n.tintGold,
        NoteTint.violet => l10n.tintViolet,
        NoteTint.cyan => l10n.tintCyan,
        NoteTint.rose => l10n.tintRose,
      };
}
