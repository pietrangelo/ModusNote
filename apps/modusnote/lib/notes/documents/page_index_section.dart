import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../note_appearance.dart';
import '../note_title.dart';
import 'page_index.dart';

/// Under a document page: the index of its manual, one section per
/// category, the open page marked, every other page one tap away, and a
/// button to write a new page in this page's category.
class PageIndexSection extends StatelessWidget {
  const PageIndexSection({
    required this.sections,
    required this.current,
    required this.schemaOf,
    required this.onOpen,
    required this.onAdd,
    super.key,
  });

  /// Null when the page is in no category.
  final List<IndexSection>? sections;

  /// The page open in the editor.
  final EntryId current;
  final SchemaDefinition? Function(DynamicEntry) schemaOf;
  final ValueChanged<DynamicEntry> onOpen;

  /// Writes a new page in the open page's category.
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sections = this.sections;
    if (sections == null) {
      return Padding(
        padding: const EdgeInsets.only(top: Spacing.l),
        child: Text(
          l10n.pageIndexNotFiled,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final indents = [0.0, Spacing.l, Spacing.xl, Spacing.xxl];
    double indent(int level) => indents[level.clamp(0, indents.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
          child: Text(l10n.pageIndex, style: theme.textTheme.labelMedium),
        ),
        for (final section in sections) ...[
          if (section.level > 0)
            Padding(
              key: ValueKey('index-section-${section.category.id.value}'),
              padding: EdgeInsetsDirectional.only(
                start: indent(section.level - 1),
                top: Spacing.s,
              ),
              child: Row(
                children: [
                  Icon(
                    CategoryAppearance.icon(section.category.icon),
                    size: IconSizes.inline,
                    color: CategoryAppearance.tint(section.category.tint),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: Text(
                      section.category.name.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
          for (final page in section.pages)
            _row(context, page, indent(section.level)),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: IconSizes.inline),
            label: Text(l10n.addPage),
            onPressed: onAdd,
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, DynamicEntry page, double start) {
    final l10n = AppLocalizations.of(context);
    final schema = schemaOf(page);
    final title = NoteTitle.of(page, schema);
    final open = page.id == current;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: start),
      child: ListTile(
        key: ValueKey('index-${page.id.value}'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        selected: open,
        leading: Icon(
          NoteAppearance.icon(schema?.icon),
          color: open ? null : NoteAppearance.tint(schema?.tint),
        ),
        title: Text(
          title.isEmpty ? l10n.untitled : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: open ? null : () => onOpen(page),
      ),
    );
  }
}
