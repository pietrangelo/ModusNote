import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/books/book_outline.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'book_support.dart';

void main() {
  group('WordCount', () {
    test('counts words, not Markdown marks', () {
      expect(WordCount.of(''), 0);
      expect(WordCount.of('   \n\t '), 0);
      expect(WordCount.of('# Capitolo uno\n\n- una **frase** _breve_'), 5);
      expect(WordCount.of("L'alba, 1923 — poi > niente."), 4);
      expect(WordCount.of('* * *\n---\n> '), 0);
      expect(WordCount.of('città così è'), 3);
    });

    test('a long chapter is counted in one pass', () {
      final text = List.filled(100000, 'parola').join(' ');
      final watch = Stopwatch()..start();
      expect(WordCount.of(text), 100000);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('BookOutline', () {
    late InMemoryNoteStore store;

    setUp(() async {
      store = await bookStore();
    });

    BookOutline? outline(CategoryId? category) =>
        BookOutline.of(category: category, store: store, schemaOf: schemaOf);

    test('gathers the book from its category and those inside', () {
      final book = outline(novel)!;

      expect(book.chapters.map((c) => c.entry.id.value), [
        'c1' * 16,
        'c2' * 16,
        'c3' * 16,
      ]);
      expect(book.chapters.map((c) => (c.number, c.words)), [
        (1, 4),
        (2, 2),
        (null, 0),
      ]);
      expect(book.words, 6);
      expect(book.characters.map(titleOf), ['Ada', 'Bruno']);
      expect(book.places.map(titleOf), ['Faro']);
    });

    test('a category inside the book gathers only what it holds', () {
      final part = outline(partTwo)!;

      expect(part.chapters.map((c) => c.number), [2]);
      expect(part.characters, isEmpty);
    });

    test('a book in no category, or one that is gone, gathers nothing', () {
      expect(outline(null), isNull);
      expect(outline(CategoryId('z' * 32)), isNull);
    });

    test('notes in the trash and other types are left out', () async {
      await store.moveToTrash(EntryId('c1' * 16));

      final book = outline(novel)!;
      expect(book.chapters.map((c) => c.number), [2, null]);
      expect(book.words, 2);
      // The quick note filed with the book is not part of it.
      expect(
        [...book.characters, ...book.places].map((e) => e.schemaId.name),
        everyElement(startsWith('book_')),
      );
    });
  });
}
