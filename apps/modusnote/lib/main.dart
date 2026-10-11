import 'package:flutter/material.dart';

import 'bootstrap/home.dart';
import 'l10n/generated/app_localizations.dart';
import 'theme/modus_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ModusNoteApp(home: await buildHome()));
}

class ModusNoteApp extends StatelessWidget {
  const ModusNoteApp({required this.home, super.key});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ModusTheme.dark(),
      home: home,
    );
  }
}
