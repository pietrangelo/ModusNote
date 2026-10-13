import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

/// What a stretch of Markdown source is, for styling it while it is
/// written. Flags combine: bold inside a heading is both.
abstract final class MdMark {
  /// Syntax rather than content: `**`, `# `, `- [ ] `, a fence.
  static const marker = 1 << 0;
  static const bold = 1 << 1;
  static const italic = 1 << 2;
  static const strike = 1 << 3;
  static const code = 1 << 4;
  static const link = 1 << 5;
  static const url = 1 << 6;
  static const heading1 = 1 << 7;
  static const heading2 = 1 << 8;
  static const quote = 1 << 9;

  /// A task that is ticked off.
  static const done = 1 << 10;

  /// The bullet, number or box that starts a list item.
  static const listMarker = 1 << 11;
  static const rule = 1 << 12;
}

/// A run of source text with the same [MdMark] flags.
@immutable
final class MdRun {
  const MdRun(this.start, this.end, this.marks);

  final int start;
  final int end;
  final int marks;

  @override
  bool operator ==(Object other) =>
      other is MdRun &&
      other.start == start &&
      other.end == end &&
      other.marks == marks;

  @override
  int get hashCode => Object.hash(start, end, marks);

  @override
  String toString() => 'MdRun($start, $end, $marks)';
}

/// Reads Markdown source into styled runs, the way the editor shows it as
/// it is typed: the source stays the text being edited, markers dimmed,
/// the rest drawn as what it means. It follows the same constructs as
/// `MarkdownDocument`, line by line, and never looks back: every search
/// for a closing mark is remembered, so the whole text is read in linear
/// time whatever it contains.
abstract final class MarkdownSyntax {
  static List<MdRun> scan(String text) {
    final marks = Uint16List(text.length);
    var inFence = false;
    var lineStart = 0;
    while (lineStart <= text.length) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = text.length;
      inFence = _line(text, marks, lineStart, lineEnd, inFence: inFence);
      lineStart = lineEnd + 1;
    }
    return _runs(marks);
  }

  static final _fence = RegExp(r' {0,3}```');
  static final _heading = RegExp(r' {0,3}(#{1,6}) ');
  static final _rule = RegExp(r' {0,3}([-*_])( {0,2}\1){2,} *$');
  static final _quote = RegExp(r' {0,3}> ?');
  static final _item = RegExp(
    r'[ \t]{0,8}([-*+] |\d{1,9}[.)] )(\[([ xX])\] )?',
  );

  /// Styles one line and says whether a code fence is open after it.
  static bool _line(
    String text,
    Uint16List marks,
    int start,
    int end, {
    required bool inFence,
  }) {
    final line = text.substring(start, end);
    if (_fence.matchAsPrefix(line) != null) {
      _mark(marks, start, end, MdMark.marker | MdMark.code);
      return !inFence;
    }
    if (inFence) {
      _mark(marks, start, end, MdMark.code);
      return true;
    }
    if (_rule.matchAsPrefix(line) != null) {
      _mark(marks, start, end, MdMark.marker | MdMark.rule);
      return false;
    }
    var at = start;
    var flags = 0;
    if (_heading.matchAsPrefix(line) case final heading?) {
      flags = heading.group(1)!.length == 1 ? MdMark.heading1 : MdMark.heading2;
      _mark(marks, start, start + heading.end, MdMark.marker | flags);
      at = start + heading.end;
    } else {
      if (_quote.matchAsPrefix(line) case final quote?) {
        flags |= MdMark.quote;
        _mark(marks, at, start + quote.end, MdMark.marker | MdMark.quote);
        at = start + quote.end;
      }
      if (_item.matchAsPrefix(text.substring(at, end)) case final item?) {
        if (item.group(3) case final box? when box != ' ') {
          flags |= MdMark.done;
        }
        _mark(marks, at, at + item.end, MdMark.listMarker | flags);
        at += item.end;
      }
    }
    _mark(marks, at, end, flags);
    _Inline(text, marks, end).scan(at);
    return false;
  }

  static void _mark(Uint16List marks, int start, int end, int flags) {
    for (var i = start; i < end; i++) {
      marks[i] |= flags;
    }
  }

  static List<MdRun> _runs(Uint16List marks) {
    final runs = <MdRun>[];
    var start = 0;
    for (var i = 1; i <= marks.length; i++) {
      if (i == marks.length || marks[i] != marks[start]) {
        if (i > start) runs.add(MdRun(start, i, marks[start]));
        start = i;
      }
    }
    return runs;
  }
}

/// Inline marks of one line, from a position to [_end].
final class _Inline {
  _Inline(this._text, this._marks, this._end);

  final String _text;
  final Uint16List _marks;
  final int _end;

  /// Where each closing mark was last found on this line, or -1 when there
  /// is none left: a search is never repeated over the same stretch.
  final _found = <String, int>{};

  int _next(String mark, int from) {
    final known = _found[mark];
    if (known != null && (known < 0 || known >= from)) return known;
    var at = _text.indexOf(mark, from);
    if (at >= _end) at = -1;
    _found[mark] = at;
    return at;
  }

  void scan(int from) {
    var pos = from;
    while (pos < _end) {
      if (_marks[pos] & MdMark.marker != 0) {
        pos++;
        continue;
      }
      final c = _text[pos];
      final advance = switch (c) {
        '`' => _code(pos),
        '*' || '_' || '~' => _emphasis(pos, c),
        '[' => _link(pos),
        _ => 1,
      };
      pos += advance;
    }
  }

  int _code(int pos) {
    final close = _next('`', pos + 1);
    if (close < 0) return 1;
    _set(pos, pos + 1, MdMark.marker);
    _set(pos + 1, close, MdMark.code);
    _set(close, close + 1, MdMark.marker);
    // Nothing inside code is Markdown.
    return close + 1 - pos;
  }

  int _emphasis(int pos, String c) {
    final double = pos + 1 < _end && _text[pos + 1] == c;
    if (c == '~' && !double) return 1;
    final mark = double ? '$c$c' : c;
    if (c == '_' && !double && pos > 0 && _isWordy(_text[pos - 1])) return 1;
    final inner = pos + mark.length;
    final close = _next(mark, inner);
    if (close <= inner) {
      if (close == inner) _found.remove(mark);
      return mark.length;
    }
    if (c == '_' && !double && close + 1 < _end && _isWordy(_text[close + 1])) {
      return 1;
    }
    final flag = switch (c) {
      '~' => MdMark.strike,
      _ when double => MdMark.bold,
      _ => MdMark.italic,
    };
    _set(pos, inner, MdMark.marker);
    _set(inner, close, flag);
    _set(close, close + mark.length, MdMark.marker);
    // The inside is read on, for marks nested in this one.
    return mark.length;
  }

  int _link(int pos) {
    final close = _next(']', pos + 1);
    if (close < 0 || close + 1 >= _end || _text[close + 1] != '(') return 1;
    final end = _next(')', close + 2);
    if (end < 0) return 1;
    final image = pos > 0 && _text[pos - 1] == '!';
    _set(image ? pos - 1 : pos, pos + 1, MdMark.marker);
    _set(pos + 1, close, MdMark.link);
    _set(close, close + 2, MdMark.marker);
    _set(close + 2, end, MdMark.url | MdMark.marker);
    _set(end, end + 1, MdMark.marker);
    return 1;
  }

  void _set(int start, int end, int flags) {
    for (var i = start; i < end; i++) {
      _marks[i] |= flags;
    }
  }

  static bool _isWordy(String c) {
    final unit = c.codeUnitAt(0);
    return (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        unit >= 0xC0;
  }
}
