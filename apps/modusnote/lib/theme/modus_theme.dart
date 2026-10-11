import 'package:flutter/material.dart';

import 'golden_ratio.dart';
import 'modus_colors.dart';

/// Dark-native Material theme built only from the design tokens.
abstract final class ModusTheme {
  /// Bundled in `assets/fonts` (SIL OFL): no font is fetched at runtime,
  /// which the web client's no-CDN rule requires anyway.
  static const titleFont = 'PlusJakartaSans';
  static const bodyFont = 'Inter';

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: ModusColors.aureoGold,
      onPrimary: ModusColors.deepVoid,
      secondary: ModusColors.rhythmViolet,
      onSecondary: ModusColors.pureMist,
      tertiary: ModusColors.cadenceCyan,
      onTertiary: ModusColors.deepVoid,
      error: Color(0xFFFF8A80),
      onError: ModusColors.deepVoid,
      surface: ModusColors.abyssalSlate,
      onSurface: ModusColors.pureMist,
      onSurfaceVariant: ModusColors.dustSilver,
      outline: ModusColors.dustSilver,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ModusColors.deepVoid,
      textTheme: _textTheme(),
      cardTheme: const CardThemeData(
        color: ModusColors.abyssalSlate,
        margin: EdgeInsets.all(Spacing.s),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.card)),
        ),
      ),
    );
  }

  static TextTheme _textTheme() {
    TextStyle title(double size, FontWeight weight) =>
        _style(titleFont, size, weight, ModusColors.pureMist);
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
      bodyLarge: body(TypeScale.body, ModusColors.pureMist),
      bodyMedium: body(TypeScale.body, ModusColors.pureMist),
      bodySmall: body(TypeScale.caption, ModusColors.dustSilver),
      labelLarge: _style(
        bodyFont,
        TypeScale.body,
        FontWeight.w600,
        ModusColors.pureMist,
      ),
      labelMedium: body(TypeScale.body, ModusColors.dustSilver),
      labelSmall: body(TypeScale.caption, ModusColors.dustSilver),
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
    fontSize: size,
    fontWeight: weight,
    fontVariations: [FontVariation.weight(weight.value.toDouble())],
    color: color,
    height: GoldenRatio.phi,
  );
}
