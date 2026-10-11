import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/recording_player_view.dart';
import '../audio/recording_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'dynamic_form_renderer.dart';
import 'note_appearance.dart';
import 'note_store.dart';
import 'schema_text.dart';

/// Writes a new note or edits one. While a note is new its type can be
/// switched in one tap, keeping whatever still fits the new type.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    required this.schemas,
    required this.store,
    required this.initialSchema,
    this.entry,
    this.clock = DateTime.now,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteStore store;
  final SchemaDefinition initialSchema;

  /// The note being edited, or null for a new one.
  final DynamicEntry? entry;
  final DateTime Function() clock;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late SchemaDefinition _schema = widget.initialSchema;
  late FormDraft _draft = FormDraft(widget.entry?.attributes ?? const {}, {});
  List<Violation> _violations = const [];

  /// Takes recorded in this edit, kept only if the note is saved.
  final _takes = <BlobId, KeyedRecording>{};
  var _saved = false;

  bool get _isNew => widget.entry == null;

  void _switchTo(SchemaDefinition schema) {
    if (schema.id == _schema.id) return;
    setState(() {
      _draft = FormDraft(
        SchemaSwitch.carryOver(
          from: _schema,
          values: _draft.values,
          to: schema,
        ),
        {},
      );
      _schema = schema;
      _violations = const [];
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final at = widget.clock().toUtc();
    final unreadable = [
      for (final key in _draft.unreadable)
        Violation(ViolationCode.typeMismatch, key),
    ];
    final result = switch (widget.entry) {
      null => DynamicEntry.create(
        schema: _schema,
        id: _newEntryId(),
        attributes: _draft.values,
        at: at,
      ),
      final entry => entry.update(
        schema: _schema,
        changes: {
          for (final field in _schema.fields)
            field.key: _draft.values[field.key],
        },
        at: at,
      ),
    };
    switch (result) {
      case Valid(:final value) when unreadable.isEmpty:
        await widget.store.save(value, takes: _takes.values);
        _saved = true;
        messenger.showSnackBar(SnackBar(content: Text(l10n.noteSaved)));
        if (mounted) Navigator.of(context).maybePop();
      case Valid():
        _reject(unreadable, l10n, messenger);
      case Invalid(:final violations):
        _reject([...violations, ...unreadable], l10n, messenger);
    }
  }

  Future<BlobId?> _record(FieldDefinition field) async {
    final recorder = widget.store.recorder;
    if (recorder == null) return null;
    final take = await RecordingSheet.show(context, recorder);
    if (take == null) return null;
    _takes[take.id] = take;
    return take.id;
  }

  Duration? _lengthOf(BlobId blob) =>
      (_takes[blob] ?? widget.store.recordingOf(blob))?.metadata.duration;

  Widget? _playerOf(BlobId blob) {
    final playback = widget.store.playback;
    final take = _takes[blob] ?? widget.store.recordingOf(blob);
    if (playback == null || take == null || !playback.canPlay(take)) {
      return null;
    }
    return RecordingPlayerView(
      // A new take is a new player: the old samples go with the old one.
      key: ValueKey(blob),
      open: () => playback.open(take),
      length: take.metadata.duration,
    );
  }

  @override
  void dispose() {
    if (!_saved && _takes.isNotEmpty) {
      widget.store.discardTakes(_takes.values.toList());
    }
    super.dispose();
  }

  void _reject(
    List<Violation> violations,
    AppLocalizations l10n,
    ScaffoldMessengerState messenger,
  ) {
    setState(() => _violations = violations);
    messenger.showSnackBar(SnackBar(content: Text(l10n.fixErrors)));
  }

  /// Opaque and random: ids reach the server in clear, so they must not
  /// reveal order, time or device. 128 bits as 32 hex digits, the shape of
  /// the record id the note is stored under.
  static EntryId _newEntryId() {
    final random = Random.secure();
    return EntryId(
      List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    return Scaffold(
      appBar: AppBar(
        title: Text(text.label(_schema.label)),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.save)),
          const SizedBox(width: Spacing.s),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Extents.xxl),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.l),
            children: [
              if (_isNew) ...[
                Text(
                  l10n.noteType,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: Spacing.s),
                Wrap(
                  spacing: Spacing.s,
                  runSpacing: Spacing.s,
                  children: [
                    for (final schema in widget.schemas)
                      ChoiceChip(
                        avatar: Icon(
                          NoteAppearance.icon(schema.icon),
                          size: IconSizes.inline,
                          color: NoteAppearance.tint(schema.tint),
                        ),
                        label: Text(text.label(schema.label)),
                        selected: schema.id == _schema.id,
                        onSelected: (_) => _switchTo(schema),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.l),
              ],
              DynamicFormRenderer(
                // A new type is a new form, filled with what was carried over.
                key: ValueKey(_schema.id),
                schema: _schema,
                values: _draft.values,
                violations: _violations,
                onChanged: (draft) {
                  _draft = draft;
                  // Typing on a soft keyboard is not a pointer event.
                  AutoLockScope.maybeOf(context)?.touch();
                },
                onRecordAudio: widget.store.recorder == null ? null : _record,
                recordingLength: _lengthOf,
                recordingPlayer: _playerOf,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
