import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'media.dart';
import 'names.dart';
import 'publishing_exception.dart';
import 'site_settings.dart';

/// One note's page on the site, as this device last published it.
@immutable
final class PublishedPage {
  PublishedPage({
    required this.slug,
    required this.title,
    required this.listed,
    required List<MediaId> media,
    required this.at,
  }) : media = List.unmodifiable(media);

  final PageSlug slug;
  final String title;

  /// False while it is only a draft to look at: reachable by its address,
  /// absent from the home and never indexed.
  final bool listed;

  /// The files uploaded for it, deleted when it is published again or
  /// withdrawn.
  final List<MediaId> media;
  final DateTime at;

  Map<String, Object> toJson() => {
    'slug': slug.value,
    'title': title,
    'listed': listed,
    'media': [for (final id in media) id.value],
    'at': at.toUtc().millisecondsSinceEpoch,
  };

  static PublishedPage fromJson(Object? json) {
    if (json case {
      'slug': final String slug,
      'title': final String title,
      'listed': final bool listed,
      'media': final List<Object?> media,
      'at': final int at,
    }) {
      return PublishedPage(
        slug: PageSlug(slug),
        title: title,
        listed: listed,
        media: [
          for (final id in media) id is String ? MediaId(id) : throw _malformed,
        ],
        at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      );
    }
    throw _malformed;
  }
}

/// What this device knows of its site on serv.pub: its name, its settings
/// and the pages of its notes. Kept sealed in the vault, never synced: the
/// site's key lives beside it and nowhere else.
@immutable
final class SiteBook {
  SiteBook({
    required this.name,
    required this.settings,
    Map<EntryId, PublishedPage> pages = const {},
  }) : pages = Map.unmodifiable(pages);

  final SiteName name;
  final SiteSettings settings;
  final Map<EntryId, PublishedPage> pages;

  Uri get home => Uri.parse('${name.url}/');

  Uri pageUrl(PageSlug slug) => Uri.parse('${name.url}/${slug.value}');

  /// The note each published page shows, for links between them.
  Map<EntryId, PageSlug> get slugs => {
    for (final MapEntry(:key, :value) in pages.entries)
      if (value.listed) key: value.slug,
  };

  SiteBook withSettings(SiteSettings settings) =>
      SiteBook(name: name, settings: settings, pages: pages);

  /// With [entry]'s page, or without it when [page] is null.
  SiteBook withPage(EntryId entry, PublishedPage? page) {
    final next = {...pages}..remove(entry);
    if (page != null) next[entry] = page;
    return SiteBook(name: name, settings: settings, pages: next);
  }

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'name': name.value,
        'settings': settings.toJson(),
        'pages': {
          for (final MapEntry(:key, :value) in pages.entries)
            key.value: value.toJson(),
        },
      }),
    ),
  );

  /// Throws [NotPublishableException] for anything this version would not
  /// have written.
  static SiteBook fromBytes(Uint8List bytes) {
    try {
      if (jsonDecode(utf8.decode(bytes)) case {
        'v': 1,
        'name': final String name,
        'settings': final Object settings,
        'pages': final Map<String, Object?> pages,
      }) {
        return SiteBook(
          name: SiteName(name),
          settings: SiteSettings.fromJson(settings),
          pages: {
            for (final MapEntry(:key, :value) in pages.entries)
              EntryId(key): PublishedPage.fromJson(value),
          },
        );
      }
    } on FormatException {
      throw _malformed;
    } on PublishingException {
      throw _malformed;
    } on ArgumentError {
      throw _malformed;
    } on InvalidSchemaException {
      throw _malformed;
    }
    throw _malformed;
  }
}

const _malformed = NotPublishableException('malformed site book');
