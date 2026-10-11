/// A small Markdown reader for notes: headings, paragraphs, lists (with
/// task items), quotes, fenced code, rules, and the inline marks strong,
/// emphasis, strike, code, links and images.
///
/// It only builds a tree; [MarkdownView] turns the tree into widgets. No
/// HTML is ever produced or interpreted (raw tags stay text), link
/// addresses are kept as written and never resolved, and image addresses
/// are never fetched. Notes come from other members of a vault, so the
/// reader is also bounded: nesting stops at [MarkdownDocument.maxDepth]
/// and every scan moves forward, so the largest note parses in linear
/// time whatever it holds.
library;

final class MarkdownDocument {
  MarkdownDocument._(this.blocks);

  factory MarkdownDocument.parse(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    return MarkdownDocument._(List.unmodifiable(_Blocks(lines, 0).parse()));
  }

  /// Quotes and lists deeper than this, and marks nested deeper than this,
  /// are read as plain text.
  static const maxDepth = 8;

  final List<MdBlock> blocks;

  /// The words without the markup, one line per block: what a note card
  /// shows as its title.
  String get plainText {
    final lines = <String>[];
    void add(List<MdBlock> blocks) {
      for (final block in blocks) {
        switch (block) {
          case MdHeading(:final inlines) || MdParagraph(:final inlines):
            lines.add(_plain(inlines));
          case MdList(:final items):
            for (final item in items) {
              add(item.blocks);
            }
          case MdQuote(:final blocks):
            add(blocks);
          case MdCodeBlock(:final text):
            lines.add(text);
          case MdRule():
            break;
        }
      }
    }

    add(blocks);
    return lines.where((line) => line.isNotEmpty).join('\n');
  }

  static String _plain(List<MdInline> inlines) => inlines
      .map(
        (inline) => switch (inline) {
          MdText(:final text) || MdCode(:final text) => text,
          MdStrong(:final children) ||
          MdEmphasis(:final children) ||
          MdStrike(:final children) ||
          MdLink(:final children) => _plain(children),
          MdImage(:final alt) => alt,
        },
      )
      .join();
}

// ---------------------------------------------------------------- blocks

sealed class MdBlock {
  const MdBlock();
}

final class MdHeading extends MdBlock {
  MdHeading(this.level, List<MdInline> inlines)
    : inlines = List.unmodifiable(inlines);

  /// From 1 to 6.
  final int level;
  final List<MdInline> inlines;

  @override
  bool operator ==(Object other) =>
      other is MdHeading &&
      other.level == level &&
      _same(other.inlines, inlines);

  @override
  int get hashCode => Object.hash(level, Object.hashAll(inlines));

  @override
  String toString() => 'MdHeading($level, $inlines)';
}

final class MdParagraph extends MdBlock {
  MdParagraph(List<MdInline> inlines) : inlines = List.unmodifiable(inlines);

  final List<MdInline> inlines;

  @override
  bool operator ==(Object other) =>
      other is MdParagraph && _same(other.inlines, inlines);

  @override
  int get hashCode => Object.hashAll(inlines);

  @override
  String toString() => 'MdParagraph($inlines)';
}

final class MdList extends MdBlock {
  MdList({
    required this.ordered,
    required this.start,
    required List<MdListItem> items,
  }) : items = List.unmodifiable(items);

  final bool ordered;

  /// The number of the first item of an ordered list.
  final int start;
  final List<MdListItem> items;

  @override
  bool operator ==(Object other) =>
      other is MdList &&
      other.ordered == ordered &&
      other.start == start &&
      _same(other.items, items);

  @override
  int get hashCode => Object.hash(ordered, start, Object.hashAll(items));

  @override
  String toString() => 'MdList(ordered: $ordered, start: $start, $items)';
}

final class MdListItem {
  MdListItem(List<MdBlock> blocks, {this.checked})
    : blocks = List.unmodifiable(blocks);

  final List<MdBlock> blocks;

  /// Null for a plain item, true or false for a task item.
  final bool? checked;

  @override
  bool operator ==(Object other) =>
      other is MdListItem &&
      other.checked == checked &&
      _same(other.blocks, blocks);

  @override
  int get hashCode => Object.hash(checked, Object.hashAll(blocks));

  @override
  String toString() => 'MdListItem($checked, $blocks)';
}

final class MdQuote extends MdBlock {
  MdQuote(List<MdBlock> blocks) : blocks = List.unmodifiable(blocks);

  final List<MdBlock> blocks;

  @override
  bool operator ==(Object other) =>
      other is MdQuote && _same(other.blocks, blocks);

  @override
  int get hashCode => Object.hashAll(blocks);

  @override
  String toString() => 'MdQuote($blocks)';
}

