import 'package:publishing/publishing.dart';
import 'package:test/test.dart';

void main() {
  final phi = Golden.phi;

  group('Golden', () {
    test('phi and its powers', () {
      expect(phi, closeTo(1.6180339887, 1e-9));
      expect(Golden.major + Golden.minor, closeTo(1, 1e-12));
      expect(Golden.major / Golden.minor, closeTo(phi, 1e-12));
    });

    test('spacing is the Fibonacci scale', () {
      final s = Golden.spacing;
      for (var i = 2; i < s.length; i++) {
        expect(s[i], s[i - 1] + s[i - 2]);
      }
      expect(s, containsAll([34, 55, 89, 610]));
    });
  });

  group('Typography', () {
    test('body sizes are the three offered', () {
      expect(BodySize.values.map((s) => s.px), [16, 18, 20]);
    });

    test('headings climb and the caption falls by phi from the body', () {
      final t = const Typography(BodySize.medium);
      expect(t.body, 18);
      expect(t.caption, (18 / phi).round());
      expect(t.h3, (18 * phi).round());
      expect(t.h2, (18 * phi * phi).round());
      expect(t.h1, (18 * phi * phi * phi).round());
      expect([t.caption, t.body, t.h3, t.h2, t.h1], [11, 18, 29, 47, 76]);
    });

    test('line height is phi and the measure is 610 px', () {
      final t = const Typography(BodySize.small);
      expect(t.lineHeight, phi);
      expect(t.measure, 610);
      expect(Golden.spacing, contains(t.measure));
    });
  });

  group('PublicationLayout', () {
    test('every column split is 1, or the golden section either way', () {
      for (final layout in PublicationLayout.values) {
        final columns = layout.columns;
        expect(columns.fold<double>(0, (a, b) => a + b), closeTo(1, 1e-12));
        if (columns.length == 2) {
          final big = columns.reduce((a, b) => a > b ? a : b);
          final small = columns.reduce((a, b) => a < b ? a : b);
          expect(big / small, closeTo(phi, 1e-12), reason: layout.name);
        } else {
          expect(columns, [1.0], reason: layout.name);
        }
      }
    });

    test(
      'golden section: text first and wide; book: contents first and narrow',
      () {
        expect(PublicationLayout.goldenSection.columns, [
          Golden.major,
          Golden.minor,
        ]);
        expect(PublicationLayout.book.columns, [Golden.minor, Golden.major]);
      },
    );

    test('cover and cards are golden rectangles', () {
      expect(PublicationLayout.goldenCover.coverAspect, closeTo(phi, 1e-12));
      expect(PublicationLayout.collection.cardAspect, closeTo(phi, 1e-12));
      expect(PublicationLayout.essay.coverAspect, isNull);
    });

    test(
      'the default follows the note type by name, unknown types an essay',
      () {
        expect(PublicationLayout.forSchemaName('book'), PublicationLayout.book);
        expect(
          PublicationLayout.forSchemaName('book_chapter'),
          PublicationLayout.book,
        );
        expect(
          PublicationLayout.forSchemaName('song_sketch'),
          PublicationLayout.goldenCover,
        );
        expect(
          PublicationLayout.forSchemaName('dream_log'),
          PublicationLayout.goldenCover,
        );
        expect(
          PublicationLayout.forSchemaName('book_character'),
          PublicationLayout.goldenSection,
        );
        expect(
          PublicationLayout.forSchemaName('journal'),
          PublicationLayout.essay,
        );
        expect(
          PublicationLayout.forSchemaName('something_new'),
          PublicationLayout.essay,
        );
      },
    );

    test('a site home is never a single-note layout by default', () {
      expect(PublicationLayout.homeDefault, PublicationLayout.collection);
    });
  });
}
