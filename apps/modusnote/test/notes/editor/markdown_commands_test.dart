import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/editor/markdown_commands.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// `|` marks the cursor; `[` and `]` mark a selection.
TextEditingValue v(String marked) {
  final caret = marked.indexOf('|');
  if (caret >= 0) {
    return TextEditingValue(
      text: marked.replaceFirst('|', ''),
      selection: TextSelection.collapsed(offset: caret),
    );
  }
  final start = marked.indexOf('[');
  final end = marked.indexOf(']') - 1;
  return TextEditingValue(
    text: marked.replaceFirst('[', '').replaceFirst(']', ''),
    selection: TextSelection(baseOffset: start, extentOffset: end),
  );
}

String show(TextEditingValue value) {
  final s = value.selection;
  final t = value.text;
  if (s.isCollapsed) {
    return '${t.substring(0, s.start)}|${t.substring(s.start)}';
  }
  return '${t.substring(0, s.start)}[${t.substring(s.start, s.end)}]'
      '${t.substring(s.end)}';
}

void main() {
  group('inline marks', () {
    test('wrap the selection and keep it selected', () {
      expect(
        show(MarkdownCommands.bold(v('un [riff] lento'))),
        'un **[riff]** lento',
      );
      expect(show(MarkdownCommands.italic(v('[riff]'))), '_[riff]_');
      expect(show(MarkdownCommands.strike(v('[riff]'))), '~~[riff]~~');
      expect(show(MarkdownCommands.code(v('[riff]'))), '`[riff]`');
    });

    test('with nothing selected, open a pair around the cursor', () {
      expect(show(MarkdownCommands.bold(v('un |'))), 'un **|**');
    });

    test('a second press takes the marks away again', () {
      final once = MarkdownCommands.bold(v('un [riff] lento'));
      expect(show(MarkdownCommands.bold(once)), 'un [riff] lento');
    });

    test('a selection that includes its marks is unwrapped too', () {
      expect(show(MarkdownCommands.bold(v('[**riff**]'))), '[riff]');
    });
  });

  group('line prefixes', () {
    test('turn every selected line into a list item', () {
      expect(show(MarkdownCommands.bullets(v('a[\nb\nc]'))), '- a[\n- b\n- c]');
    });

    test('number the lines in order', () {
      expect(show(MarkdownCommands.numbered(v('[a\nb]'))), '1. [a\n2. b]');
    });

    test('a task list starts unchecked', () {
      expect(
        show(MarkdownCommands.tasks(v('compra corde|'))),
        '- [ ] compra corde|',
      );
    });

    test('pressing again on a list takes the prefix away', () {
      expect(show(MarkdownCommands.bullets(v('- [a\n- b]'))), '[a\nb]');
    });

    test('another kind of list replaces the prefix', () {
      expect(show(MarkdownCommands.tasks(v('- a|'))), '- [ ] a|');
      expect(show(MarkdownCommands.bullets(v('1. a|'))), '- a|');
    });

    test('quote', () {
      expect(show(MarkdownCommands.quote(v('detto|'))), '> detto|');
    });

    test('headings cycle from one to three levels and back', () {
      var value = v('Strofa|');
      final seen = <String>[];
      for (var i = 0; i < 4; i++) {
        value = MarkdownCommands.heading(value);
        seen.add(show(value));
      }
      expect(seen, ['# Strofa|', '## Strofa|', '### Strofa|', 'Strofa|']);
    });

    test('only the line the cursor is on changes', () {
      expect(show(MarkdownCommands.quote(v('a\nb|\nc'))), 'a\n> b|\nc');
    });
  });

  group('blocks', () {
    test('a link around the selection selects the address to type', () {
      expect(
        show(MarkdownCommands.link(v('vedi [qui]'))),
        'vedi [qui]([https://])',
      );
    });

    test('a code block fences the selected lines', () {
      expect(
        show(MarkdownCommands.codeBlock(v('[x = 1]'))),
        '```\n[x = 1]\n```',
      );
    });

    test('a rule goes on its own line', () {
      expect(show(MarkdownCommands.rule(v('fine|'))), 'fine\n\n---\n|');
    });
  });

  group('Enter in a list', () {
    test('continues the list', () {
      expect(show(MarkdownCommands.newline(v('- a|'))!), '- a\n- |');
      expect(show(MarkdownCommands.newline(v('  * a|'))!), '  * a\n  * |');
      expect(show(MarkdownCommands.newline(v('> a|'))!), '> a\n> |');
    });

    test('counts on in a numbered list', () {
      expect(show(MarkdownCommands.newline(v('9. a|'))!), '9. a\n10. |');
    });

    test('a new task is unchecked even after a done one', () {
      expect(
        show(MarkdownCommands.newline(v('- [x] a|'))!),
        '- [x] a\n- [ ] |',
      );
    });

    test('takes the rest of the line into the new item', () {
      expect(show(MarkdownCommands.newline(v('- ab|cd'))!), '- ab\n- |cd');
    });

    test('on an empty item ends the list', () {
      expect(show(MarkdownCommands.newline(v('- a\n- |'))!), '- a\n|');
    });

    test('outside a list it is an ordinary Enter', () {
      expect(MarkdownCommands.newline(v('testo|')), isNull);
      expect(MarkdownCommands.newline(v('[- a]')), isNull);
    });
  });

  group('adversary', () {
    test('a huge line is handled in linear time', () {
      final line = '- ${'a' * 100000}';
      final watch = Stopwatch()..start();
      MarkdownCommands.newline(
        TextEditingValue(
          text: line,
          selection: TextSelection.collapsed(offset: line.length),
        ),
      );
      MarkdownCommands.bullets(
        TextEditingValue(
          text: '${'x\n' * 50000}x',
          selection: const TextSelection(baseOffset: 0, extentOffset: 100001),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('an invalid selection changes nothing', () {
      const value = TextEditingValue(text: 'abc');
      expect(MarkdownCommands.bold(value), value);
      expect(MarkdownCommands.newline(value), isNull);
    });
  });

  group('image', () {
    final blob = BlobId('f' * 32);
    final ref = '(image:${'f' * 32})';

    test('goes on a line of its own, the cursor after it', () {
      expect(
        show(MarkdownCommands.image(v('ab|cd'), blob)),
        'ab\n![]$ref|\ncd',
      );
      expect(show(MarkdownCommands.image(v('ab\n|'), blob)), 'ab\n![]$ref|\n');
      expect(show(MarkdownCommands.image(v('|'), blob)), '![]$ref|\n');
      expect(
        show(MarkdownCommands.image(v('ab|\ncd'), blob)),
        'ab\n![]$ref|\ncd',
      );
    });

    test('a selection on one line becomes its caption', () {
      expect(
        show(MarkdownCommands.image(v('x [Il palco] y'), blob)),
        'x \n![Il palco]$ref|\n y',
      );
      expect(show(MarkdownCommands.image(v('[a\nb]'), blob)), '![]$ref|\n');
    });
  });
}
