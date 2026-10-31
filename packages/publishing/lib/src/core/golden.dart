import 'dart:math';

/// The golden ratio and what the published pages derive from it.
abstract final class Golden {
  static final double phi = (1 + sqrt(5)) / 2;

  /// The golden section of a whole: 61.8 % and 38.2 %.
  static final double major = 1 / phi;
  static final double minor = 1 / (phi * phi);

  /// The golden angle, 360°/φ², which spaces accent hues.
  static final double angle = 360 / (phi * phi);

  /// One step of OKLCH lightness between a background and its surface:
  /// 1/φ⁶ ≈ 0.056.
  static final double lightnessStep = 1 / pow(phi, 6);

  /// Margins, gaps and widths in px: the Fibonacci scale.
  static const spacing = [3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987];
}
