import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';

/// Turns the language-neutral keys of the seed schemas into the user's
/// language. Generated localizations have one getter per string, so the
/// keys are mapped here; a test checks that every seed key is covered.
final class SchemaText {
  SchemaText(this._l10n);

  final AppLocalizations _l10n;

  /// What to show for [label]; a key this version does not know (a schema
  /// from a newer app) falls back to its last segment, readable if plain.
  String label(Label label) => switch (label) {
    LiteralLabel(:final text) => text,
    LocalizedLabel(:final key) =>
      lookup(label) ?? _readable(key.split('.').last),
  };

  String option(FieldDefinition field, String option) =>
      lookupOption(field, option) ?? _readable(option);

  String? lookup(Label label) => switch (label) {
    LiteralLabel(:final text) => text,
    LocalizedLabel(:final key) => _byKey(key),
  };

  String? lookupOption(FieldDefinition field, String option) {
    if (field.label case LocalizedLabel(:final key)) {
      final direct = _byKey('$key.$option');
      if (direct != null) return direct;
    }
    return _musicalKey(option);
  }

  String violation(ViolationCode code) => switch (code) {
    ViolationCode.schemaMismatch => _l10n.violationSchemaMismatch,
    ViolationCode.unknownField => _l10n.violationUnknownField,
    ViolationCode.missingRequired => _l10n.violationMissingRequired,
    ViolationCode.typeMismatch => _l10n.violationTypeMismatch,
    ViolationCode.tooLong => _l10n.violationTooLong,
    ViolationCode.outOfRange => _l10n.violationOutOfRange,
    ViolationCode.notAnInteger => _l10n.violationNotAnInteger,
    ViolationCode.invalidChoice => _l10n.violationInvalidChoice,
    ViolationCode.tooManyTags => _l10n.violationTooManyTags,
    ViolationCode.invalidCharacters => _l10n.violationInvalidCharacters,
  };

  static String _readable(String identifier) => identifier.replaceAll('_', ' ');

  String? _musicalKey(String option) {
    final match = _keyPattern.firstMatch(option);
    if (match == null) return null;
    final tonic = _tonic(match[1]!);
    if (tonic == null) return null;
    return match[2] == 'major'
        ? _l10n.musicalKeyMajor(tonic)
        : _l10n.musicalKeyMinor(tonic);
  }

  static final _keyPattern = RegExp(
    r'^([a-g](?:_sharp|_flat)?)_(major|minor)$',
  );

  String? _tonic(String name) => switch (name) {
    'c' => _l10n.tonicC,
    'c_sharp' => _l10n.tonicCSharp,
    'd' => _l10n.tonicD,
    'e_flat' => _l10n.tonicEFlat,
    'e' => _l10n.tonicE,
    'f' => _l10n.tonicF,
    'f_sharp' => _l10n.tonicFSharp,
    'g' => _l10n.tonicG,
    'a_flat' => _l10n.tonicAFlat,
    'a' => _l10n.tonicA,
    'b_flat' => _l10n.tonicBFlat,
    'b' => _l10n.tonicB,
    _ => null,
  };

  String? _byKey(String key) => switch (key) {
    'schema.song_sketch.label' => _l10n.schemaSongSketchLabel,
    'schema.song_sketch.field.title' => _l10n.schemaSongSketchFieldTitle,
    'schema.song_sketch.field.bpm' => _l10n.schemaSongSketchFieldBpm,
    'schema.song_sketch.field.key' => _l10n.schemaSongSketchFieldKey,
    'schema.song_sketch.field.lyrics' => _l10n.schemaSongSketchFieldLyrics,
    'schema.song_sketch.field.guide_track' =>
      _l10n.schemaSongSketchFieldGuideTrack,
    'schema.dream_log.label' => _l10n.schemaDreamLogLabel,
    'schema.dream_log.field.title' => _l10n.schemaDreamLogFieldTitle,
    'schema.dream_log.field.dream_date' => _l10n.schemaDreamLogFieldDreamDate,
    'schema.dream_log.field.lucidity' => _l10n.schemaDreamLogFieldLucidity,
    'schema.dream_log.field.transcription' =>
      _l10n.schemaDreamLogFieldTranscription,
    'schema.dream_log.field.wake_audio' => _l10n.schemaDreamLogFieldWakeAudio,
    'schema.task.label' => _l10n.schemaTaskLabel,
    'schema.task.field.description' => _l10n.schemaTaskFieldDescription,
    'schema.task.field.due' => _l10n.schemaTaskFieldDue,
    'schema.task.field.priority' => _l10n.schemaTaskFieldPriority,
    'schema.task.field.completed' => _l10n.schemaTaskFieldCompleted,
    'schema.task.field.priority.low' => _l10n.schemaTaskFieldPriorityLow,
    'schema.task.field.priority.medium' => _l10n.schemaTaskFieldPriorityMedium,
    'schema.task.field.priority.high' => _l10n.schemaTaskFieldPriorityHigh,
    'schema.task.field.priority.urgent' => _l10n.schemaTaskFieldPriorityUrgent,
    'schema.quick_note.label' => _l10n.schemaQuickNoteLabel,
    'schema.quick_note.field.content' => _l10n.schemaQuickNoteFieldContent,
    'schema.quick_note.field.tags' => _l10n.schemaQuickNoteFieldTags,
    _ => null,
  };
}
