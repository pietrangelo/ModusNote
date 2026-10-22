import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import 'note_appearance.dart';
import 'schema_text.dart';

/// The [NoteTypeChoice] of an open vault: a change shows at once and is
/// kept by [persist] (a sealed setting of this device).
final class NoteTypeSetting extends ValueNotifier<NoteTypeChoice> {
  NoteTypeSetting(super.value, {required this.persist});

  final Future<void> Function(Uint8List bytes) persist;

  @override
  set value(NoteTypeChoice choice) {
    if (choice == value) return;
    super.value = choice;
    unawaited(persist(choice.toBytes()));
  }
}

/// The note types of the app, each with a switch: a type turned off leaves
/// the choice of a new note, the filters and the palette (the journal
/// takes its calendar and reminder along), while its notes stay. The last
/// type on cannot be turned off.
class NoteTypesSheet extends StatelessWidget {
  const NoteTypesSheet({
    required this.schemas,
    required this.setting,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteTypeSetting setting;

  static Future<void> show(
    BuildContext context, {
    required List<SchemaDefinition> schemas,
    required NoteTypeSetting setting,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // The golden share of the window at most.
    constraints: BoxConstraints(
      maxWidth: Extents.xxl,
      maxHeight: MediaQuery.sizeOf(context).height * LayoutSplit.primary,
    ),
    builder: (_) => NoteTypesSheet(schemas: schemas, setting: setting),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    return ValueListenableBuilder(
      valueListenable: setting,
      builder: (context, choice, _) => SafeArea(
        child: ListView(
          key: const ValueKey('note-types-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            Spacing.l,
            0,
            Spacing.l,
            Spacing.l,
          ),
          children: [
            Text(l10n.noteTypesSettings, style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.s),
            Text(
              l10n.noteTypesSettingsHint,
              style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
            ),
            const SizedBox(height: Spacing.m),
            for (final schema in schemas)
              SwitchListTile(
                key: ValueKey('note-type-${schema.id.name}'),
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  NoteAppearance.icon(schema.icon),
                  color: palette.tint(schema.tint),
                ),
                title: Text(text.label(schema.label)),
                value: choice.isOn(schema.id.name),
                onChanged:
                    choice.isOn(schema.id.name) &&
                        !choice.canTurnOff(schema.id.name, schemas)
                    ? null
                    : (on) => setting.value = on
                          ? choice.turnedOn(schema.id.name)
                          : choice.turnedOff(schema.id.name, schemas),
              ),
          ],
        ),
      ),
    );
  }
}
