import 'dart:math';
import 'dart:ui';

/// A colour from OKLCH (Björn Ottosson's perceptual space): lightness
/// [l] from 0 to 1, chroma [c], hue [h] in degrees. Equal steps of [l]
/// look like equal steps of lightness, which is what lets the themes put
/// φ in their lightness rather than in raw RGB. Out-of-gamut channels are
/// clipped; the themes stay well inside sRGB.
Color oklch(double l, double c, double h) {
  final a = c * cos(h * pi / 180);
  final b = c * sin(h * pi / 180);
  final l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
  final m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
  final s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3).toDouble();
  final r = 4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1;
  final g = -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1;
  final bl = -0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1;
  int channel(double linear) {
    final x = linear.clamp(0.0, 1.0);
    final encoded = x <= 0.0031308
        ? 12.92 * x
        : 1.055 * pow(x, 1 / 2.4) - 0.055;
    return (encoded * 255).round();
  }

  return Color.fromARGB(255, channel(r), channel(g), channel(bl));
}

/// The OKLCH lightness of [color], the inverse of [oklch] for it.
double oklchLightness(Color color) {
  double linear(double c) =>
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(color.r);
  final g = linear(color.g);
  final b = linear(color.b);
  final l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  final m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  final s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  double cbrt(double x) => pow(x, 1 / 3).toDouble();
  return 0.2104542553 * cbrt(l) +
      0.7936177850 * cbrt(m) -
      0.0040720468 * cbrt(s);
}
