import 'dart:convert';
import 'dart:typed_data';

import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

void main() {
  group('site settings', () {
    test('travel to serv.pub with the colours derived and checked', () {
      final settings = SiteSettings(
        title: 'Quaderno',
        lang: 'it',
        theme: const SiteTheme(BaseTheme.paper, accentHue: 200),
      );
      final wire = settings.toWire();
      expect(wire['title'], 'Quaderno');
      expect(wire['body'], 18);
      expect(wire['home'], 'collection');
      expect(wire['indexable'], isFalse, reason: 'off until turned on');
      final theme = wire['theme']! as Map<String, Object>;
      expect(theme['dark'], isFalse);
      for (final key in [
        'background',
        'surface',
        'text',
        'secondary',
        'accent',
        'second_accent',
      ]) {
        expect(theme[key], matches(RegExp(r'^#[0-9A-F]{6}$')), reason: key);
      }
      final text = Srgb.hex(theme['text']! as String);
      final ground = Srgb.hex(theme['background']! as String);
      expect(text.contrastWith(ground), greaterThanOrEqualTo(7));
    });

    test('are kept as choices and read back', () {
      final settings = SiteSettings(
        title: 'Quaderno',
        about: 'Note di mare.',
        lang: 'en',
        theme: const SiteTheme(
          BaseTheme.restful,
          accentHue: 30,
          backgroundHue: 250,
        ),
        body: BodySize.large,
        home: PublicationLayout.essay,
        indexable: true,
        font: SiteFont.literata,
      );
      expect(
        SiteSettings.fromJson(jsonDecode(jsonEncode(settings.toJson()))),
        settings,
      );
    });

    test('choose the body font, Inter until chosen', () {
      final settings = SiteSettings(title: 'Quaderno', lang: 'it');
      expect(settings.font, SiteFont.inter);
      expect(settings.toWire()['font'], 'inter');
      for (final font in SiteFont.values) {
        expect(settings.copyWith(font: font).toWire()['font'], font.wire);
      }
      expect(
        {for (final font in SiteFont.values) font.wire},
        {'inter', 'literata', 'atkinson', 'quattro'},
        reason: "serv.pub's names",
      );
      // A site book kept before fonts were a choice.
      final kept = settings.toJson()..remove('font');
      expect(SiteSettings.fromJson(kept).font, SiteFont.inter);
      expect(
        () => SiteSettings.fromJson({...settings.toJson(), 'font': 'comic'}),
        throwsA(isA<NotPublishableException>()),
      );
    });

    test('refuse what serv.pub would refuse', () {
      expect(
        () => SiteSettings(title: '  ', lang: 'it'),
        throwsA(isA<NotPublishableException>()),
      );
      expect(
        () => SiteSettings(title: 'x', lang: 'ITA'),
        throwsA(isA<NotPublishableException>()),
      );
      expect(
        () =>
            SiteSettings(title: 'x', lang: 'it', home: PublicationLayout.book),
        throwsA(isA<NotPublishableException>()),
      );
      expect(SiteSettings(title: 'a\u202Eb', lang: 'it').title, 'a b');
    });
  });

  group('site book', () {
    final book = SiteBook(
      name: SiteName('quaderno'),
      settings: SiteSettings(title: 'Quaderno', lang: 'it'),
      pages: {
        EntryId('note-1'): PublishedPage(
          slug: PageSlug('il-faro'),
          title: 'Il faro',
          listed: true,
          media: [MediaId('AAAAAAAAAAAAAAAAAAAAAA')],
          at: DateTime.utc(2026, 10, 31),
        ),
      },
      drafts: {
        EntryId('note-2'): PublishedPage(
          slug: PageSlug('bozza-abcdefghij'),
          title: 'Bozza',
          listed: false,
          media: const [],
          at: DateTime.utc(2026, 10, 31),
        ),
      },
    );

    test('round trips', () {
      final back = SiteBook.fromBytes(book.toBytes());
      expect(back.name, book.name);
      expect(back.settings, book.settings);
      expect(back.pages.keys, book.pages.keys);
      expect(back.drafts.keys, [EntryId('note-2')]);
      expect(back.pages[EntryId('note-1')]!.media, [
        MediaId('AAAAAAAAAAAAAAAAAAAAAA'),
      ]);
      expect(back.home, Uri.parse('https://serv.pub/quaderno/'));
    });

    test('links only to listed pages, never to drafts', () {
      expect(book.slugs, {EntryId('note-1'): PageSlug('il-faro')});
    });

    test('adds and removes pages and drafts', () {
      final without = book.withPage(EntryId('note-1'), null);
      expect(without.pages, isEmpty);
      expect(without.drafts, hasLength(1));
      expect(book.pages, hasLength(1), reason: 'immutable');
      expect(book.taken, {PageSlug('il-faro'), PageSlug('bozza-abcdefghij')});
      expect(book.withDraft(EntryId('note-2'), null).drafts, isEmpty);
    });

    test('anything else is malformed', () {
      for (final bad in [
        '',
        '{}',
        '{"v":2,"name":"quaderno","settings":{},"pages":{},"drafts":{}}',
        '{"v":1,"name":"api","settings":{},"pages":{},"drafts":{}}',
      ]) {
        expect(
          () => SiteBook.fromBytes(Uint8List.fromList(utf8.encode(bad))),
          throwsA(isA<NotPublishableException>()),
          reason: bad,
        );
      }
    });
  });
}