final class MdCodeBlock extends MdBlock {
  const MdCodeBlock(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is MdCodeBlock && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'MdCodeBlock($text)';
}

final class MdRule extends MdBlock {
  const MdRule();

  @override
  bool operator ==(Object other) => other is MdRule;

  @override
  int get hashCode => (MdRule).hashCode;

  @override
  String toString() => 'MdRule()';
}

// --------------------------------------------------------------- inlines

sealed class MdInline {
  const MdInline();
}

final class MdText extends MdInline {
  const MdText(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is MdText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'MdText(${_quoted(text)})';
}

final class MdCode extends MdInline {
  const MdCode(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is MdCode && other.text == text;

  @override
  int get hashCode => Object.hash(MdCode, text);

  @override
  String toString() => 'MdCode(${_quoted(text)})';
}

final class MdStrong extends MdInline {
  MdStrong(List<MdInline> children) : children = List.unmodifiable(children);

  final List<MdInline> children;

  @override
  bool operator ==(Object other) =>
      other is MdStrong && _same(other.children, children);

  @override
  int get hashCode => Object.hash(MdStrong, Object.hashAll(children));

  @override
  String toString() => 'MdStrong($children)';
}

final class MdEmphasis extends MdInline {
  MdEmphasis(List<MdInline> children) : children = List.unmodifiable(children);

  final List<MdInline> children;

  @override
  bool operator ==(Object other) =>
      other is MdEmphasis && _same(other.children, children);

  @override
  int get hashCode => Object.hash(MdEmphasis, Object.hashAll(children));

  @override
  String toString() => 'MdEmphasis($children)';
}

final class MdStrike extends MdInline {
  MdStrike(List<MdInline> children) : children = List.unmodifiable(children);

  final List<MdInline> children;

  @override
  bool operator ==(Object other) =>
      other is MdStrike && _same(other.children, children);

  @override
  int get hashCode => Object.hash(MdStrike, Object.hashAll(children));

  @override
  String toString() => 'MdStrike($children)';
}

/// A link is shown with its address and is never opened by the app: a
/// note can come from another member, and a tap should not reach out.
final class MdLink extends MdInline {
  MdLink(List<MdInline> children, this.url)
    : children = List.unmodifiable(children);

  final List<MdInline> children;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is MdLink && other.url == url && _same(other.children, children);

  @override
  int get hashCode => Object.hash(url, Object.hashAll(children));

  @override
  String toString() => 'MdLink($children, ${_quoted(url)})';
}

/// Only the alt text is shown: fetching the image would tell its server
/// who opened the note, and when.
final class MdImage extends MdInline {
  const MdImage(this.alt, this.url);

  final String alt;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is MdImage && other.alt == alt && other.url == url;

  @override
  int get hashCode => Object.hash(alt, url);

  @override
  String toString() => 'MdImage(${_quoted(alt)}, ${_quoted(url)})';
}

bool _same<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _quoted(String text) => "'${text.replaceAll('\n', r'\n')}'";

// ---------------------------------------------------------- block reader

final _heading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*))?$');
final _closingHashes = RegExp(r'(?:^|[ \t]+)#+[ \t]*$');
final _rule = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _fence = RegExp(r'^( {0,3})(`{3,}|~{3,})');
final _quote = RegExp(r'^ {0,3}> ?');
final _item = RegExp(r'^( {0,3})([-*+]|(\d{1,9})[.)])([ \t]+|$)');
final _task = RegExp(r'^\[([ xX])\][ \t]+');

final class _Blocks {
  _Blocks(this._lines, this._depth);

  final List<String> _lines;
  final int _depth;
  var _at = 0;

  bool get _nests => _depth < MarkdownDocument.maxDepth;

  List<MdBlock> parse() {
    final blocks = <MdBlock>[];
    while (_at < _lines.length) {
      final line = _lines[_at];
      if (line.trim().isEmpty) {
        _at++;
      } else if (_fence.firstMatch(line) case final fence?) {
        blocks.add(_code(fence));
      } else if (_heading.firstMatch(line) case final heading?) {
        _at++;
        final text = (heading[2] ?? '').replaceFirst(_closingHashes, '');
        blocks.add(MdHeading(heading[1]!.length, _inlines(text.trim())));
      } else if (_rule.hasMatch(line)) {
        _at++;
        blocks.add(const MdRule());
      } else if (_nests && _quote.hasMatch(line)) {
        blocks.add(_quoteBlock());
      } else if (_nests && _item.hasMatch(line)) {
        blocks.add(_list());
      } else {
        blocks.add(_paragraph());
      }
    }
    return blocks;
  }

  List<MdInline> _inlines(String text) => _Inlines(text, _depth).parse();

