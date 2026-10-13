import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/editor/markdown_syntax.dart';

/// The flags of the run covering the first occurrence of [part] in [text],
/// which must be a single run.
int marksOf(String text, String part, {int from = 0}) {
  final start = text.indexOf(part, from);
  expect(start, greaterThanOrEqualTo(0), reason: part);
  final runs = MarkdownSyntax.scan(text);
  final run = runs.firstWhere((r) => r.start <= start && start < r.end);
  expect(run.end, greaterThanOrEqualTo(start + part.length), reason: part);
  return run.marks;
}

bool has(int marks, int flag) => marks & flag != 0;

void main() {
  test('runs cover the whole text, in order, without gaps', () {
    const text = '# Titolo\n\nUn **riff** e _poi_ `code`.\n- [x] fatto';
    final runs = MarkdownSyntax.scan(text);
    var at = 0;
    for (final run in runs) {
      expect(run.start, at);
      expect(run.end, greaterThan(run.start));
      at = run.end;
    }
    expect(at, text.length);
  });

  test('plain text has no marks', () {
    expect(MarkdownSyntax.scan('solo testo'), [const MdRun(0, 10, 0)]);
    expect(MarkdownSyntax.scan(''), isEmpty);
  });

  test('bold, italic, strike and code show as such, their marks dimmed', () {
    const text = 'a **forte** b _piano_ c ~~via~~ d `x = 1`';
    expect(has(marksOf(text, 'forte'), MdMark.bold), isTrue);
    expect(has(marksOf(text, '**'), MdMark.marker), isTrue);
    expect(has(marksOf(text, 'piano'), MdMark.italic), isTrue);
    expect(has(marksOf(text, 'via'), MdMark.strike), isTrue);
    expect(has(marksOf(text, 'x = 1'), MdMark.code), isTrue);
    expect(marksOf(text, ' b '), 0);
  });

  test('marks nest', () {
    const text = '**molto _forte_**';
    final forte = marksOf(text, 'forte');
    expect(has(forte, MdMark.bold) && has(forte, MdMark.italic), isTrue);
  });

  test('nothing inside code is Markdown', () {
    expect(has(marksOf('`**no**`', 'no'), MdMark.bold), isFalse);
  });

  test('an underscore inside a word is not emphasis', () {
    expect(marksOf('nome_del_file', 'del'), 0);
  });

  test('an unclosed mark is plain text', () {
    expect(MarkdownSyntax.scan('a **b'), [const MdRun(0, 5, 0)]);
  });

  test('headings are big, their hashes dimmed', () {
    const text = '# Uno\n## Due';
    expect(has(marksOf(text, 'Uno'), MdMark.heading1), isTrue);
    expect(has(marksOf(text, 'Due'), MdMark.heading2), isTrue);
    expect(has(marksOf(text, '# '), MdMark.marker), isTrue);
    expect(marksOf('#hashtag', 'hashtag'), 0);
  });

  test('list markers stand out; a ticked task is done', () {
    const text = '- uno\n1. due\n- [x] tre\n- [ ] quattro';
    expect(has(marksOf(text, '- '), MdMark.listMarker), isTrue);
    expect(has(marksOf(text, '1. '), MdMark.listMarker), isTrue);
    expect(has(marksOf(text, 'tre'), MdMark.done), isTrue);
    expect(has(marksOf(text, 'quattro'), MdMark.done), isFalse);
  });

  test('quotes, rules and links', () {
    const text = '> detto\n---\n[sito](https://x.y)';
    expect(has(marksOf(text, 'detto'), MdMark.quote), isTrue);
    expect(has(marksOf(text, '---'), MdMark.rule), isTrue);
    expect(has(marksOf(text, 'sito'), MdMark.link), isTrue);
    expect(has(marksOf(text, 'https'), MdMark.url), isTrue);
  });

  test('fenced code is code up to its closing fence', () {
    const text = '```\n**non grassetto**\n```\ndopo';
    expect(has(marksOf(text, 'non'), MdMark.code), isTrue);
    expect(has(marksOf(text, 'non'), MdMark.bold), isFalse);
    expect(marksOf(text, 'dopo'), 0);
  });

  group('adversary', () {
    for (final (name, text) in [
      ('openers without closers', '[' * 100000),
      ('stars', '*' * 100000),
      ('backticks', '`a' * 50000),
      ('underscores', '_a' * 50000),
      ('nested brackets', '${'[' * 50000}${']' * 50000}'),
      ('many lines', '- **a\n' * 20000),
    ]) {
      test('$name are read in linear time', () {
        final watch = Stopwatch()..start();
        final runs = MarkdownSyntax.scan(text);
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        expect(runs.last.end, text.length);
      });
    }
  });
}
