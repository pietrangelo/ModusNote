import 'dart:math';
import 'dart:typed_data';

import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart' as fx;
import 'fixtures.dart' show field, schema, entry, labelOf, describe;

final class FakeKey implements SiteKey {
  FakeKey(this.name);

  final String name;
  var released = false;

  @override
  Future<String> authorize(String method, String path, Uint8List body) async =>
      'MN1 $name';

  @override
  void adjustClock(DateTime server) {}

  @override
  void release() => released = true;
}

final class FakeKeys implements SiteKeys {
  final kept = <String>{};
  final handed = <FakeKey>[];

  @override
  Future<SiteKey?> open(SiteName name) async {
    if (!kept.contains(name.value)) return null;
    return FakeKey(name.value)..also(handed.add);
  }

  @override
  Future<SiteKey> create(SiteName name) async {
    kept.add(name.value);
    return FakeKey(name.value)..also(handed.add);
  }

  @override
  Future<void> forget(SiteName name) async => kept.remove(name.value);
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}

final class FakeBooks implements SiteBookStore {
  SiteBook? book;

  @override
  Future<SiteBook?> load() async => book;

  @override
  Future<void> save(SiteBook? book) async => this.book = book;
}

final class FakeMedia implements PublicationMedia {
  final ready = <BlobId, PreparedMedia>{};

  @override
  Future<PreparedMedia?> prepare(BlobId blob) async => ready[blob];
}

/// serv.pub in memory: who holds each name, the pages and files of each.
final class FakeServer implements SiteGateway {
  final owners = <String, String>{};
  final pages = <String, Map<String, Object>>{};
  final files = <String, MediaKind>{};
  final calls = <String>[];
  Object? failPages;

  void _own(SiteKey key, SiteName name) {
    if (owners[name.value] != (key as FakeKey).name) {
      throw const PublishingRejectedException(PublishingRejection.notOwner);
    }
  }

  @override
  Future<void> claim(SiteKey key, SiteName name, Map<String, Object> s) async {
    calls.add('claim ${name.value}');
    final holder = owners[name.value];
    if (holder != null && holder != (key as FakeKey).name) {
      throw const SiteNameTakenException();
    }
    owners[name.value] = (key as FakeKey).name;
  }

  @override
  Future<void> putSettings(
    SiteKey key,
    SiteName name,
    Map<String, Object> s,
  ) async {
    _own(key, name);
    calls.add('settings');
  }

  @override
  Future<void> deleteSite(SiteKey key, SiteName name) async {
    _own(key, name);
    owners.remove(name.value);
    pages.clear();
    files.clear();
  }

  @override
  Future<void> putPage(
    SiteKey key,
    SiteName name,
    PageSlug slug,
    Map<String, Object> page,
  ) async {
    _own(key, name);
    if (failPages case final error?) throw error;
    pages[slug.value] = page;
  }

  @override
  Future<void> deletePage(SiteKey key, SiteName name, PageSlug slug) async {
    _own(key, name);
    pages.remove(slug.value);
  }

  @override
  Future<void> putMedia(
    SiteKey key,
    SiteName name,
    MediaId id,
    MediaKind kind,
    Uint8List bytes,
  ) async {
    _own(key, name);
    files[id.value] = kind;
  }

  @override
  Future<void> deleteMedia(SiteKey key, SiteName name, MediaId id) async {
    _own(key, name);
    files.remove(id.value);
  }
}