  bool _interrupts(String line) =>
      _fence.hasMatch(line) ||
      _heading.hasMatch(line) ||
      _rule.hasMatch(line) ||
      (_nests && (_quote.hasMatch(line) || _item.hasMatch(line)));

  MdParagraph _paragraph() {
    final text = <String>[_lines[_at++].trim()];
    while (_at < _lines.length &&
        _lines[_at].trim().isNotEmpty &&
        !_interrupts(_lines[_at])) {
      text.add(_lines[_at++].trim());
    }
    return MdParagraph(_inlines(text.join('\n')));
  }

  MdCodeBlock _code(RegExpMatch fence) {
    final indent = fence[1]!.length;
    final marker = fence[2]!;
    _at++;
    final text = <String>[];
    while (_at < _lines.length) {
      final line = _lines[_at++];
      final trimmed = line.trim();
      if (trimmed.startsWith(marker) &&
          trimmed.replaceAll(marker[0], '').isEmpty) {
        break;
      }
      text.add(_dedent(line, indent));
    }
    return MdCodeBlock(text.join('\n'));
  }

  MdQuote _quoteBlock() {
    final inner = <String>[];
    while (_at < _lines.length) {
      final match = _quote.firstMatch(_lines[_at]);
      if (match == null) break;
      inner.add(_lines[_at++].substring(match.end));
    }
    return MdQuote(_Blocks(inner, _depth + 1).parse());
  }

  MdList _list() {
    final first = _item.firstMatch(_lines[_at])!;
    final ordered = first[3] != null;
    final start = ordered ? int.parse(first[3]!) : 1;
    final items = <MdListItem>[];
    while (_at < _lines.length) {
      final match = _item.firstMatch(_lines[_at]);
      if (match == null || (match[3] != null) != ordered) break;
      if (_rule.hasMatch(_lines[_at])) break;
      items.add(_listItem(match));
    }
    return MdList(ordered: ordered, start: start, items: items);
  }

  MdListItem _listItem(RegExpMatch match) {
    final spaces = match[4]!.length;
    // Content more than four spaces in is code in CommonMark; here it is
    // simply content one space after the marker.
    final indent = match[1]!.length + match[2]!.length + _clamp(spaces);
    var first = _lines[_at++].substring(match.end);
    bool? checked;
    if (_task.firstMatch(first) case final task?) {
      checked = task[1] != ' ';
      first = first.substring(task.end);
    }
    final inner = <String>[first];
    while (_at < _lines.length) {
      final line = _lines[_at];
      if (line.trim().isEmpty) {
        // A blank line stays in the item only if the item goes on.
        final next = _at + 1;
        if (next < _lines.length && _indentOf(_lines[next]) >= indent) {
          inner.add('');
          _at++;
          continue;
        }
        break;
      }
      if (_indentOf(line) < indent) break;
      inner.add(_dedent(line, indent));
      _at++;
    }
    return MdListItem(_Blocks(inner, _depth + 1).parse(), checked: checked);
  }

  static int _clamp(int spaces) => spaces == 0 || spaces > 4 ? 1 : spaces;

  static int _indentOf(String line) {
    var count = 0;
    while (count < line.length && line.codeUnitAt(count) == 0x20) {
      count++;
    }
    return count;
  }

  static String _dedent(String line, int indent) {
    final strip = _indentOf(line) < indent ? _indentOf(line) : indent;
    return line.substring(strip);
  }
}

// --------------------------------------------------------- inline reader

const _punctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

final class _Inlines {
  _Inlines(this._s, this._depth);

  final String _s;
  final int _depth;

  /// For each kind of closer and span end, the lowest position from which
  /// a search already found none: a later search from there or beyond, to
  /// the same end, cannot succeed, so it is skipped. This keeps unmatched
  /// openers linear.
  final _noCloserFrom = <String, int>{};

  List<MdInline> parse() => _span(0, _s.length, _depth);

