import 'dart:math';

import 'package:meta/meta.dart';

import 'publishing_exception.dart';

/// An opaque sRGB colour, 8 bits per channel: what a stylesheet receives.
@immutable
final class Srgb {
  const Srgb._(this.r, this.g, this.b);

  /// From `#RRGGBB` (the `#` optional).
  factory Srgb.hex(String hex) {
    final digits = hex.startsWith('#') ? hex.substring(1) : hex;
    if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(digits)) {
      throw const InvalidColorException();
    }
    final v = int.parse(digits, radix: 16);
    return Srgb._(v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF);
  }

  final int r;
  final int g;
  final int b;

  String get hex =>
      '#${[r, g, b].map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

  /// WCAG 2 relative luminance.
  double get luminance {
    double lin(int c) {
      final s = c / 255;
      return s <= 0.04045
          ? s / 12.92
          : pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  /// WCAG 2 contrast ratio, from 1 to 21.
  double contrastWith(Srgb other) {
    final a = luminance;
    final o = other.luminance;
    return (max(a, o) + 0.05) / (min(a, o) + 0.05);
  }

  @override
  bool operator ==(Object other) =>
      other is Srgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => hex;
}

/// A colour in OKLCH (Björn Ottosson's perceptual space): lightness [l]
/// from 0 to 1, chroma [c], hue [h] in degrees. Equal steps of [l] look
/// equal, which is what lets the palettes put φ in their lightness.
@immutable
final class Oklch {
  const Oklch(this.l, this.c, this.h);

  factory Oklch.of(Srgb color) {
    double lin(int c) {
      final s = c / 255;
      return s <= 0.04045
          ? s / 12.92
          : pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = lin(color.r);
    final g = lin(color.g);
    final b = lin(color.b);
    double cbrt(double x) => x <= 0 ? 0 : pow(x, 1 / 3).toDouble();
    final l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    final a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    final bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    final h = atan2(bb, a) * 180 / pi;
    return Oklch(l, sqrt(a * a + bb * bb), h < 0 ? h + 360 : h);
  }

  final double l;
  final double c;
  final double h;

  Oklch withL(double l) => Oklch(l, c, h);
  Oklch withH(double h) => Oklch(l, c, h % 360);

  /// The nearest sRGB colour; channels outside the gamut are clipped.
  Srgb toSrgb() {
    final a = c * cos(h * pi / 180);
    final b = c * sin(h * pi / 180);
    final l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
    final m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
    final s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3).toDouble();
    int channel(double linear) {
      final x = linear.clamp(0.0, 1.0);
      final encoded = x <= 0.0031308
          ? 12.92 * x
          : 1.055 * pow(x, 1 / 2.4) - 0.055;
      return (encoded * 255).round();
    }

    return Srgb._(
      channel(4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1),
      channel(-1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1),
      channel(-0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1),
    );
  }
}
