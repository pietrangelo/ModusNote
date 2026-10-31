import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/publishing/publish_sheet.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/harness.dart';

final class _Key implements SiteKey {
  @override
  Future<String> authorize(String method, String path, Uint8List body) async =>
      'MN1 test';

  @override
  void adjustClock(DateTime server) {}

  @override
  void release() {}
}

final class _Keys implements SiteKeys {
  final kept = <String>{};

  @override
  Future<SiteKey?> open(SiteName name) async =>
      kept.contains(name.value) ? _Key() : null;

  @override
  Future<SiteKey> create(SiteName name) async {
    kept.add(name.value);
    return _Key();
  }

  @override
  Future<void> forget(SiteName name) async => kept.remove(name.value);
}

final class _Books implements SiteBookStore {
  SiteBook? book;

  @override
  Future<SiteBook?> load() async => book;

  @override
  Future<void> save(SiteBook? book) async => this.book = book;
}

final class _Media implements PublicationMedia {
  @override
  Future<PreparedMedia?> prepare(BlobId blob) async => null;
}

final class _Server implements SiteGateway {
  final claimed = <String>[];
  final pages = <String, Map<String, Object>>{};
  final settings = <Map<String, Object>>[];
  var taken = false;
  var deleted = false;

  @override
  Future<void> claim(SiteKey key, SiteName name, Map<String, Object> s) async {
    if (taken) throw const SiteNameTakenException();
    claimed.add(name.value);
  }

  @override
  Future<void> putSettings(
    SiteKey k,
    SiteName n,
    Map<String, Object> s,
  ) async => settings.add(s);

  @override
  Future<void> deleteSite(SiteKey key, SiteName name) async => deleted = true;

  @override
  Future<void> putPage(
    SiteKey key,
    SiteName name,
    PageSlug slug,
    Map<String, Object> page,
  ) async => pages[slug.value] = page;

  @override
  Future<void> deletePage(SiteKey key, SiteName name, PageSlug slug) async =>
      pages.remove(slug.value);

  @override
  Future<void> putMedia(
    SiteKey key,
    SiteName name,
    MediaId id,
    MediaKind kind,
    Uint8List bytes,
  ) async {}

  @override
  Future<void> deleteMedia(SiteKey key, SiteName name, MediaId id) async {}
}

Future<void> tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
}

