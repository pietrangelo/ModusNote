import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/markdown/markdown_document.dart';

List<MdBlock> parse(String source) => MarkdownDocument.parse(source).blocks;

List<MdInline> inlineOf(String source) =>
    (parse(source).single as MdParagraph).inlines;

void main() {
  group('blocks', () {
    test('paragraphs are split by blank lines; lines inside keep breaks', () {
      final blocks = parse('prima riga\nseconda riga\n\naltro paragrafo');

      expect(blocks, [
        MdParagraph([MdText('prima riga\nseconda riga')]),
        MdParagraph([MdText('altro paragrafo')]),
      ]);
    });

    test('ATX headings, with closing hashes dropped', () {
      expect(parse('# Titolo\n## Sotto ##\n###### Sei'), [
        MdHeading(1, [MdText('Titolo')]),
        MdHeading(2, [MdText('Sotto')]),
        MdHeading(6, [MdText('Sei')]),
      ]);
      expect(parse('####### sette'), [
        MdParagraph([MdText('####### sette')]),
      ]);
      expect(parse('#senza spazio'), [
        MdParagraph([MdText('#senza spazio')]),
      ]);
    });

    test('bullet and ordered lists, with their start number', () {
      expect(parse('- uno\n* due\n+ tre'), [
        MdList(
          ordered: false,
          start: 1,
          items: [
            MdListItem([
              MdParagraph([MdText('uno')]),
            ]),
            MdListItem([
              MdParagraph([MdText('due')]),
            ]),
            MdListItem([
              MdParagraph([MdText('tre')]),
            ]),
          ],
        ),
      ]);
      expect(parse('3. tre\n4) quattro'), [
        MdList(
          ordered: true,
          start: 3,
          items: [
            MdListItem([
              MdParagraph([MdText('tre')]),
            ]),
            MdListItem([
              MdParagraph([MdText('quattro')]),
            ]),
          ],
        ),
      ]);
    });

    test('task items carry their check state', () {
      final list =
          parse('- [ ] latte\n- [x] pane\n- [X] uova').single as MdList;

      expect(
        [for (final item in list.items) item.checked],
        [false, true, true],
      );
      expect(list.items.first.blocks, [
        MdParagraph([MdText('latte')]),
      ]);
    });

    test('indented lines belong to the item above, as a nested list', () {
      final list =
          parse('- frutta\n  - mele\n  - pere\n- verdura').single as MdList;

      expect(list.items, hasLength(2));
      expect(list.items.first.blocks, [
        MdParagraph([MdText('frutta')]),
        MdList(
          ordered: false,
          start: 1,
          items: [
            MdListItem([
              MdParagraph([MdText('mele')]),
            ]),
            MdListItem([
              MdParagraph([MdText('pere')]),
            ]),
          ],
        ),
      ]);
    });

    test('quotes hold blocks of their own', () {
      expect(parse('> # Citazione\n> testo'), [
        MdQuote([
          MdHeading(1, [MdText('Citazione')]),
          MdParagraph([MdText('testo')]),
        ]),
      ]);
    });

    test('fenced code keeps its text untouched', () {
      expect(parse('```dart\nfinal a = **1**;\n\n# no\n```\ndopo'), [
        MdCodeBlock('final a = **1**;\n\n# no'),
        MdParagraph([MdText('dopo')]),
      ]);
    });

    test('an unclosed fence runs to the end', () {
      expect(parse('```\ncodice'), [MdCodeBlock('codice')]);
    });

    test('rules', () {
      expect(parse('sopra\n\n---\n\n* * *\n___'), [
        MdParagraph([MdText('sopra')]),
        MdRule(),
        MdRule(),
        MdRule(),
      ]);
    });

    test('a heading or list interrupts a paragraph', () {
      expect(parse('testo\n# Titolo\n- voce'), [
        MdParagraph([MdText('testo')]),
        MdHeading(1, [MdText('Titolo')]),
        MdList(
          ordered: false,
          start: 1,
          items: [
            MdListItem([
              MdParagraph([MdText('voce')]),
            ]),
          ],
        ),
      ]);
    });

    test('Windows line endings read like Unix ones', () {
      expect(parse('# A\r\nb\r\n'), parse('# A\nb\n'));
    });
  });

  group('inlines', () {
    test('strong, emphasis, strike and code', () {
      expect(inlineOf('a **forte** b *corsivo* c ~~via~~ d `x*y`'), [
        MdText('a '),
        MdStrong([MdText('forte')]),
        MdText(' b '),
        MdEmphasis([MdText('corsivo')]),
        MdText(' c '),
        MdStrike([MdText('via')]),
        MdText(' d '),
        MdCode('x*y'),
      ]);
    });

    test('underscores inside words stay literal', () {
      expect(inlineOf('snake_case_name e _corsivo_'), [
        MdText('snake_case_name e '),
        MdEmphasis([MdText('corsivo')]),
      ]);
    });

    test('nesting', () {
      expect(inlineOf('**forte e *corsivo***'), [
        MdStrong([
          MdText('forte e '),
          MdEmphasis([MdText('corsivo')]),
        ]),
      ]);
    });

    test('unmatched delimiters are plain text', () {
      expect(inlineOf('2 * 3 = 6 e **aperto'), [
        MdText('2 * 3 = 6 e **aperto'),
      ]);
      expect(inlineOf('`aperto'), [MdText('`aperto')]);
    });

    test('backslash escapes punctuation', () {
      expect(inlineOf(r'\*non corsivo\* e \a'), [
        MdText(r'*non corsivo* e \a'),
      ]);
    });

    test('links keep text and address; images keep only their alt text', () {
      expect(
        inlineOf(
          'vedi [il sito](https://modus.serv.run) e ![foto](https://x/y.png)',
        ),
        [
          MdText('vedi '),
          MdLink([MdText('il sito')], 'https://modus.serv.run'),
          MdText(' e '),
          MdImage('foto', 'https://x/y.png'),
        ],
      );
      expect(inlineOf('[senza indirizzo] e [vuoto]()'), [
        MdText('[senza indirizzo] e '),
        MdLink([MdText('vuoto')], ''),
      ]);
    });

    test('raw HTML is just text', () {
      expect(inlineOf('<script>alert(1)</script>'), [
        MdText('<script>alert(1)</script>'),
      ]);
    });
  });

  test('plain text drops the markup, for previews', () {
    final document = MarkdownDocument.parse(
      '# Spesa\n\n- [ ] **latte** e [pane](https://x)\n\n```\ncodice\n```',
    );

    expect(document.plainText, 'Spesa\nlatte e pane\ncodice');
  });

  group('adversary', () {
    test('deep nesting is cut off, not recursed into', () {
      final quotes = MarkdownDocument.parse('${'> ' * 5000}fondo');
      var depth = 0;
      var block = quotes.blocks.single;
      while (block is MdQuote) {
        depth++;
        block = block.blocks.single;
      }
      expect(depth, MarkdownDocument.maxDepth);
      expect(block, isA<MdParagraph>());

      final lists = MarkdownDocument.parse(
        [for (var i = 0; i < 2000; i++) '${'  ' * i}- livello $i'].join('\n'),
      );
      expect(lists.blocks, isNotEmpty);

      final inline = MarkdownDocument.parse('${'**' * 5000}x${'**' * 5000}');
      expect(inline.plainText, contains('x'));
    });

    test('the largest allowed note parses quickly, whatever it holds', () {
      const limit = 100000;
      final inputs = {
        'openers': '*a ' * (limit ~/ 3),
        'strong openers': '**a ' * (limit ~/ 4),
        'brackets': '[' * limit,
        'link starts': '[a](' * (limit ~/ 4),
        'backticks': '`a``' * (limit ~/ 4),
        'list items': '- a\n' * (limit ~/ 4),
        'blank lines': '\n' * limit,
        'escapes': r'\*' * (limit ~/ 2),
      };
      for (final MapEntry(:key, :value) in inputs.entries) {
        final watch = Stopwatch()..start();
        MarkdownDocument.parse(value);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 1)),
          reason: key,
        );
      }
    });

    test('link addresses are kept as written, never resolved', () {
      expect(inlineOf('[a](javascript:alert(1))'), [
        MdLink([MdText('a')], 'javascript:alert(1'),
        MdText(')'),
      ]);
    });
  });
}
