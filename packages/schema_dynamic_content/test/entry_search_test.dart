import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'fixtures.dart';

DynamicEntry songEntry(Map<String, FieldValue> attributes) => valueOf(
  DynamicEntry.create(
    schema: song,
    id: EntryId('e1'),
    attributes: {
      key('title'): const TextValue('Notturno'),
      for (final e in attributes.entries) key(e.key): e.value,
    },
    at: at,
  ),
);

DynamicEntry noteEntry(String content) => valueOf(
  DynamicEntry.create(
    schema: SeedSchemas.quickNoteV1,
    id: EntryId('n1'),
    attributes: {key('content'): TextValue(content)},
    at: at,
  ),
);

void main() {
  final entry = songEntry({
    'title': const TextValue('Città di notte'),
    'tags': TagListValue({'Jazz', 'demo'}),
    'key': const ChoiceValue('a_minor'),
    'bpm': NumberValue(96),
  });

  test('an empty or blank query matches every entry', () {
    expect(EntrySearch('').matches(entry), isTrue);
    expect(EntrySearch('   ').matches(entry), isTrue);
  });

  test('matches text, tags and choice options', () {
    expect(EntrySearch('notte').matches(entry), isTrue);
    expect(EntrySearch('jazz').matches(entry), isTrue);
    expect(EntrySearch('a_minor').matches(entry), isTrue);
  });

  test('ignores case and Latin diacritics, both ways', () {
    expect(EntrySearch('CITTA').matches(entry), isTrue);
    expect(EntrySearch('città').matches(entry), isTrue);
    expect(
      EntrySearch('perche')
          .matches(songEntry({'title': const TextValue('Perché no')})),
      isTrue,
    );
  });

  test('every word of the query must match, in any field', () {
    expect(EntrySearch('notte jazz').matches(entry), isTrue);
    expect(EntrySearch('notte rock').matches(entry), isFalse);
  });

  test('numbers, dates and audio ids are not searched', () {
    expect(EntrySearch('96').matches(entry), isFalse);
  });

  group('adversary', () {
    Glados2(any.letterOrDigits, any.letterOrDigits).test(
      'never throws, whatever the query and the text',
      (query, text) {
        EntrySearch(query).matches(noteEntry(text));
      },
    );

    test('emoji, combining marks and lone surrogates do not break it', () {
      final odd = noteEntry('🎵 e\u0301 \uD800 ok');

      expect(EntrySearch('🎵').matches(odd), isTrue);
      expect(EntrySearch('\uDC00').matches(odd), isFalse);
      expect(EntrySearch('ok').matches(odd), isTrue);
    });

    test('regex metacharacters are plain text, not patterns', () {
      final tricky = songEntry({'title': const TextValue('a+b (c)')});

      expect(EntrySearch('a+b').matches(tricky), isTrue);
      expect(EntrySearch('(c)').matches(tricky), isTrue);
      expect(EntrySearch('.*').matches(tricky), isFalse);
    });
  });

  test('an edited entry is searched by its new text, not a cached one', () {
    final before = noteEntry('prima');
    final after = valueOf(
      before.update(
        schema: SeedSchemas.quickNoteV1,
        changes: {key('content'): const TextValue('dopo')},
        at: at,
      ),
    );
    expect(EntrySearch('prima').matches(before), isTrue);
    expect(EntrySearch('dopo').matches(after), isTrue);
    expect(EntrySearch('prima').matches(after), isFalse);
    expect(EntrySearch('dopo').matches(before), isFalse);
  });

  test('folding lowers, strips Latin accents and leaves the rest', () {
    expect(EntrySearch.fold('Città ÀÉÎÕÜ çß ŽŁ'), 'citta aeiou cs zł');
    expect(EntrySearch.fold('Plain ASCII, 123!'), 'plain ascii, 123!');
    expect(EntrySearch.fold('Привет 東京 🎵ñ'), 'привет 東京 🎵n');
    expect(EntrySearch.fold(''), '');
  });
}
