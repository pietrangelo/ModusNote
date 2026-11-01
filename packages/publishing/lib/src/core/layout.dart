import 'golden.dart';

/// How a published page is laid out. Every split is the golden section and
/// every framed block a golden rectangle; on a phone each collapses to one
/// column keeping the Fibonacci margins.
enum PublicationLayout {
  /// One centred column of text.
  essay,

  /// Text in the wide column (61.8 %), margin notes, tags and audio in the
  /// narrow one (38.2 %).
  goldenSection,

  /// An opening golden rectangle with the title at the spiral's eye, then
  /// the text.
  goldenCover,

  /// Contents in the narrow column, the chapter in the wide one.
  book,

  /// A grid of golden-rectangle cards: a site's home.
  collection;

  List<double> get columns => switch (this) {
    goldenSection => [Golden.major, Golden.minor],
    book => [Golden.minor, Golden.major],
    essay || goldenCover || collection => const [1.0],
  };

  /// Width over height of the opening block, if the layout has one.
  double? get coverAspect => this == goldenCover ? Golden.phi : null;

  /// Width over height of a card, if the layout shows cards.
  double? get cardAspect => this == collection ? Golden.phi : null;

  static const homeDefault = collection;

  /// The layout a note starts with, by its type's name, so a newer version
  /// of a type keeps it.
  static PublicationLayout forSchemaName(String name) => switch (name) {
    'book' || 'book_chapter' => book,
    'song_sketch' || 'dream_log' || 'recipe' => goldenCover,
    'book_character' || 'book_place' => goldenSection,
    _ => essay,
  };
}