void main() {
  final note = schema('note', [
    field('body', const MarkdownFieldType()),
    field('files', AttachmentsFieldType()),
  ]);
  final picture = BlobId('0123456789abcdef0123456789abcdef');
  final name = SiteName('quaderno');
  final settings = SiteSettings(title: 'Quaderno', lang: 'it');

  late FakeServer server;
  late FakeKeys keys;
  late FakeBooks books;
  late FakeMedia media;
  late bool confirmed;
  late Publisher publisher;

  setUp(() {
    server = FakeServer();
    keys = FakeKeys();
    books = FakeBooks();
    media = FakeMedia()
      ..ready[picture] = PreparedMedia(MediaKind.png, Uint8List(8));
    confirmed = true;
    publisher = Publisher(
      gateway: server,
      keys: keys,
      books: books,
      media: media,
      isConfirmed: () => confirmed,
      random: Random(7),
      now: () => DateTime.utc(2026, 10, 31, 18),
    );
  });

  Future<Uri> publish(String text, {bool draft = false, String id = 'note-1'}) {
    final e = entry(note, {
      'body': TextValue(text),
      'files': AttachmentsValue([ImageAttachment(picture, caption: 'Molo')]),
    }, id: id);
    return publisher.publish(
      entry: e.id,
      content: PublicationPolicy.compose(
        entry: e,
        schema: note,
        fields: keys_(['body', 'files']),
      ),
      schema: note,
      labelOf: labelOf,
      describe: describe,
      draft: draft,
    );
  }

  test('claiming keeps a key of its own and the book', () async {
    final book = await publisher.claim(name, settings);
    expect(book.name, name);
    expect(books.book?.name, name);
    expect(keys.kept, {'quaderno'});
    expect(server.owners['quaderno'], 'quaderno');
    expect(keys.handed.every((k) => k.released), isTrue);
  });

  test(
    'a name someone else holds is refused and its new key forgotten',
    () async {
      server.owners['quaderno'] = 'someone';
      await expectLater(
        publisher.claim(name, settings),
        throwsA(isA<SiteNameTakenException>()),
      );
      expect(keys.kept, isEmpty);
      expect(books.book, isNull);
    },
  );

  test('nothing goes public without a fresh confirmation', () async {
    await publisher.claim(name, settings);
    confirmed = false;
    await expectLater(
      publish('# Il faro\n\nLuce.'),
      throwsA(isA<PublishingConfirmationRequiredException>()),
    );
    await expectLater(
      publisher.updateSettings(settings),
      throwsA(isA<PublishingConfirmationRequiredException>()),
    );
    await expectLater(
      publisher.withdrawSite(),
      throwsA(isA<PublishingConfirmationRequiredException>()),
    );
    expect(server.pages, isEmpty);
    expect(server.files, isEmpty);
    expect(
      () => Publisher(
        gateway: server,
        keys: keys,
        books: books,
        media: media,
        isConfirmed: () => false,
      ).claim(SiteName('altro'), settings),
      throwsA(isA<PublishingConfirmationRequiredException>()),
    );
  });

  test('publishing without a site says so', () async {
    await expectLater(publish('x'), throwsA(isA<NoSiteException>()));
  });

  test('a page is published with fresh copies of its pictures', () async {
    await publisher.claim(name, settings);
    final url = await publish('# Il faro\n\nLuce.');
    expect(url, Uri.parse('https://serv.pub/quaderno/il-faro'));
    expect(server.pages.keys, ['il-faro']);
    expect(server.files, hasLength(1));
    final copy = server.files.keys.single;
    expect(copy, isNot(picture.value));
    final page = books.book!.pages[EntryId('note-1')]!;
    expect(page.media.single.value, copy);
    expect(page.listed, isTrue);
  });

  test('published again it keeps its address and swaps its files', () async {
    await publisher.claim(name, settings);
    await publish('# Il faro\n\nLuce.');
    final first = server.files.keys.single;
    final url = await publish('# Un altro titolo\n\nLuce.');
    expect(url.path, '/quaderno/il-faro');
    expect(server.files.keys.single, isNot(first));
    expect(server.pages.keys, ['il-faro']);
  });

  test(
    'a draft has an address nobody guesses and leaves the page be',
    () async {
      await publisher.claim(name, settings);
      await publish('# Il faro\n\nLuce.');
      final live = Map.of(server.pages['il-faro']!);
      final url = await publish('# Il faro\n\nAltra luce.', draft: true);
      expect(url.path, matches(RegExp(r'^/quaderno/il-faro-[a-z2-7]{10}$')));
      final slug = url.pathSegments.last;
      expect(
        server.pages['il-faro'],
        live,
        reason: 'the live page is untouched',
      );
      expect(server.pages[slug]!['listed'], isFalse);
      expect(books.book!.drafts[EntryId('note-1')]!.slug.value, slug);
      expect(books.book!.slugs.values, [PageSlug('il-faro')]);

      // Another preview replaces the first, files and all.
      final again = await publish('# Il faro\n\nTerza.', draft: true);
      expect(again, isNot(url));
      expect(server.pages.containsKey(slug), isFalse);
      expect(server.files, hasLength(2), reason: 'the page and one draft');

      // Publishing takes the draft away.
      await publish('# Il faro\n\nTerza.');
      expect(server.pages.keys, ['il-faro']);
      expect(server.files, hasLength(1));
      expect(books.book!.drafts, isEmpty);
    },
  );

  test('a page at the cookbook\'s address moves off it', () async {
    await publisher.claim(name, settings);
    // Published before serv.pub kept the address for the cookbook.
    server.pages['ricette'] = {'title': 'Ricette'};
    books.book = books.book!.withPage(
      EntryId('note-1'),
      PublishedPage(
        slug: PageSlug('ricette'),
        title: 'Ricette',
        listed: true,
        media: const [],
        at: DateTime.utc(2026, 10, 1),
      ),
    );
    final url = await publish('# Ricette\n\nLe mie.');
    expect(url.path, '/quaderno/ricette-2');
    expect(server.pages.keys, ['ricette-2']);
    expect(books.book!.slugs.values, [PageSlug('ricette-2')]);
  });

  test('a recipe reaches serv.pub structured, in the cookbook', () async {
    await publisher.claim(name, settings);
    final recipe = SeedSchemas.recipeV1;
    final e = entry(recipe, {
      'title': const TextValue('Pane'),
      'servings': NumberValue(2),
      'ingredients': IngredientsValue([
        Ingredient('Farina', amount: 500, unit: IngredientUnit.gram),
      ]),
    });
    final url = await publisher.publish(
      entry: e.id,
      content: PublicationPolicy.compose(
        entry: e,
        schema: recipe,
        fields: keys_(['title', 'servings', 'ingredients']),
      ),
      schema: recipe,
      labelOf: labelOf,
      describe: describe,
      recipeWords: RecipeWords(
        unit: (_, _) => 'g',
        option: (_, o) => o,
        category: 'Pane e lievitati',
      ),
    );
    expect(url.path, '/quaderno/pane');
    final page = server.pages['pane']!;
    expect(page['layout'], 'recipe');
    final sent = page['recipe']! as Map<String, Object?>;
    expect(sent['category'], 'Pane e lievitati');
    expect(sent['servings'], 2);
    expect((sent['ingredients']! as List).single, containsPair('one', 'g'));
  });

  test('two notes with one title get two addresses', () async {
    await publisher.claim(name, settings);
    await publish('# Il faro\n\nA.');
    final url = await publish('# Il faro\n\nB.', id: 'note-2');
    expect(url.path, '/quaderno/il-faro-2');
  });

  test('a page that fails takes its new files back', () async {
    await publisher.claim(name, settings);
    server.failPages = const PublishingRejectedException(
      PublishingRejection.invalid,
    );
    await expectLater(
      publish('# Il faro\n\nLuce.'),
      throwsA(isA<PublishingRejectedException>()),
    );
    expect(server.files, isEmpty);
    expect(books.book!.pages, isEmpty);
  });

  test(
    'withdrawing a page needs no confirmation and takes its files',
    () async {
      await publisher.claim(name, settings);
      await publish('# Il faro\n\nLuce.');
      await publish('# Il faro\n\nBozza.', draft: true);
      confirmed = false;
      await publisher.withdraw(EntryId('note-1'));
      expect(server.pages, isEmpty);
      expect(server.files, isEmpty);
      expect(books.book!.pages, isEmpty);
      expect(books.book!.drafts, isEmpty);
    },
  );

  test('withdrawing the site forgets its key and book', () async {
    await publisher.claim(name, settings);
    await publish('# Il faro\n\nLuce.');
    await publisher.withdrawSite();
    expect(server.owners, isEmpty);
    expect(keys.kept, isEmpty);
    expect(books.book, isNull);
  });

  test('settings are sent and kept', () async {
    await publisher.claim(name, settings);
    final next = settings.copyWith(indexable: true);
    await publisher.updateSettings(next);
    expect(server.calls, contains('settings'));
    expect(books.book!.settings.indexable, isTrue);
  });
}

Set<FieldKey> keys_(List<String> names) => fx.keys(names);
