import 'package:meta/meta.dart';

import 'publishing_exception.dart';

final _name = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// The short name of a site, its address on serv.pub: `serv.pub/<name>`.
/// ASCII letters and digits only, so no two names look alike (no Cyrillic
/// `а` for a Latin `a`), with single inner hyphens.
@immutable
final class SiteName {
  SiteName(this.value) {
    if (value.length < minLength ||
        value.length > maxLength ||
        !_name.hasMatch(value) ||
        reserved.contains(value)) {
      throw const InvalidSiteNameException();
    }
  }

  static const minLength = 3;

  /// A Fibonacci number, like every bound of the platform.
  static const maxLength = 34;

  /// Paths the platform serves itself, and names that would pass for it.
  static const reserved = {
    'about',
    'abuse',
    'admin',
    'api',
    'app',
    'assets',
    'blog',
    'contact',
    'feed',
    'fonts',
    'help',
    'info',
    'legal',
    'login',
    'modus',
    'modusnote',
    'modusnotes',
    'official',
    'privacy',
    'report',
    'robots',
    'rss',
    'security',
    'segnala',
    'serv',
    'servpub',
    'sitemap',
    'static',
    'status',
    'support',
    'terms',
    'well-known',
    'www',
  };

  final String value;

  String get url => 'https://serv.pub/$value';

  @override
  bool operator ==(Object other) => other is SiteName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The address of a page inside its site: `serv.pub/<site>/<slug>`.
@immutable
final class PageSlug {
  PageSlug(this.value) {
    if (value.isEmpty || value.length > maxLength || !_name.hasMatch(value)) {
      throw const InvalidPageSlugException();
    }
  }

  /// Made from [title]: lowercase, Latin accents folded, everything else a
  /// hyphen; a title with nothing usable reads `pagina`.
  factory PageSlug.fromTitle(String title) {
    final out = StringBuffer();
    for (final rune in title.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      final folded = _fold[char] ?? char;
      out.write(_name.hasMatch(folded) ? folded : '-');
    }
    var slug = out.toString().replaceAll(RegExp('-+'), '-');
    slug = _trimHyphens(slug);
    if (slug.length > maxLength) {
      slug = _trimHyphens(slug.substring(0, maxLength));
    }
    return PageSlug(slug.isEmpty ? fallback : slug);
  }

  static const maxLength = 89;
  static const fallback = 'pagina';

  /// The address of a site's cookbook.
  static const cookbook = 'ricette';

  /// Addresses inside a site that are not pages.
  static const reserved = {cookbook};

  final String value;

  /// Whether serv.pub keeps this address for itself.
  bool get isReserved => reserved.contains(value);

  /// This slug, or the first `<slug>-<n>` from 2 up that [taken] lacks;
  /// never a [reserved] one.
  PageSlug freeAmong(Set<PageSlug> taken) {
    if (!taken.contains(this) && !isReserved) return this;
    for (var n = 2; ; n++) {
      final suffix = '-$n';
      final base = value.length + suffix.length > maxLength
          ? _trimHyphens(value.substring(0, maxLength - suffix.length))
          : value;
      final candidate = PageSlug('$base$suffix');
      if (!taken.contains(candidate)) return candidate;
    }
  }

  static String _trimHyphens(String s) => s.replaceAll(RegExp(r'^-+|-+$'), '');

  static const _fold = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'ā': 'a',
    'æ': 'ae',
    'ç': 'c',
    'č': 'c',
    'ć': 'c',
    'ď': 'd',
    'đ': 'd',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ē': 'e',
    'ě': 'e',
    'ę': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ī': 'i',
    'ł': 'l',
    'ñ': 'n',
    'ń': 'n',
    'ň': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ø': 'o',
    'ō': 'o',
    'œ': 'oe',
    'ř': 'r',
    'ß': 'ss',
    'š': 's',
    'ś': 's',
    'ť': 't',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ū': 'u',
    'ů': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ž': 'z',
    'ź': 'z',
    'ż': 'z',
  };

  @override
  bool operator ==(Object other) => other is PageSlug && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
