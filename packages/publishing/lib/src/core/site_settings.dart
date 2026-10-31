import 'package:meta/meta.dart';

import 'layout.dart';
import 'page_document.dart';
import 'publishing_exception.dart';
import 'site_palette.dart';
import 'typography.dart';

/// What a site says about itself and how it looks, as serv.pub takes it
/// (`PUT /api/s/<site>`): the colours travel already derived and checked
/// ([SitePalette]), so the server only checks the contrast again.
@immutable
final class SiteSettings {
  SiteSettings({
    required String title,
    String about = '',
    required this.lang,
    this.theme = const SiteTheme(BaseTheme.modus),
    this.body = BodySize.medium,
    this.home = PublicationLayout.collection,
    this.indexable = false,
    this.font = SiteFont.inter,
  }) : title = PageComposer.line(title, maxTitle),
       about = _about(about) {
    if (this.title.isEmpty) {
      throw const NotPublishableException('a site needs a title');
    }
    if (!_lang.hasMatch(lang)) {
      throw const NotPublishableException('not a language');
    }
    if (home != PublicationLayout.collection &&
        home != PublicationLayout.essay) {
      throw const NotPublishableException('not a home layout');
    }
  }

  static const maxTitle = 89;
  static const maxAbout = 2584;
  static final _lang = RegExp(r'^[a-z]{2}$');
  static final _unsafe = RegExp(
    r'[\x00-\x08\x0B-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\u2028\u2029]',
  );

  final String title;
  final String about;

  /// Two lowercase letters, the language of the site's pages.
  final String lang;
  final SiteTheme theme;
  final BodySize body;
  final PublicationLayout home;

  /// Whether search engines may index the site's listed pages; off until
  /// the person turns it on.
  final bool indexable;

  /// The body's typeface.
  final SiteFont font;

  SiteSettings copyWith({
    String? title,
    String? about,
    String? lang,
    SiteTheme? theme,
    BodySize? body,
    PublicationLayout? home,
    bool? indexable,
    SiteFont? font,
  }) => SiteSettings(
    title: title ?? this.title,
    about: about ?? this.about,
    lang: lang ?? this.lang,
    theme: theme ?? this.theme,
    body: body ?? this.body,
    home: home ?? this.home,
    indexable: indexable ?? this.indexable,
    font: font ?? this.font,
  );

  /// The wire format of serv.pub.
  Map<String, Object> toWire() {
    final palette = SitePalette.of(theme);
    return {
      'title': title,
      'about': about,
      'lang': lang,
      'theme': {
        'dark': palette.isDark,
        'background': palette.background.hex,
        'surface': palette.surface.hex,
        'text': palette.text.hex,
        'secondary': palette.secondaryText.hex,
        'accent': palette.accent.hex,
        'second_accent': palette.secondAccent.hex,
      },
      'body': body.px,
      'home': home == PublicationLayout.essay ? 'essay' : 'collection',
      'indexable': indexable,
      'font': font.wire,
    };
  }

  /// What the device keeps: the choices, not the derived colours.
  Map<String, Object?> toJson() => {
    'title': title,
    'about': about,
    'lang': lang,
    'base': theme.base.name,
    'accentHue': theme.accentHue,
    'backgroundHue': theme.backgroundHue,
    'body': body.px,
    'home': home.name,
    'indexable': indexable,
    'font': font.wire,
  };

  /// Throws [NotPublishableException] or [InvalidColorException] for
  /// anything this version would not have written.
  static SiteSettings fromJson(Object? json) {
    if (json case {
      'title': final String title,
      'about': final String about,
      'lang': final String lang,
      'base': final String base,
      'accentHue': final num? accentHue,
      'backgroundHue': final num? backgroundHue,
      'body': final int body,
      'home': final String home,
      'indexable': final bool indexable,
    }) {
      // Absent from what was kept before fonts were a choice.
      final font = switch (json['font']) {
        null => SiteFont.inter,
        final String wire => SiteFont.values.firstWhere(
          (f) => f.wire == wire,
          orElse: () => throw const NotPublishableException('font'),
        ),
        _ => throw const NotPublishableException('font'),
      };
      return SiteSettings(
        title: title,
        about: about,
        lang: lang,
        theme: SiteTheme.checked(
          BaseTheme.values.firstWhere(
            (b) => b.name == base,
            orElse: () => throw const InvalidColorException(),
          ),
          accentHue: accentHue?.toDouble(),
          backgroundHue: backgroundHue?.toDouble(),
        ),
        body: BodySize.values.firstWhere(
          (b) => b.px == body,
          orElse: () => throw const NotPublishableException('body size'),
        ),
        home: PublicationLayout.values.firstWhere(
          (l) => l.name == home,
          orElse: () => throw const NotPublishableException('home layout'),
        ),
        indexable: indexable,
        font: font,
      );
    }
    throw const NotPublishableException('malformed site settings');
  }

  static String _about(String about) {
    var safe = about.replaceAll(_unsafe, ' ').trim();
    if (safe.length > maxAbout) {
      var cut = maxAbout;
      final last = safe.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut--;
      safe = safe.substring(0, cut).trim();
    }
    return safe;
  }

  @override
  bool operator ==(Object other) =>
      other is SiteSettings &&
      other.title == title &&
      other.about == about &&
      other.lang == lang &&
      other.theme == theme &&
      other.body == body &&
      other.home == home &&
      other.indexable == indexable &&
      other.font == font;

  @override
  int get hashCode =>
      Object.hash(title, about, lang, theme, body, home, indexable, font);
}