  List<MdInline> _span(int start, int end, int depth) {
    if (depth >= MarkdownDocument.maxDepth) {
      return [if (start < end) MdText(_s.substring(start, end))];
    }
    final out = <MdInline>[];
    final text = StringBuffer();
    void emit(MdInline inline) {
      if (text.isNotEmpty) {
        out.add(MdText(text.toString()));
        text.clear();
      }
      out.add(inline);
    }

    var i = start;
    while (i < end) {
      final c = _s[i];
      if (c == r'\' && i + 1 < end && _punctuation.contains(_s[i + 1])) {
        text.write(_s[i + 1]);
        i += 2;
      } else if (c == '`') {
        final run = _runEnd(i, end);
        final close = _codeCloser(run, end, run - i);
        if (close == null) {
          text.write(_s.substring(i, run));
          i = run;
        } else {
          emit(MdCode(_trimCode(_s.substring(run, close))));
          i = close + (run - i);
        }
      } else if (c == '*' || c == '_' || c == '~') {
        final run = _runEnd(i, end);
        final mark = _mark(i, run, end, depth);
        if (mark == null) {
          text.write(_s.substring(i, run));
          i = run;
        } else {
          final (lead, inline, next) = mark;
          text.write(_s.substring(i, lead));
          emit(inline);
          i = next;
        }
      } else if (c == '[' || (c == '!' && i + 1 < end && _s[i + 1] == '[')) {
        final image = c == '!';
        final link = _link(image ? i + 1 : i, end);
        if (link == null) {
          text.write(c);
          i++;
        } else {
          final (textEnd, url, next) = link;
          final textStart = image ? i + 2 : i + 1;
          emit(
            image
                ? MdImage(_s.substring(textStart, textEnd), url)
                : MdLink(_span(textStart, textEnd, depth + 1), url),
          );
          i = next;
        }
      } else {
        text.write(c);
        i++;
      }
    }
    if (text.isNotEmpty) out.add(MdText(text.toString()));
    return out;
  }

  int _runEnd(int from, int end) {
    final c = _s.codeUnitAt(from);
    var i = from;
    while (i < end && _s.codeUnitAt(i) == c) {
      i++;
    }
    return i;
  }

  static String _trimCode(String code) =>
      code.length > 2 && code.startsWith(' ') && code.endsWith(' ')
      ? code.substring(1, code.length - 1)
      : code;

  /// Where a run of exactly [length] backticks starts after [from].
  int? _codeCloser(int from, int end, int length) {
    final kind = '`$length@$end';
    if (from >= (_noCloserFrom[kind] ?? end + 1)) return null;
    var at = from;
    while (true) {
      final found = _s.indexOf('`', at);
      if (found == -1 || found >= end) break;
      final run = _runEnd(found, end);
      if (run - found == length) return found;
      at = run;
    }
    _remember(kind, from);
    return null;
  }

  /// A strong, emphasis or strike span opened by the run [open, run):
  /// the position where literal text before the opener ends, the span,
  /// and where reading continues.
  (int, MdInline, int)? _mark(int open, int run, int end, int depth) {
    final c = _s[open];
    final length = run - open;
    if (run >= end || _isSpace(_s[run])) return null;
    if (c == '_' && open > 0 && _isWordy(_s[open - 1])) return null;
    final tries = c == '~' ? [if (length >= 2) 2] : [if (length >= 2) 2, 1];
    for (final width in tries) {
      // The opener is the last [width] marks of the run; any marks before
      // it are literal text.
      final lead = run - width;
      final close = _closer(c, width, run, end);
      if (close == null) continue;
      final children = _span(run, close, depth + 1);
      final inline = switch ((c, width)) {
        ('~', _) => MdStrike(children),
        (_, 2) => MdStrong(children),
        _ => MdEmphasis(children),
      };
      return (lead, inline, close + width);
    }
    return null;
  }

  /// The start of the closing marks for an opener of [width] marks [c]
  /// whose content starts at [from].
  int? _closer(String c, int width, int from, int end) {
    final kind = '$c$width@$end';
    if (from >= (_noCloserFrom[kind] ?? end + 1)) return null;
    var at = from;
    while (true) {
      final found = _s.indexOf(c, at);
      if (found == -1 || found >= end) break;
      final run = _runEnd(found, end);
      final length = run - found;
      final fits = width == 2 ? length >= 2 : length != 2;
      final close = run - width;
      if (fits &&
          close > from &&
          !_isSpace(_s[found - 1]) &&
          !(c == '_' && run < end && _isWordy(_s[run]))) {
        return close;
      }
      at = run;
    }
    _remember(kind, from);
    return null;
  }

  /// `]` then `(` then `)`, with no line break in the address.
  (int, String, int)? _link(int open, int end) {
    final textEnd = _find(']', open + 1, end);
    if (textEnd == null) return null;
    if (textEnd + 1 >= end || _s[textEnd + 1] != '(') return null;
    final urlEnd = _find(')', textEnd + 2, end);
    if (urlEnd == null) return null;
    final url = _s.substring(textEnd + 2, urlEnd);
    if (url.contains('\n')) return null;
    return (textEnd, url.trim(), urlEnd + 1);
  }

  int? _find(String c, int from, int end) {
    final kind = '$c@$end';
    if (from >= (_noCloserFrom[kind] ?? end + 1)) return null;
    final found = _s.indexOf(c, from);
    if (found == -1 || found >= end) {
      _remember(kind, from);
      return null;
    }
    return found;
  }

  void _remember(String kind, int from) {
    final known = _noCloserFrom[kind];
    if (known == null || from < known) _noCloserFrom[kind] = from;
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == ' ';

  static bool _isWordy(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        code > 0x7F;
  }
}