void main() {
  final schema = SchemaDefinition(
    id: SchemaId('note', 1),
    label: Label.literal('Nota'),
    fields: [
      FieldDefinition(
        key: FieldKey('body'),
        label: Label.literal('Testo'),
        type: const MarkdownFieldType(),
      ),
      FieldDefinition(
        key: FieldKey('pin'),
        label: Label.literal('PIN'),
        type: PasswordFieldType(),
      ),
    ],
  );
  final at = DateTime.utc(2026, 10, 31, 12);
  final entry = (DynamicEntry.restore(
    schema: schema,
    id: EntryId('note-1'),
    attributes: {
      FieldKey('body'): const TextValue('# Il faro\n\nLa luce.'),
      FieldKey('pin'): const SecretValue('1234'),
    },
    audit: AuditTrail(createdAt: at, updatedAt: at, revision: 1),
  ) as Valid<DynamicEntry>).value;

  late _Server server;
  late _Books books;
  late int confirmations;
  late bool confirms;
  late bool confirmed;

  PublishingAccess access() => PublishingAccess(
    publisher: Publisher(
      gateway: server,
      keys: _Keys(),
      books: books,
      media: _Media(),
      isConfirmed: () => confirmed,
      random: Random(3),
    ),
    confirm: () async {
      confirmations++;
      confirmed = confirms;
      return confirms;
    },
  );

  setUp(() {
    server = _Server();
    books = _Books();
    confirmations = 0;
    confirms = true;
    confirmed = false;
  });

  Future<void> open(WidgetTester tester) => pumpApp(
    tester,
    Scaffold(
      body: PublishSheet(access: access(), entry: entry, schema: schema),
    ),
  );

  testWidgets('warns first, then creates the site after a confirmation', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const ValueKey('publish-warning')), findsOneWidget);
    expect(find.textContaining('fuori dalla cifratura'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('publish-site-name')),
      'Quaderno Blu!',
    );
    await tester.pump();
    // Only what a site name may hold is typed.
    expect(find.text('uaderno'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('publish-site-name')),
      'quaderno',
    );
    await tester.pump();
    await tap(tester, 'publish-create-site');
    await tester.pumpAndSettle();

    expect(confirmations, 1);
    expect(server.claimed, ['quaderno']);
    expect(find.byKey(const ValueKey('publish-confirm')), findsOneWidget);
  });

  testWidgets('a taken name says so', (tester) async {
    server.taken = true;
    await open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('publish-site-name')),
      'quaderno',
    );
    await tester.pump();
    await tap(tester, 'publish-create-site');
    await tester.pumpAndSettle();
    expect(find.text('Questo nome è già preso'), findsOneWidget);
  });

  testWidgets('without the confirmation nothing is sent', (tester) async {
    books.book = SiteBook(
      name: SiteName('quaderno'),
      settings: SiteSettings(title: 'Quaderno', lang: 'it'),
    );
    confirms = false;
    await open(tester);
    await tap(tester, 'publish-confirm');
    await tester.pumpAndSettle();
    expect(confirmations, 1);
    expect(server.pages, isEmpty);
  });

  testWidgets('publishes, shows the address, never offers the PIN', (
    tester,
  ) async {
    books.book = SiteBook(
      name: SiteName('quaderno'),
      settings: SiteSettings(title: 'Quaderno', lang: 'it'),
    );
    final keys = _Keys()..kept.add('quaderno');
    await pumpApp(
      tester,
      Scaffold(
        body: PublishSheet(
          access: PublishingAccess(
            publisher: Publisher(
              gateway: server,
              keys: keys,
              books: books,
              media: _Media(),
              isConfirmed: () => confirmed,
            ),
            confirm: () async => confirmed = true,
          ),
          entry: entry,
          schema: schema,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('publish-field-pin')), findsNothing);
    expect(find.byKey(const ValueKey('publish-field-body')), findsOneWidget);

    await tap(tester, 'publish-layout-goldenCover');
    await tap(tester, 'publish-confirm');
    await tester.pumpAndSettle();

    expect(server.pages.keys, ['il-faro']);
    final page = server.pages['il-faro']!;
    expect(page['layout'], 'golden_cover');
    expect(page['listed'], isTrue);
    expect(page.toString(), isNot(contains('1234')));
    expect(find.text('https://serv.pub/quaderno/il-faro'), findsOneWidget);
    expect(find.text('Aggiorna la pagina'), findsOneWidget);

    await tap(tester, 'publish-withdraw');
    await tester.pumpAndSettle();
    expect(server.pages, isEmpty);
    expect(find.text('Pagina ritirata'), findsOneWidget);
  });

  group('the site panel', () {
    Future<void> openSite(WidgetTester tester) async {
      books.book = SiteBook(
        name: SiteName('quaderno'),
        settings: SiteSettings(title: 'Quaderno', lang: 'it'),
      );
      final keys = _Keys()..kept.add('quaderno');
      await pumpApp(
        tester,
        Scaffold(
          body: PublishSheet(
            access: PublishingAccess(
              publisher: Publisher(
                gateway: server,
                keys: keys,
                books: books,
                media: _Media(),
                isConfirmed: () => confirmed,
              ),
              confirm: () async {
                confirmations++;
                confirmed = confirms;
                return confirms;
              },
            ),
            entry: entry,
            schema: schema,
          ),
        ),
      );
      await tap(tester, 'publish-site-settings');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('site-preview')), findsOneWidget);
    }

    testWidgets('saves theme, hue, size, font, home and indexing', (
      tester,
    ) async {
      await openSite(tester);
      expect(
        find.text('https://serv.pub/quaderno/feed.xml'),
        findsOneWidget,
        reason: 'the feed is offered',
      );
      await tester.enterText(
        find.byKey(const ValueKey('site-about')),
        'Note di mare.',
      );
      await tap(tester, 'site-theme-paper');
      await tester.pumpAndSettle();
      final accent = find.descendant(
        of: find.byKey(const ValueKey('site-accent-hue')),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(accent);
      await tester.tap(accent);
      await tester.pumpAndSettle();
      await tap(tester, 'site-font-literata');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('20 px'));
      await tester.tap(find.text('20 px'));
      await tester.pumpAndSettle();
      await tap(tester, 'site-home-essay');
      await tester.pumpAndSettle();
      await tap(tester, 'site-indexable');
      await tester.pumpAndSettle();
      await tap(tester, 'site-save');
      await tester.pumpAndSettle();

      expect(confirmations, 1);
      final wire = server.settings.single;
      expect(wire['about'], 'Note di mare.');
      expect(wire['font'], 'literata');
      expect(wire['body'], 20);
      expect(wire['home'], 'essay');
      expect(wire['indexable'], isTrue);
      expect((wire['theme']! as Map)['dark'], isFalse);
      final kept = books.book!.settings;
      expect(kept.theme.base, BaseTheme.paper);
      expect(kept.theme.accentHue, isNotNull);
      expect(kept.font, SiteFont.literata);
      expect(find.text('Sito aggiornato'), findsOneWidget);
      expect(find.byKey(const ValueKey('site-preview')), findsNothing);
    });

    testWidgets('without the confirmation nothing is saved', (tester) async {
      confirms = false;
      await openSite(tester);
      await tap(tester, 'site-font-quattro');
      await tester.pumpAndSettle();
      await tap(tester, 'site-save');
      await tester.pumpAndSettle();
      expect(confirmations, 1);
      expect(server.settings, isEmpty);
      expect(books.book!.settings.font, SiteFont.inter);
    });

    testWidgets('withdraws the whole site only when asked twice', (
      tester,
    ) async {
      await openSite(tester);
      await tap(tester, 'site-withdraw');
      await tester.pumpAndSettle();
      expect(find.textContaining('serv.pub/quaderno'), findsWidgets);
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
      expect(server.deleted, isFalse);
      expect(confirmations, 0);

      await tap(tester, 'site-withdraw');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('site-withdraw-confirm')));
      await tester.pumpAndSettle();
      expect(confirmations, 1);
      expect(server.deleted, isTrue);
      expect(books.book, isNull);
      expect(find.text('Sito ritirato'), findsOneWidget);
      // Back to creating a site.
      expect(find.byKey(const ValueKey('publish-site-name')), findsOneWidget);
    });
  });
}
