import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/golden_ratio.dart';
import '../../theme/modus_colors.dart';
import '../../theme/modus_theme.dart';
import 'markdown_commands.dart';
import 'markdown_syntax.dart';

/// Markdown rendered as it is typed, in the field itself: the text being
/// edited stays the Markdown source, its markers dimmed and the rest drawn
/// as what it means (bold, headings, lists, code, links). Nothing is
/// parsed as HTML and nothing is fetched; a link is only coloured.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  String? _scanned;
  List<MdRun> _runs = const [];

  /// Applies a [MarkdownCommands] edit as if it were typed.
  void apply(TextEditingValue Function(TextEditingValue) command) {
    value = command(value);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!identical(_scanned, text)) {
      _runs = MarkdownSyntax.scan(text);
      _scanned = text;
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final base = style ?? const TextStyle();
    return TextSpan(
      style: style,
      children: [
        for (final run in _runs)
          for (final (start, end, underline) in _split(run, composing))
            TextSpan(
              text: text.substring(start, end),
              style: MarkdownStyles.of(base, run.marks, underline: underline),
            ),
      ],
    );
  }

  /// [run] cut where the text being composed by the keyboard starts and
  /// ends, so that stretch can be underlined as the platform expects.
  static Iterable<(int, int, bool)> _split(MdRun run, TextRange composing) {
    if (!composing.isValid ||
        composing.isCollapsed ||
        composing.end <= run.start ||
        composing.start >= run.end) {
      return [(run.start, run.end, false)];
    }
    final from = composing.start < run.start ? run.start : composing.start;
    final to = composing.end > run.end ? run.end : composing.end;
    return [
      if (from > run.start) (run.start, from, false),
      (from, to, true),
      if (to < run.end) (to, run.end, false),
    ];
  }
}

/// How each [MdMark] looks, on the app's colours and type scale.
abstract final class MarkdownStyles {
  static TextStyle of(TextStyle base, int marks, {bool underline = false}) {
    var style = base;
    bool has(int flag) => marks & flag != 0;
    if (has(MdMark.heading1) || has(MdMark.heading2)) {
      style = style.copyWith(
        fontFamily: ModusTheme.titleFont,
        fontSize: has(MdMark.heading1) ? TypeScale.title2 : base.fontSize,
        fontWeight: FontWeight.w700,
        fontVariations: const [FontVariation.weight(700)],
      );
    }
    if (has(MdMark.bold)) {
      style = style.copyWith(
        fontWeight: FontWeight.w700,
        fontVariations: const [FontVariation.weight(700)],
      );
    }
    if (has(MdMark.italic) || has(MdMark.quote)) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    if (has(MdMark.code)) {
      style = style.copyWith(
        fontFamily: 'monospace',
        backgroundColor: ModusColors.abyssalSlate,
      );
    }
    if (has(MdMark.link)) {
      style = style.copyWith(color: ModusColors.aureoGold);
    }
    final lines = <TextDecoration>[
      if (has(MdMark.strike) || has(MdMark.done)) TextDecoration.lineThrough,
      if (underline || has(MdMark.link)) TextDecoration.underline,
    ];
    if (lines.isNotEmpty) {
      style = style.copyWith(decoration: TextDecoration.combine(lines));
    }
    if (has(MdMark.done)) {
      style = style.copyWith(color: ModusColors.dustSilver);
    }
    if (has(MdMark.listMarker)) {
      style = style.copyWith(
        color: has(MdMark.done)
            ? ModusColors.cadenceCyan
            : ModusColors.aureoGold,
        decoration: TextDecoration.none,
      );
    } else if (has(MdMark.marker)) {
      style = style.copyWith(color: ModusColors.dustSilver);
    }
    return style;
  }
}

/// Turns the Enter typed in a list item, on any keyboard, into the next
/// item, or into the end of the list on an empty one.
final class MarkdownListFormatter extends TextInputFormatter {
  const MarkdownListFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final at = oldValue.selection;
    if (!at.isValid ||
        !at.isCollapsed ||
        newValue.text.length != oldValue.text.length + 1 ||
        newValue.selection.baseOffset != at.start + 1 ||
        newValue.text[at.start] != '\n' ||
        !newValue.text.startsWith(oldValue.text.substring(0, at.start)) ||
        !newValue.text.endsWith(oldValue.text.substring(at.start))) {
      return newValue;
    }
    return MarkdownCommands.newline(oldValue) ?? newValue;
  }
}
