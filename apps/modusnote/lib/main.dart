import 'package:flutter/material.dart';

import 'appearance/appearance_scope.dart';
import 'bootstrap/home.dart';
import 'l10n/generated/app_localizations.dart';
import 'theme/modus_theme.dart';
import 'theme/modus_themes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (:home, :themes) = await buildHome();
  runApp(
    ModusNoteApp(
      home: home,
      appearance: AppearanceSettings(themeMemory: themes),
    ),
  );
}

class ModusNoteApp extends StatelessWidget {
  const ModusNoteApp({required this.home, required this.appearance, super.key});

  final Widget home;

  /// Above the navigator, so that every route and sheet sees it.
  final AppearanceSettings appearance;

  @override
  Widget build(BuildContext context) {
    return AppearanceScope(
      settings: appearance,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ModusTheme.of(ModusThemes.palette(appearance.theme)),
          themeAnimationDuration: ModusThemes.transition,
          home: home,
        ),
      ),
    );
  }
}
