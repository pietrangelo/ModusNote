import 'package:flutter/material.dart';

import 'l10n/generated/app_localizations.dart';
import 'theme/golden_ratio.dart';
import 'theme/modus_theme.dart';

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
      theme: ModusTheme.dark(),
      home: const _LockedVaultPlaceholder(),
    );
  }
}

// Stand-in home screen until the vault unlock flow exists (Fase 1+).
class _LockedVaultPlaceholder extends StatelessWidget {
  const _LockedVaultPlaceholder();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/brand/modus_notes_logo.png',
                width: constraints.maxWidth * LayoutSplit.primary,
                semanticLabel: l10n.appTitle,
              ),
              const SizedBox(height: Spacing.xl),
              Text(l10n.vaultLockedMessage),
            ],
          ),
        ),
      ),
    );
  }
}
