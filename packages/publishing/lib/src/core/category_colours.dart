import 'dart:math';

import 'package:meta/meta.dart';

import 'color.dart';
import 'golden.dart';
import 'site_palette.dart';

/// The colours of a cookbook's category, the same that serv.pub gives it
/// (`server/crates/publish/src/colour.rs`): the palette's accent turned by
/// the golden angle once more than the category before it, then moved in
/// lightness until it reads (4.5:1) on the background and the surface, and
/// a tint of the background leaning toward the same hue that keeps the
/// text at 7:1. A book printed from the app and the site it came from show
/// a category in one colour.
@immutable
final class CategoryColours {
  const CategoryColours(this.accent, this.tint);

  /// The colours of the category that came [order]-th (from 0) under
  /// [palette].
  factory CategoryColours.of(SitePalette palette, int order) {
    final background = palette.background;
    final surface = palette.surface;
    final text = palette.text;
    final base = Oklch.of(palette.accent);
    final hue = (base.h + Golden.angle * order) % 360;
    final chroma = max(base.c, 0.12);
    final direction = palette.isDark ? 1.0 : -1.0;
    Srgb? accent;
    for (var step = 0; step <= 100; step++) {
      final lightness = (base.l + direction * 0.01 * step).clamp(0.0, 1.0);
      final colour = inGamut(lightness, chroma, hue);
      if (colour.contrastWith(background) >= otherContrast &&
          colour.contrastWith(surface) >= otherContrast) {
        accent = colour;
        break;
      }
    }
    final reads = accent ?? text;
    final ground = Oklch.of(background).l;
    final lean = palette.isDark ? 0.04 : -0.03;
    var tint = background;
    for (final c in const [0.035, 0.025, 0.015]) {
      final t = inGamut((ground + lean).clamp(0.0, 1.0), c, hue);
      if (text.contrastWith(t) >= textContrast &&
          reads.contrastWith(t) >= otherContrast) {
        tint = t;
        break;
      }
    }
    return CategoryColours(reads, tint);
  }

  /// Headings, numbers and links of the category.
  final Srgb accent;

  /// Its bands and the ground of its boxes.
  final Srgb tint;

  static const textContrast = 7.0;
  static const otherContrast = 4.5;

  /// The colour at [l], [h] with the most chroma up to [c] that sRGB shows.
  static Srgb inGamut(double l, double c, double h) {
    var chroma = c;
    while (true) {
      final rgb = _linear(l, chroma, h);
      if (rgb.every((v) => v >= -1e-4 && v <= 1 + 1e-4) || chroma <= 0) {
        int channel(double v) {
          final x = v.clamp(0.0, 1.0);
          final encoded = x <= 0.0031308
              ? 12.92 * x
              : 1.055 * pow(x, 1 / 2.4) - 0.055;
          return (encoded * 255).round();
        }

        return Srgb.hex(
          rgb.map((v) => channel(v).toRadixString(16).padLeft(2, '0')).join(),
        );
      }
      chroma -= 0.005;
    }
  }

  static List<double> _linear(double l, double c, double h) {
    final a = c * cos(h * pi / 180);
    final b = c * sin(h * pi / 180);
    final l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
    final m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
    final s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3).toDouble();
    return [
      4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1,
      -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1,
      -0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is CategoryColours && other.accent == accent && other.tint == tint;

  @override
  int get hashCode => Object.hash(accent, tint);

  @override
  String toString() => 'CategoryColours($accent, $tint)';
}
