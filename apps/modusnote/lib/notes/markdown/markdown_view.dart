import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import 'markdown_document.dart';
import '../../theme/modus_palette.dart';

/// Shows a [MarkdownDocument] as Flutter widgets. Nothing is turned into
/// HTML, nothing is fetched and nothing can be tapped open: links show
/// their address beside the text, images show their alt text.
class MarkdownView extends StatelessWidget {
  const MarkdownView({required this.document, super.key});

  final MarkdownDocument document;

  @override
  Widget build(BuildContext context) =>
      SelectionArea(child: _Blocks(document.blocks));
}

class _Blocks extends StatelessWidget {
  const _Blocks(this.blocks);

  final List<MdBlock> blocks;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: Spacing.s,
    children: [for (final block in blocks) _block(context, block)],
  );

  Widget _block(BuildContext context, MdBlock block) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge!;
    return switch (block) {
      // Two heading sizes only: the type scale has no room for six.
      MdHeading(:final level, :final inlines) => _Inline(
        inlines,
        style: level == 1
            ? theme.textTheme.headlineSmall!
            : theme.textTheme.titleMedium!,
        heading: true,
      ),
      MdParagraph(:final inlines) => _Inline(inlines, style: body),
      MdList() => _ListView(block),
      MdQuote(:final blocks) => Container(
        padding: const EdgeInsets.only(left: Spacing.m),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: ModusPalette.of(context).violet,
              width: Spacing.xxs,
            ),
          ),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: ModusPalette.of(context).muted),
          child: _Blocks(blocks),
        ),
      ),
      MdCodeBlock(:final text) => Container(
        padding: const EdgeInsets.all(Spacing.m),
        decoration: BoxDecoration(
          color: ModusPalette.of(context).surface,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.small)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(text, style: body.copyWith(fontFamily: _monospace)),
        ),
      ),
      MdRule() => Divider(color: ModusPalette.of(context).muted),
    };
  }
}

/// No monospace font is bundled; the platform's own is used.
const _monospace = 'monospace';

class _ListView extends StatelessWidget {
  const _ListView(this.list);

  final MdList list;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.xs,
      children: [
        for (final (index, item) in list.items.indexed)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: Spacing.l,
                child: switch (item.checked) {
                  true => Icon(
                    Icons.check_box,
                    key: const ValueKey('task-done'),
                    size: IconSizes.inline,
                    color: ModusPalette.of(context).success,
                  ),
                  false => Icon(
                    Icons.check_box_outline_blank,
                    key: const ValueKey('task-open'),
                    size: IconSizes.inline,
                    color: ModusPalette.of(context).muted,
                  ),
                  null => Text(
                    list.ordered ? '${list.start + index}.' : '•',
                    style: body.copyWith(color: ModusPalette.of(context).muted),
                  ),
                },
              ),
              const SizedBox(width: Spacing.s),
              Expanded(child: _Blocks(item.blocks)),
            ],
          ),
      ],
    );
  }
}

class _Inline extends StatelessWidget {
  const _Inline(this.inlines, {required this.style, this.heading = false});

  final List<MdInline> inlines;
  final TextStyle style;
  final bool heading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final inherited = DefaultTextStyle.of(context).style.color;
    final base = inherited == null || heading
        ? style
        : style.copyWith(color: inherited);
    return Text.rich(
      TextSpan(
        style: base,
        children: _spans(inlines, base, l10n, ModusPalette.of(context)),
      ),
    );
  }

  static List<InlineSpan> _spans(
    List<MdInline> inlines,
    TextStyle style,
    AppLocalizations l10n,
    ModusPalette palette,
  ) => [
    for (final inline in inlines)
      switch (inline) {
        MdText(:final text) => TextSpan(text: text),
        MdCode(:final text) => TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: _monospace,
            backgroundColor: palette.surface,
          ),
        ),
        MdStrong(:final children) => TextSpan(
          style: _weight(style, FontWeight.w700),
          children: _spans(
            children,
            _weight(style, FontWeight.w700),
            l10n,
            palette,
          ),
        ),
        MdEmphasis(:final children) => TextSpan(
          style: const TextStyle(fontStyle: FontStyle.italic),
          children: _spans(children, style, l10n, palette),
        ),
        MdStrike(:final children) => TextSpan(
          style: const TextStyle(decoration: TextDecoration.lineThrough),
          children: _spans(children, style, l10n, palette),
        ),
        MdLink(:final children, :final url) => TextSpan(
          children: [
            TextSpan(
              style: const TextStyle(decoration: TextDecoration.underline),
              children: _spans(children, style, l10n, palette),
            ),
            if (url.isNotEmpty)
              TextSpan(
                text: ' ($url)',
                style: TextStyle(color: palette.muted),
              ),
          ],
        ),
        MdImage(:final alt) => TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                Icons.image_not_supported_outlined,
                size: IconSizes.inline,
                color: palette.muted,
                semanticLabel: l10n.markdownImage,
              ),
            ),
            TextSpan(
              text: alt.isEmpty ? '' : ' $alt',
              style: TextStyle(color: palette.muted),
            ),
          ],
        ),
      },
  ];

  /// The fonts are variable: the weight goes on the `wght` axis too.
  static TextStyle _weight(TextStyle style, FontWeight weight) =>
      style.copyWith(
        fontWeight: weight,
        fontVariations: [FontVariation.weight(weight.value.toDouble())],
      );
}
