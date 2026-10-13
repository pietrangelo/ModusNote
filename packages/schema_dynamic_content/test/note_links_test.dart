import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

void main() {
  final a = EntryId('0123456789abcdef0123456789abcdef');
  final b = EntryId('fedcba9876543210fedcba9876543210');

  test('writes a link to the note id', () {
    expect(
      NoteLinks.markdown('Capitolo 1', a),
      '[Capitolo 1](note:0123456789abcdef0123456789abcdef)',
    );
  });

  test('makes the label one safe line that cannot close early', () {
    expect(
      NoteLinks.markdown(' a]b[c\nd\u202Ee ', a),
      startsWith('[a b c d e]('),
    );
    expect(NoteLinks.markdown('[]\n', a), startsWith('[→]('));
  });

  test('finds every target once, in order, in text values only', () {
    final values = <FieldValue>[
      TextValue(
        'Vedi ${NoteLinks.markdown('B', b)} e ${NoteLinks.markdown('A', a)}, '
        'poi ancora ${NoteLinks.markdown('B di nuovo', b)}.',
      ),
      TagListValue({'(note:${a.value})'}),
      const TextValue('[x](https://example.org) [y](note:) [z](note:a b)'),
    ];
    expect(NoteLinks.targets(values), [b, a]);
  });

  test('a written link is always found again', () {
    for (final label in ['', 'x', 'a](note:zz)', '\n\n', 'é ♯']) {
      expect(NoteLinks.targets([TextValue(NoteLinks.markdown(label, a))]), [
        a,
      ], reason: label);
    }
  });

  Glados(any.letterOrDigits).test('any label round-trips to the same target', (
    label,
  ) {
    expect(NoteLinks.targets([TextValue(NoteLinks.markdown(label, b))]), [b]);
  });
}
