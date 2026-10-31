import 'dart:math';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/layout.dart';
import '../core/media.dart';
import '../core/names.dart';
import '../core/page_document.dart';
import '../core/publication_policy.dart';
import '../core/publishing_exception.dart';
import '../core/site_book.dart';
import '../core/site_settings.dart';
import 'ports.dart';

/// Use case: this device's site on serv.pub, and the notes it publishes
/// there.
///
/// Publishing makes a snapshot of a note readable by anyone, so every step
/// that puts something on the site (claiming it, changing its settings,
/// publishing a page, even as a draft) and withdrawing the whole site
/// need the person to have proved again, at the device, that the vault is
/// theirs ([isConfirmed]): whoever only found the vault open cannot
/// publish it. Withdrawing one page needs nothing: it only takes away.
final class Publisher {
  Publisher({
    required this._gateway,
    required this._keys,
    required this._books,
    required this._media,
    required this._isConfirmed,
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  final SiteGateway _gateway;
  final SiteKeys _keys;
  final SiteBookStore _books;
  final PublicationMedia _media;
  final bool Function() _isConfirmed;
  final Random _random;
  final DateTime Function() _now;

  /// The site, or null before one is claimed.
  Future<SiteBook?> book() => _books.load();

  /// Takes [name] on serv.pub with a new key of its own. The key is kept
  /// before the name is asked for, so a claim that did not get an answer
  /// can be repeated with the same key. Throws [SiteNameTakenException].
  Future<SiteBook> claim(SiteName name, SiteSettings settings) async {
    _requireConfirmed();
    if (await _books.load() != null) {
      throw const NotPublishableException('the vault has a site');
    }
    final key = await _keys.open(name) ?? await _keys.create(name);
    try {
      await _gateway.claim(key, name, settings.toWire());
    } on SiteNameTakenException {
      await _keys.forget(name);
      rethrow;
    } finally {
      key.release();
    }
    final book = SiteBook(name: name, settings: settings);
    await _books.save(book);
    return book;
  }

  Future<SiteBook> updateSettings(SiteSettings settings) async {
    _requireConfirmed();
    final book = await _site();
    await _withKey(
      book,
      (key) => _gateway.putSettings(key, book.name, settings.toWire()),
    );
    final next = book.withSettings(settings);
    await _books.save(next);
    return next;
  }

  /// Publishes [content], the snapshot of note [entry] made by
  /// [PublicationPolicy.compose], as a page the site lists. The page keeps
  /// its address when published again; its files are uploaded anew and
  /// the old ones deleted, and so is the note's draft. Returns the page's
  /// address.
  ///
  /// As a [draft] (a preview) it goes to an address of its own, the
  /// title's followed by 50 random bits, so nobody finds it by guessing
  /// before the person decides; the site does not list it, search engines
  /// are told not to index it, and the live page, if any, stays as it is.
  Future<Uri> publish({
    required EntryId entry,
    required PublicationContent content,
    required SchemaDefinition schema,
    required String Function(FieldDefinition field) labelOf,
    required String Function(FieldDefinition field, FieldValue value) describe,
    bool draft = false,
    PublicationLayout? layout,
  }) async {
    _requireConfirmed();
    final book = await _site();
    final page = book.pages[entry];
    final previousDraft = book.drafts[entry];
    final slug = draft
        ? _draftSlug(content.slug, book.taken)
        : page?.slug ?? content.slug.freeAmong(book.taken);
    final published = await _withKey(book, (key) async {
      final uploaded = <BlobId, MediaId>{};
      try {
        for (final blob in {...content.images, ...content.audio}) {
          final prepared = await _media.prepare(blob);
          if (prepared == null) continue;
          final id = MediaId.random(_random);
          await _gateway.putMedia(
            key,
            book.name,
            id,
            prepared.kind,
            prepared.bytes,
          );
          uploaded[blob] = id;
        }
        final document = PageComposer.compose(
          content: content,
          schema: schema,
          media: uploaded,
          labelOf: labelOf,
          describe: describe,
          listed: !draft,
          layout: layout,
        );
        await _gateway.putPage(key, book.name, slug, document.toJson());
        return PublishedPage(
          slug: slug,
          title: document.title,
          listed: !draft,
          media: document.media,
          at: _now().toUtc(),
        );
      } catch (_) {
        await _deleteQuietly(key, book, uploaded.values);
        rethrow;
      }
    });
    // A draft replaces the note's earlier draft; a page replaces its
    // earlier self and every draft of the note.
    await _books.save(
      draft
          ? book.withDraft(entry, published)
          : book.withPage(entry, published).withDraft(entry, null),
    );
    await _withKey(book, (key) async {
      final stale = draft ? null : page;
      if (previousDraft != null) {
        await _deletePageQuietly(key, book, previousDraft.slug);
        await _deleteQuietly(key, book, previousDraft.media);
      }
      if (stale != null) {
        await _deleteQuietly(
          key,
          book,
          stale.media.where((id) => !published.media.contains(id)),
        );
      }
    });
    return book.pageUrl(slug);
  }

  /// Takes [entry]'s page and draft off the site, with their files.
  Future<void> withdraw(EntryId entry) async {
    final book = await _site();
    final page = book.pages[entry];
    final draft = book.drafts[entry];
    if (page == null && draft == null) return;
    await _withKey(book, (key) async {
      if (page != null) {
        await _gateway.deletePage(key, book.name, page.slug);
        await _deleteQuietly(key, book, page.media);
      }
      if (draft != null) {
        await _deletePageQuietly(key, book, draft.slug);
        await _deleteQuietly(key, book, draft.media);
      }
    });
    await _books.save(book.withPage(entry, null).withDraft(entry, null));
  }

  /// Withdraws the whole site: serv.pub deletes its pages and files and
  /// the name is free again. Copies others made stay theirs.
  Future<void> withdrawSite() async {
    _requireConfirmed();
    final book = await _site();
    await _withKey(book, (key) => _gateway.deleteSite(key, book.name));
    await _books.save(null);
    await _keys.forget(book.name);
  }

  void _requireConfirmed() {
    if (!_isConfirmed()) {
      throw const PublishingConfirmationRequiredException();
    }
  }

  Future<SiteBook> _site() async =>
      await _books.load() ?? (throw const NoSiteException());

  Future<T> _withKey<T>(SiteBook book, Future<T> Function(SiteKey) use) async {
    final key = await _keys.open(book.name) ?? (throw const NoSiteException());
    try {
      return await use(key);
    } finally {
      key.release();
    }
  }

  /// A draft nobody needs any more: like a file, left behind on failure.
  Future<void> _deletePageQuietly(
    SiteKey key,
    SiteBook book,
    PageSlug slug,
  ) async {
    try {
      await _gateway.deletePage(key, book.name, slug);
    } on PublishingException {
      // Left behind, unlisted.
    }
  }

  /// The title's address followed by ten random symbols (50 bits).
  PageSlug _draftSlug(PageSlug base, Set<PageSlug> taken) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    while (true) {
      final suffix = List.generate(
        10,
        (_) => alphabet[_random.nextInt(alphabet.length)],
      ).join();
      final room = PageSlug.maxLength - suffix.length - 1;
      final head = base.value.length > room
          ? base.value.substring(0, room).replaceAll(RegExp(r'-+$'), '')
          : base.value;
      final slug = PageSlug('$head-$suffix');
      if (!taken.contains(slug)) return slug;
    }
  }

  /// Files no page shows any more: a failure leaves them on the site,
  /// within its limits, and is no reason to fail what already succeeded.
  Future<void> _deleteQuietly(
    SiteKey key,
    SiteBook book,
    Iterable<MediaId> ids,
  ) async {
    for (final id in ids.toList()) {
      try {
        await _gateway.deleteMedia(key, book.name, id);
      } on PublishingException {
        // Left behind.
      }
    }
  }
}
