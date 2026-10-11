import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'l10n/generated/app_localizations.dart';
import 'notes/note_library.dart';
import 'notes/note_store.dart';
import 'theme/modus_theme.dart';

void main() {
  runApp(ModusNoteApp(store: InMemoryNoteStore()));
}

class ModusNoteApp extends StatelessWidget {
  const ModusNoteApp({required this.store, super.key});

  final NoteStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ModusTheme.dark(),
      home: NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
    );
  }
}
