import 'package:flutter/material.dart';

import 'l10n/generated/app_localizations.dart';

void main() {
  runApp(const ModusNoteApp());
}

class ModusNoteApp extends StatelessWidget {
  const ModusNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _LockedVaultPlaceholder(),
    );
  }
}

// Stand-in home screen until the vault unlock flow exists (Fase 1+).
class _LockedVaultPlaceholder extends StatelessWidget {
  const _LockedVaultPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(AppLocalizations.of(context).vaultLockedMessage),
      ),
    );
  }
}
