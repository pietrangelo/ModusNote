import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import 'vault_note_store.dart';

/// Says that some notes were left out of the library because a newer app
/// wrote them, instead of letting them disappear without a word.
class UnreadableNotice extends StatelessWidget {
  const UnreadableNotice({required this.store, super.key});

  final VaultNoteStore store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final count = store.unreadable;
      if (count == 0) return const SizedBox.shrink();
      final palette = ModusPalette.of(context);
      return Card(
        key: const ValueKey('unreadable-notice'),
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.m),
          child: Row(
            spacing: Spacing.s,
            children: [
              Icon(Icons.system_update_outlined, color: palette.primary),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).unreadableNotes(count),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
