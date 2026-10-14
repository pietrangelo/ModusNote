import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../theme/golden_ratio.dart';
import '../../theme/modus_colors.dart';
import '../../theme/modus_theme.dart';
import 'markdown_commands.dart';
import 'markdown_syntax.dart';

/// Markdown rendered as it is typed, in the field itself: the text being
/// edited stays the Markdown source, its markers dimmed and the rest drawn
/// as what it means (bold, headings, lists, code, links). Nothing is
/// parsed as HTML and nothing is fetched; a link is only coloured.
///
/// A picture written in the text ([InlineImages]) is drawn where it sits
/// by [pictureBuilder], in place of its Markdown, until the cursor goes
/// into that Markdown to edit it. Each character of the reference stays
/// in the text: the `!` carries the picture and the rest takes no room,
/// so offsets, selection and what is saved are the source as typed.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  String? _scanned;
  List<MdRun> _runs = const [];
  List<InlineImage> _pictures = const [];

  /// The most pictures drawn in one text, as many as a page can attach.
  static const maxPictures = 34;

  /// Draws a picture of the text; null where pictures cannot be shown,
  /// which leaves their Markdown as it is.
  Widget Function(InlineImage picture)? pictureBuilder;

  /// Whether the field has the keyboard: only then does the cursor open a
  /// picture's Markdown.
  bool get editing => _editing;
  bool _editing = false;
  set editing(bool editing) {
    if (editing == _editing) return;
    _editing = editing;
    notifyListeners();
  }

  /// The pictures shown as pictures: all but the one being edited.
  List<InlineImage> _shown() {
    if (pictureBuilder == null) return const [];
    final selection = value.selection;
    if (!_editing || !selection.isValid) return _pictures;
    return [
      for (final picture in _pictures)
        if (selection.start >= picture.end ||
            selection.end <= picture.start ||
            (selection.isCollapsed && selection.start == picture.start))
          picture,
    ];
  }

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
      // Every picture drawn is decrypted and held in memory: a text with
      // more, crafted or pasted, shows the rest as Markdown.
      _pictures = InlineImages.find(text).take(maxPictures).toList();
      _scanned = text;
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final base = style ?? const TextStyle();
    final shown = _shown();
    final builder = pictureBuilder;
    final children = <InlineSpan>[];
    var next = 0;
    for (final run in _runs) {
      for (final (start, end, underline) in _split(run, composing)) {
        TextSpan piece(int from, int to) => TextSpan(
          text: text.substring(from, to),
          style: MarkdownStyles.of(base, run.marks, underline: underline),
        );
        var from = start;
        while (from < end) {
          while (next < shown.length && shown[next].end <= from) {
            next++;
          }
          if (builder == null ||
              next == shown.length ||
              shown[next].start >= end) {
            children.add(piece(from, end));
            break;
          }
          final picture = shown[next];
          if (from < picture.start) {
            children.add(piece(from, picture.start));
            from = picture.start;
          }
          final to = end < picture.end ? end : picture.end;
          for (var at = from; at < to; at++) {
            children.add(
              at == picture.start
                  ? WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: builder(picture),
                    )
                  : _nothing,
            );
          }
          from = to;
        }
      }
    }
    return TextSpan(style: style, children: children);
  }

  /// A character of a picture's Markdown while the picture is shown.
  static const _nothing = WidgetSpan(child: SizedBox.shrink());

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
