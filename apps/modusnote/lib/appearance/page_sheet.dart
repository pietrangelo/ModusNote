import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import 'appearance_scope.dart';
import 'page_appearance.dart';

/// The «Aa» sheet of the editor: text size and, on a wide window, page
/// width. A change shows on the page behind it at once.
class PageAppearanceSheet extends StatelessWidget {
  const PageAppearanceSheet({required this.settings, super.key});

  final AppearanceSettings settings;

  /// Shows the sheet for the settings above [context]; nothing without a
  /// scope.
  static Future<void> show(BuildContext context) async {
    final settings = AppearanceScope.maybeOf(context);
    if (settings == null) return;
    final wide = MediaQuery.sizeOf(context).width >= PageAppearance.wideFrom;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // The page stays visible behind the sheet, to see the change.
      barrierColor: Colors.transparent,
      // The golden share of the window at most, so the page stays in sight.
      constraints: BoxConstraints(
        maxWidth: wide ? Extents.xxl : double.infinity,
        maxHeight: MediaQuery.sizeOf(context).height * LayoutSplit.primary,
      ),
      builder: (_) => PageAppearanceSheet(settings: settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= PageAppearance.wideFrom;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final page = settings.page;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.pageAppearance, style: theme.textTheme.titleLarge),
                const SizedBox(height: Spacing.xs),
                Text(
                  l10n.pageAppearanceDevice,
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: Spacing.l),
                Text(l10n.pageTextSize, style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.s),
                SegmentedButton<int>(
                  key: const ValueKey('page-text-size'),
                  showSelectedIcon: false,
                  segments: [
                    for (final (step, size) in PageAppearance.textSizes.indexed)
                      ButtonSegment(
                        value: step,
                        label: Text(
                          l10n.pageTextSizeValue(size.round()),
                          key: ValueKey('page-text-size-${size.round()}'),
                        ),
                      ),
                  ],
                  selected: {page.textStep},
                  onSelectionChanged: (chosen) =>
                      settings.page = page.copyWith(textStep: chosen.single),
                ),
                const SizedBox(height: Spacing.l),
                Text(l10n.pageFont, style: theme.textTheme.titleMedium),
                RadioGroup<PageFont>(
                  groupValue: page.font,
                  onChanged: (font) {
                    if (font != null) settings.page = page.copyWith(font: font);
                  },
                  child: Column(
                    children: [
                      for (final font in PageFont.values)
                        RadioListTile<PageFont>(
                          key: ValueKey('page-font-${font.name}'),
                          value: font,
                          contentPadding: EdgeInsets.zero,
                          title: Text(switch (font) {
                            PageFont.inter => l10n.pageFontInter,
                            PageFont.literata => l10n.pageFontLiterata,
                            PageFont.atkinson => l10n.pageFontAtkinson,
                            PageFont.quattro => l10n.pageFontQuattro,
                          }),
                          subtitle: Text(switch (font) {
                            PageFont.inter => l10n.pageFontInterHint,
                            PageFont.literata => l10n.pageFontLiterataHint,
                            PageFont.atkinson => l10n.pageFontAtkinsonHint,
                            PageFont.quattro => l10n.pageFontQuattroHint,
                          }),
                        ),
                    ],
                  ),
                ),
                if (wide) ...[
                  const SizedBox(height: Spacing.l),
                  Text(l10n.pageWidth, style: theme.textTheme.titleMedium),
                  const SizedBox(height: Spacing.s),
                  SegmentedButton<PageWidth>(
                    key: const ValueKey('page-width'),
                    showSelectedIcon: false,
                    segments: [
                      for (final width in PageWidth.values)
                        ButtonSegment(
                          value: width,
                          label: Text(switch (width) {
                            PageWidth.narrow => l10n.pageWidthNarrow,
                            PageWidth.medium => l10n.pageWidthMedium,
                            PageWidth.wide => l10n.pageWidthWide,
                            PageWidth.full => l10n.pageWidthFull,
                          }, key: ValueKey('page-width-${width.name}')),
                        ),
                    ],
                    selected: {page.width},
                    onSelectionChanged: (chosen) =>
                        settings.page = page.copyWith(width: chosen.single),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
