import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// The formatting a Markdown field offers, as edits of the text being
/// written: the toolbar and the keyboard shortcuts both call these. Each
/// one returns the new text and selection, and leaves an invalid
/// selection alone. All of them run in time linear in the text.
abstract final class MarkdownCommands {
  static TextEditingValue bold(TextEditingValue value) => _wrap(value, '**');

  static TextEditingValue italic(TextEditingValue value) => _wrap(value, '_');

  static TextEditingValue strike(TextEditingValue value) => _wrap(value, '~~');

  static TextEditingValue code(TextEditingValue value) => _wrap(value, '`');

  static TextEditingValue bullets(TextEditingValue value) =>
      _prefixLines(value, (_) => '- ', (prefix) => prefix == '- ');

  static TextEditingValue numbered(TextEditingValue value) => _prefixLines(
    value,
    (index) => '${index + 1}. ',
    (prefix) => _number.hasMatch(prefix),
  );

  static TextEditingValue tasks(TextEditingValue value) =>
      _prefixLines(value, (_) => '- [ ] ', (prefix) => _task.hasMatch(prefix));

  static TextEditingValue quote(TextEditingValue value) =>
      _prefixLines(value, (_) => '> ', (prefix) => prefix == '> ');

  /// No heading, then `#`, `##`, `###`, then none again, on every line.
  static TextEditingValue heading(TextEditingValue value) {
    if (!_valid(value)) return value;
    final level = _headingLevel(_lineAt(value.text, value.selection.start));
    final next = level >= 3 ? '' : '${'#' * (level + 1)} ';
    return _mapLines(value, (index, line) {
      final current = _headingLevel(line);
      return (drop: current == 0 ? 0 : current + 1, add: next);
    });
  }

  /// `[selection](https://)` with the address selected, ready to type.
  static TextEditingValue link(TextEditingValue value) {
    if (!_valid(value)) return value;
    final selection = value.selection;
    final label = selection.textInside(value.text);
    const address = 'https://';
    final before = '${selection.textBefore(value.text)}[$label](';
    return TextEditingValue(
      text: '$before$address)${selection.textAfter(value.text)}',
      selection: TextSelection(
        baseOffset: before.length,
        extentOffset: before.length + address.length,
      ),
    );
  }

  /// A link to note [target] in place of the selection, reading the
  /// selected words or, with none, the note's [title]; the cursor goes
  /// after it.
  static TextEditingValue noteLink(
    TextEditingValue value, {
    required String title,
    required EntryId target,
  }) {
    if (!_valid(value)) return value;
    final selection = value.selection;
    final selected = selection.textInside(value.text);
    final link = NoteLinks.markdown(
      selected.trim().isEmpty ? title : selected,
      target,
    );
    final before = '${selection.textBefore(value.text)}$link';
    return TextEditingValue(
      text: '$before${selection.textAfter(value.text)}',
      selection: TextSelection.collapsed(offset: before.length),
    );
  }

  /// Fences the lines the selection touches as a code block.
  static TextEditingValue codeBlock(TextEditingValue value) {
    if (!_valid(value)) return value;
    final text = value.text;
    final (start, end) = _lineSpan(text, value.selection);
    const fence = '```\n';
    return TextEditingValue(
      text:
          '${text.substring(0, start)}$fence${text.substring(start, end)}'
          '\n```${text.substring(end)}',
      selection: TextSelection(
        baseOffset: value.selection.start + fence.length,
        extentOffset: value.selection.end + fence.length,
      ),
    );
  }

