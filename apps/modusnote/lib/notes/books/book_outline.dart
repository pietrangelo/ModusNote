import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../note_store.dart';
import '../note_title.dart';

/// Words as a writer counts them: runs of text between spaces that hold a
/// letter or a digit. Markdown marks on their own (`#`, `-`, `**`, `>`)
/// are not words; a word inside them is one. One pass over the text,
/// whatever its length.
abstract final class WordCount {
  static final _run = RegExp(r'\S+');
  static final _wordy = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static int of(String text) {
    var count = 0;
    for (final match in _run.allMatches(text)) {
      if (_wordy.hasMatch(match[0]!)) count++;
    }
    return count;
  }
}

/// A chapter as its book lists it.
final class OutlinedChapter {
  const OutlinedChapter(this.entry, {required this.words, this.number});

  final DynamicEntry entry;
  final int words;
  final int? number;
}

/// What a book gathers: the chapters, characters and places filed in its
/// category or in the categories inside it, outside the trash. Notes of a
/// type are told by the type's name, so a later version of a chapter is
/// still a chapter.
final class BookOutline {
  BookOutline._(this.category, this.chapters, this.characters, this.places);

  static const book = 'book';
  static const chapter = 'book_chapter';
  static const character = 'book_character';
  static const place = 'book_place';

  /// Null when the book is in no category: there is nothing to gather.
  static BookOutline? of({
    required CategoryId? category,
    required NoteStore store,
    required SchemaDefinition? Function(DynamicEntry) schemaOf,
  }) {
    if (category == null) return null;
    final inside = store.categories.subtree(category);
    if (inside.isEmpty) return null;
    final chapters = <OutlinedChapter>[];
    final characters = <DynamicEntry>[];
    final places = <DynamicEntry>[];
    for (final entry in store.entries) {
      if (!inside.contains(store.categoryOf(entry.id))) continue;
      switch (entry.schemaId.name) {
        case chapter:
          chapters.add(
            OutlinedChapter(
              entry,
              words: switch (entry.valueOf(FieldKey('body'))) {
                TextValue(:final text) => WordCount.of(text),
                _ => 0,
              },
              number: switch (entry.valueOf(FieldKey('number'))) {
                NumberValue(:final number) => number.toInt(),
                _ => null,
              },
            ),
          );
        case character:
          characters.add(entry);
        case place:
          places.add(entry);
      }
    }
    String title(DynamicEntry entry) =>
        NoteTitle.of(entry, schemaOf(entry)).toLowerCase();
    int byTitle(DynamicEntry a, DynamicEntry b) {
      final named = title(a).compareTo(title(b));
      return named != 0 ? named : a.id.value.compareTo(b.id.value);
    }

    chapters.sort((a, b) {
      final (x, y) = (a.number, b.number);
      if (x != y) {
        if (x == null) return 1;
        if (y == null) return -1;
        return x.compareTo(y);
      }
      return byTitle(a.entry, b.entry);
    });
    characters.sort(byTitle);
    places.sort(byTitle);
    return BookOutline._(category, chapters, characters, places);
  }

  final CategoryId category;

  /// By number, then by title; chapters without a number come last.
  final List<OutlinedChapter> chapters;

  /// By name.
  final List<DynamicEntry> characters;

  /// By name.
  final List<DynamicEntry> places;

  int get words => chapters.fold(0, (sum, c) => sum + c.words);
}
