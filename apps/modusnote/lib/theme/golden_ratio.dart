/// The only source of sizes in the UI: every spacing, radius, font size
/// and split derives from φ, so widgets never write numbers by hand.
abstract final class GoldenRatio {
  static const phi = 1.6180339887498949;
}

/// 8 dp × φⁿ, rounded to whole dp (Fibonacci numbers, as it happens).
abstract final class Spacing {
  static const double xxs = 3;
  static const double xs = 5;
  static const double s = 8;
  static const double m = 13;
  static const double l = 21;
  static const double xl = 34;
  static const double xxl = 55;

  static const all = [xxs, xs, s, m, l, xl, xxl];
}

/// 16 sp × φⁿ.
abstract final class TypeScale {
  static const double caption = 10;
  static const double body = 16;
  static const double title2 = 26;
  static const double title1 = 42;
  static const double display = 68;

  static const all = [caption, body, title2, title1, display];
}

/// Screen and column divisions: 61.8 % main content, 38.2 % secondary.
abstract final class LayoutSplit {
  static const primary = GoldenRatio.phi - 1;
  static const secondary = 2 - GoldenRatio.phi;
}

abstract final class Radii {
  static const double small = Spacing.xs;
  static const double card = Spacing.m;
  static const double sheet = Spacing.l;

  static const all = [small, card, sheet];
}

/// The spacing scale continued for content blocks: card widths, column
/// widths and breakpoints.
abstract final class Extents {
  static const double s = 89;
  static const double m = 144;
  static const double l = 233;
  static const double xl = 377;
  static const double xxl = 610;
  static const double xxxl = 987;

  static const all = [s, m, l, xl, xxl, xxxl];
}

abstract final class IconSizes {
  static const double inline = Spacing.l;
  static const double prominent = Spacing.xl;
}