  /// A horizontal rule on a line of its own after the cursor.
  static TextEditingValue rule(TextEditingValue value) {
    if (!_valid(value)) return value;
    final at = value.selection.end;
    final text = value.text;
    final lead = at == 0 || text[at - 1] == '\n' ? '' : '\n\n';
    final inserted = '$lead---\n';
    return TextEditingValue(
      text: '${text.substring(0, at)}$inserted${text.substring(at)}',
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }

  /// Enter inside a list item or a quote: the next line starts with the
  /// same marker (numbers count on, tasks start unchecked); on an item with
  /// nothing after its marker the marker goes and the list ends. Null when
  /// the cursor is not in one, so Enter does what it always does.
  static TextEditingValue? newline(TextEditingValue value) {
    if (!_valid(value) || !value.selection.isCollapsed) return null;
    final text = value.text;
    final at = value.selection.start;
    final lineStart = _lineStart(text, at);
    final marker = _marker.matchAsPrefix(text.substring(lineStart, at));
    if (marker == null) return null;
    final whole = marker.group(0)!;
    final lineEnd = _lineEnd(text, at);
    if (lineStart + whole.length == lineEnd) {
      // An empty item: the list ends here.
      return TextEditingValue(
        text: text.substring(0, lineStart) + text.substring(lineEnd),
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final indent = marker.group(1)!;
    final kind = marker.group(2)!;
    final next = switch (_number.matchAsPrefix(kind)) {
      final number? => '${int.parse(number.group(1)!) + 1}${number.group(2)!} ',
      null when _task.hasMatch(kind) => '- [ ] ',
      null => kind,
    };
    final inserted = '\n$indent$next';
    return TextEditingValue(
      text: text.substring(0, at) + inserted + text.substring(at),
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }

  /// Indent, then one of: a task, a bullet, a number, a quote.
  static final _marker = RegExp(
    r'([ \t]{0,8})(- \[[ xX]\] |[-*+] |\d{1,9}[.)] |> )',
  );
  static final _number = RegExp(r'(\d{1,9})([.)]) $');
  static final _task = RegExp(r'^- \[[ xX]\] $');
  static final _anyPrefix = RegExp(r'(- \[[ xX]\] |[-*+] |\d{1,9}[.)] |> )');

  static bool _valid(TextEditingValue value) {
    final selection = value.selection;
    return selection.isValid &&
        selection.start >= 0 &&
        selection.end <= value.text.length;
  }

  static TextEditingValue _wrap(TextEditingValue value, String mark) {
    if (!_valid(value)) return value;
    final text = value.text;
    final selection = value.selection;
    final inside = selection.textInside(text);
    final before = selection.textBefore(text);
    final after = selection.textAfter(text);
    // Marks just outside the selection: take them away.
    if (before.endsWith(mark) && after.startsWith(mark)) {
      final start = selection.start - mark.length;
      return TextEditingValue(
        text:
            before.substring(0, before.length - mark.length) +
            inside +
            after.substring(mark.length),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + inside.length,
        ),
      );
    }
    // Marks inside the selection, selected with it: take them away too.
    if (inside.length >= 2 * mark.length &&
        inside.startsWith(mark) &&
        inside.endsWith(mark)) {
      final bare = inside.substring(mark.length, inside.length - mark.length);
      return TextEditingValue(
        text: before + bare + after,
        selection: TextSelection(
          baseOffset: selection.start,
          extentOffset: selection.start + bare.length,
        ),
      );
    }
    final start = selection.start + mark.length;
    return TextEditingValue(
      text: '$before$mark$inside$mark$after',
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + inside.length,
      ),
    );
  }

  /// Gives every line the selection touches the prefix [prefixFor], or
  /// takes it away when all of them already have the kind [isKind].
  /// Another list or quote marker on a line is replaced.
  static TextEditingValue _prefixLines(
    TextEditingValue value,
    String Function(int index) prefixFor,
    bool Function(String prefix) isKind,
  ) {
    if (!_valid(value)) return value;
    final (start, end) = _lineSpan(value.text, value.selection);
    final lines = value.text.substring(start, end).split('\n');
    final removing = lines.every(
      (line) => isKind(_anyPrefix.matchAsPrefix(line)?.group(0) ?? ''),
    );
    return _mapLines(value, (index, line) {
      final current = _anyPrefix.matchAsPrefix(line)?.group(0) ?? '';
      return (drop: current.length, add: removing ? '' : prefixFor(index));
    });
  }

  /// Rewrites the start of each line the selection touches: [edit] says
  /// how many characters to drop there and what to put in their place.
  /// The selection moves with the text it was on.
  static TextEditingValue _mapLines(
    TextEditingValue value,
    ({int drop, String add}) Function(int index, String line) edit,
  ) {
    final text = value.text;
    final selection = value.selection;
    final (start, end) = _lineSpan(text, selection);
    final out = StringBuffer(text.substring(0, start));
    final lines = <({int from, int to, int at, int drop, int add})>[];
    var lineStart = start;
    for (var index = 0; ; index++) {
      final lineEnd = _lineEnd(text, lineStart);
      final line = text.substring(lineStart, lineEnd);
      final change = edit(index, line);
      final drop = change.drop > line.length ? line.length : change.drop;
      lines.add((
        from: lineStart,
        to: lineEnd,
        at: out.length,
        drop: drop,
        add: change.add.length,
      ));
      out
        ..write(change.add)
        ..write(line.substring(drop));
      if (lineEnd >= end) break;
      out.write('\n');
      lineStart = lineEnd + 1;
    }
    final shift = out.length - end;
    out.write(text.substring(end));

    // The selection moves with the text it was on.
    int moved(int offset) {
      if (offset < start) return offset;
      if (offset > end) return offset + shift;
      for (final line in lines) {
        if (offset <= line.to) {
          final within = offset - line.from;
          return line.at +
              line.add +
              (within < line.drop ? 0 : within - line.drop);
        }
      }
      return offset + shift;
    }

    return TextEditingValue(
      text: out.toString(),
      selection: TextSelection(
        baseOffset: moved(selection.baseOffset),
        extentOffset: moved(selection.extentOffset),
      ),
    );
  }

  /// From the start of the selection's first line to the end of its last.
  static (int, int) _lineSpan(String text, TextSelection selection) =>
      (_lineStart(text, selection.start), _lineEnd(text, selection.end));

  static int _lineStart(String text, int offset) =>
      offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

  static int _lineEnd(String text, int from) {
    final end = text.indexOf('\n', from);
    return end < 0 ? text.length : end;
  }

  static String _lineAt(String text, int offset) =>
      text.substring(_lineStart(text, offset), _lineEnd(text, offset));

  static int _headingLevel(String line) {
    var level = 0;
    while (level < line.length && level < 6 && line[level] == '#') {
      level++;
    }
    return level > 0 && level < line.length && line[level] == ' ' ? level : 0;
  }
}
