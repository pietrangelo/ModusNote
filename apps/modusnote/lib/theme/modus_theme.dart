import 'package:flutter/material.dart';

import 'golden_ratio.dart';
import 'modus_palette.dart';

/// Dark-native Material theme built only from the design tokens.
abstract final class ModusTheme {
  /// Bundled in `assets/fonts` (SIL OFL): no font is fetched at runtime,
  /// which the web client's no-CDN rule requires anyway.
  static const titleFont = 'PlusJakartaSans';
  static const bodyFont = 'Inter';

  /// The music signs (♩ ♪ ♫ ♬ ♭ ♮ ♯) cut from Noto Sans Symbols: neither
  /// font above has them, and without a bundled fallback Flutter on the
  /// web would try to download one from Google.
  static const symbolFont = 'NotoSansSymbols';

  static ThemeData dark() => of(ModusPalette.modus);

  /// The Material theme of [palette], which it also carries for widgets;
  /// built once per palette.
  static ThemeData of(ModusPalette palette) =>
      _built[palette] ??= _build(palette);

  static final _built = Expando<ThemeData>();

  static ThemeData _build(ModusPalette palette) {
    final scheme = ColorScheme(
      brightness: palette.brightness,
      primary: palette.primary,
      onPrimary: palette.onAccent,
      secondary: palette.violetFill,
      onSecondary: palette.onVioletFill,
      tertiary: palette.success,
      onTertiary: palette.onAccent,
      error: palette.error,
      onError: palette.onAccent,
      surface: palette.surface,
      onSurface: palette.text,
      onSurfaceVariant: palette.muted,
      outline: palette.muted,
    );
    final textTheme = _textTheme(palette);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [palette],
      scaffoldBackgroundColor: palette.background,
      textTheme: textTheme,
      // Material lays the date picker's header out in a fixed 120 dp box,
      // sized for its own 32 sp headline; a title 1 at the golden line
      // height does not fit, a title 2 does.
      datePickerTheme: DatePickerThemeData(
        headerHeadlineStyle: textTheme.headlineMedium,
        headerHelpStyle: textTheme.labelMedium,
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        margin: const EdgeInsets.all(Spacing.s),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.card)),
        ),
      ),
    );
  }

  static TextTheme _textTheme(ModusPalette palette) {
    TextStyle title(double size, FontWeight weight) =>
        _style(titleFont, size, weight, palette.text);
    TextStyle body(double size, Color color) =>
        _style(bodyFont, size, FontWeight.w400, color);

    return TextTheme(
      displayLarge: title(TypeScale.display, FontWeight.w700),
      displayMedium: title(TypeScale.title1, FontWeight.w700),
      displaySmall: title(TypeScale.title1, FontWeight.w600),
      headlineLarge: title(TypeScale.title1, FontWeight.w700),
      headlineMedium: title(TypeScale.title2, FontWeight.w700),
      headlineSmall: title(TypeScale.title2, FontWeight.w600),
      titleLarge: title(TypeScale.title2, FontWeight.w600),
      titleMedium: title(TypeScale.body, FontWeight.w600),
      titleSmall: title(TypeScale.body, FontWeight.w500),
      bodyLarge: body(TypeScale.body, palette.text),
      bodyMedium: body(TypeScale.body, palette.text),
      bodySmall: body(TypeScale.caption, palette.muted),
      labelLarge: _style(
        bodyFont,
        TypeScale.body,
        FontWeight.w600,
        palette.text,
      ),
      labelMedium: body(TypeScale.body, palette.muted),
      labelSmall: body(TypeScale.caption, palette.muted),
    );
  }

  /// Variable fonts: the weight is set on the `wght` axis as well, since
  /// not every platform maps [FontWeight] onto it.
  static TextStyle _style(
    String family,
    double size,
    FontWeight weight,
    Color color,
  ) => TextStyle(
    fontFamily: family,
    fontFamilyFallback: const [symbolFont],
    fontSize: size,
    fontWeight: weight,
    fontVariations: [FontVariation.weight(weight.value.toDouble())],
    color: color,
    height: GoldenRatio.phi,
  );
}
