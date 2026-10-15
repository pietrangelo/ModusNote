import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/appearance_scope.dart';
import 'package:modusnote/l10n/generated/app_localizations.dart';
import 'package:modusnote/theme/modus_theme.dart';

/// Pumps [child] inside the app's theme and localizations, in Italian
/// unless told otherwise, on a phone-sized surface.
///
/// With [appearance] the app holds it above the navigator, as `main` does;
/// [size] is in logical pixels.
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('it'),
  AppearanceSettings? appearance,
  Size size = const Size(360, 780),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final app = MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ModusTheme.dark(),
    home: child,
  );
  await tester.pumpWidget(
    appearance == null
        ? app
        : AppearanceScope(settings: appearance, child: app),
  );
  await tester.pumpAndSettle();
}

Finder fieldFinder(String key) => find.byKey(ValueKey('field-$key'));

/// The editable text inside the field named [key].
Finder textInput(String key) =>
    find.descendant(of: fieldFinder(key), matching: find.byType(EditableText));
