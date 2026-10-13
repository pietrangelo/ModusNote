import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/documents/page_index.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../books/book_support.dart' show schemaOf;
import 'manual_support.dart';

void main() {
  group('naturalCompare', () {
    int sign(String a, String b) => PageIndex.naturalCompare(a, b).sign;

    test('numbers by value, the rest as text', () {
      expect(sign('2. uso', '10. note'), -1);
      expect(sign('capitolo 9', 'capitolo 10'), -1);
      expect(sign('a', 'b'), -1);
      expect(sign('abc', 'ab'), 1);
      expect(sign('007', '7'), 0);
      expect(sign('x2y', 'x2z'), -1);
    });

    test('a run of digits too long for a number is still ordered', () {
      final huge = '9' * 400;
      expect(sign('1$huge', '2$huge'), -1);
      expect(sign(huge, '1$huge'), -1);
    });
  });

  group('PageIndex', () {
    late InMemoryNoteStore store;

    setUp(() async {
      store = await manualStore();
    });

    List<IndexSection>? index(CategoryId? category) =>
        PageIndex.of(category: category, store: store, schemaOf: schemaOf);

    List<(String, int, String)> shape(List<IndexSection> sections) => [
      for (final s in sections)
        (
          s.category.name.value,
          s.level,
          [for (final p in s.pages) p.id.value.substring(0, 2)].join(' '),
        ),
    ];

    test('a section per category, pages in natural order', () {
      expect(shape(index(manual)!), [
        ('Manuale', 0, 'p1 p2 p3'),
        ('Installazione', 1, 'p4'),
        ('Avanzate', 2, 'p5'),
      ]);
    });

    test('a category inside the manual indexes what it holds', () {
      expect(shape(index(setup)!), [
        ('Installazione', 0, 'p4'),
        ('Avanzate', 1, 'p5'),
      ]);
    });

    test('empty categories inside are left out, the own one kept', () async {
      await store.moveToTrash(page('p5'));
      await store.moveToTrash(page('p4'));

      expect(shape(index(setup)!), [('Installazione', 0, '')]);
    });

    test('a page in no category, or in one that is gone, has no index', () {
      expect(index(null), isNull);
      expect(index(CategoryId('z' * 32)), isNull);
    });
  });
}
