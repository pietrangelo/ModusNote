import 'package:meta/meta.dart';

import 'color.dart';
import 'golden.dart';
import 'publishing_exception.dart';

/// The themes of the app, offered to published pages too, so a page looks
/// like the note it comes from; and Fresco, a cookbook's: a warm cream
/// with livelier colours that let the photos of the dishes stand out, or
/// its evening version on a dark ground.
enum BaseTheme { modus, restful, paper, fresco, frescoDark }

/// What a site chooses about colour: a base theme and, optionally, the hue
/// of its accent and of its background. Only hues: lightness and chroma
/// come from the theme, so no choice can be garish or unreadable.
@immutable
final class SiteTheme {
  const SiteTheme(this.base, {this.accentHue, this.backgroundHue})
    : assert(accentHue == null || (accentHue >= 0 && accentHue < 360)),
      assert(
        backgroundHue == null || (backgroundHue >= 0 && backgroundHue < 360),
      );

  /// Validates hues coming from outside (a form, the wire).
  factory SiteTheme.checked(
    BaseTheme base, {
    double? accentHue,
    double? backgroundHue,
  }) {
    for (final hue in [accentHue, backgroundHue]) {
      if (hue != null && !(hue >= 0 && hue < 360)) {
        throw const InvalidColorException();
      }
    }
    return SiteTheme(base, accentHue: accentHue, backgroundHue: backgroundHue);
  }

  final BaseTheme base;
  final double? accentHue;
  final double? backgroundHue;

  @override
  bool operator ==(Object other) =>
      other is SiteTheme &&
      other.base == base &&
      other.accentHue == accentHue &&
      other.backgroundHue == backgroundHue;

  @override
  int get hashCode => Object.hash(base, accentHue, backgroundHue);
}

/// The colours of a published page, derived from a [SiteTheme] with φ in
/// OKLCH and checked against WCAG 2:
///
/// * a tinted background keeps the theme's lightness; its surface sits one
///   golden step (1/φ⁶) above it on dark themes, below it on light ones;
/// * a custom accent takes the theme accent's lightness and chroma;
/// * the second accent sits at the golden angle (≈137.5°) from the first;
/// * body text is held at 7:1 or more (AAA), everything else at 4.5:1 (AA)
///   on both background and surface: a colour that falls short is moved
///   away from the background in lightness until it passes.
@immutable
final class SitePalette {
  const SitePalette._({
    required this.isDark,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.accent,
    required this.secondAccent,
  });

  factory SitePalette.of(SiteTheme theme) {
    final base = _bases[theme.base]!;
    var background = Srgb.hex(base.background);
    var surface = Srgb.hex(base.surface);
    if (theme.backgroundHue case final hue?) {
      final l = Oklch.of(background).l;
      final step = base.dark ? Golden.lightnessStep : -Golden.lightnessStep;
      background = Oklch(l, _groundChroma, hue).toSrgb();
      surface = Oklch(l + step, _groundChroma, hue).toSrgb();
    }
    final grounds = [background, surface];
    var accent = Oklch.of(Srgb.hex(base.accent));
    if (theme.accentHue case final hue?) accent = accent.withH(hue);
    final second = accent.withH(accent.h + Golden.angle);
    Srgb ensure(Oklch colour, double ratio) =>
        _ensure(colour, ratio, grounds, lighter: base.dark);
    return SitePalette._(
      isDark: base.dark,
      background: background,
      surface: surface,
      text: ensure(Oklch.of(Srgb.hex(base.text)), 7),
      secondaryText: ensure(Oklch.of(Srgb.hex(base.secondary)), 4.5),
      accent: ensure(accent, 4.5),
      secondAccent: ensure(second, 4.5),
    );
  }

  final bool isDark;
  final Srgb background;
  final Srgb surface;
  final Srgb text;
  final Srgb secondaryText;
  final Srgb accent;
  final Srgb secondAccent;

  static const _groundChroma = 0.02;

  static Srgb _ensure(
    Oklch colour,
    double ratio,
    List<Srgb> grounds, {
    required bool lighter,
  }) {
    var c = colour;
    for (var i = 0; i < 100; i++) {
      final rgb = c.toSrgb();
      if (grounds.every((g) => rgb.contrastWith(g) >= ratio)) return rgb;
      c = c.withL((c.l + (lighter ? 0.01 : -0.01)).clamp(0.0, 1.0));
    }
    return lighter ? Srgb.hex('#FFFFFF') : Srgb.hex('#000000');
  }

  static const _bases = {
    BaseTheme.modus: _Base(
      dark: true,
      background: '#090C15',
      surface: '#13192B',
      text: '#F8FAFC',
      secondary: '#8F9CAE',
      accent: '#EBB448',
    ),
    BaseTheme.restful: _Base(
      dark: true,
      background: '#0A1520',
      surface: '#0E1B28',
      text: '#E4DDD1',
      secondary: '#A7A093',
      accent: '#DCB87A',
    ),
    BaseTheme.paper: _Base(
      dark: false,
      background: '#F9EEE0',
      surface: '#E9DDCC',
      text: '#262F38',
      secondary: '#57606A',
      accent: '#7B5600',
    ),
    BaseTheme.fresco: _Base(
      dark: false,
      background: '#FBF8F1',
      surface: '#FFFFFF',
      text: '#1D1A16',
      secondary: '#5E574C',
      accent: '#A9461B',
    ),
    BaseTheme.frescoDark: _Base(
      dark: true,
      background: '#13161D',
      surface: '#1B1F28',
      text: '#F4F1EA',
      secondary: '#AFA899',
      accent: '#E6905A',
    ),
  };
}

final class _Base {
  const _Base({
    required this.dark,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondary,
    required this.accent,
  });

  final bool dark;
  final String background;
  final String surface;
  final String text;
  final String secondary;
  final String accent;
}
