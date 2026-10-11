import 'dart:ui';

/// The Modus Notes palette (visual identity, 2026-10-11).
abstract final class ModusColors {
  static const deepVoid = Color(0xFF090C15);
  static const abyssalSlate = Color(0xFF13192B);
  static const aureoGold = Color(0xFFEBB448);
  static const rhythmViolet = Color(0xFF8B3FD6);
  static const cadenceCyan = Color(0xFF00A3FF);
  static const pureMist = Color(0xFFF8FAFC);
  static const dustSilver = Color(0xFF8F9CAE);

  /// Rhythm Violet reaches only 3.2:1 on Abyssal Slate, below WCAG AA for
  /// text; this 20 % tint (4.5:1) is for violet text and icons, while the
  /// original stays the fill colour under Pure Mist text.
  static const rhythmVioletText = Color(0xFFA265DE);

  /// The fourth accent, for dream notes (2026-10-11): apart from gold,
  /// violet and cyan, and above AA as text on both dark backgrounds.
  static const lucidRose = Color(0xFFF07CA8);
}
