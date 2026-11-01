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
    ViolationCode.tooManyItems => _l10n.violationTooManyItems,
    ViolationCode.emptyItem => _l10n.violationEmptyItem,
    ViolationCode.duplicateItem => _l10n.violationDuplicateItem,
    ViolationCode.invalidUrl => _l10n.violationInvalidUrl,
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
    'schema.task.field.title' => _l10n.schemaTaskFieldTitle,
    'schema.task.field.items' => _l10n.schemaTaskFieldItems,
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
    'schema.document.label' => _l10n.schemaDocumentLabel,
    'schema.document.field.title' => _l10n.schemaDocumentFieldTitle,
    'schema.document.field.body' => _l10n.schemaDocumentFieldBody,
    'schema.document.field.attachments' => _l10n.schemaDocumentFieldAttachments,
    'schema.document.field.tags' => _l10n.schemaDocumentFieldTags,
    'schema.book.label' => _l10n.schemaBookLabel,
    'schema.book.field.title' => _l10n.schemaBookFieldTitle,
    'schema.book.field.synopsis' => _l10n.schemaBookFieldSynopsis,
    'schema.book.field.genre' => _l10n.schemaBookFieldGenre,
    'schema.book.field.word_goal' => _l10n.schemaBookFieldWordGoal,
    'schema.book.field.attachments' => _l10n.schemaBookFieldAttachments,
    'schema.book.field.tags' => _l10n.schemaBookFieldTags,
    'schema.book_chapter.label' => _l10n.schemaBookChapterLabel,
    'schema.book_chapter.field.title' => _l10n.schemaBookChapterFieldTitle,
    'schema.book_chapter.field.body' => _l10n.schemaBookChapterFieldBody,
    'schema.book_chapter.field.number' => _l10n.schemaBookChapterFieldNumber,
    'schema.book_chapter.field.status' => _l10n.schemaBookChapterFieldStatus,
    'schema.book_chapter.field.status.idea' =>
      _l10n.schemaBookChapterFieldStatusIdea,
    'schema.book_chapter.field.status.draft' =>
      _l10n.schemaBookChapterFieldStatusDraft,
    'schema.book_chapter.field.status.revised' =>
      _l10n.schemaBookChapterFieldStatusRevised,
    'schema.book_chapter.field.status.final' =>
      _l10n.schemaBookChapterFieldStatusFinal,
    'schema.book_chapter.field.attachments' =>
      _l10n.schemaBookChapterFieldAttachments,
    'schema.book_character.label' => _l10n.schemaBookCharacterLabel,
    'schema.book_character.field.name' => _l10n.schemaBookCharacterFieldName,
    'schema.book_character.field.profile' =>
      _l10n.schemaBookCharacterFieldProfile,
    'schema.book_character.field.role' => _l10n.schemaBookCharacterFieldRole,
    'schema.book_character.field.role.protagonist' =>
      _l10n.schemaBookCharacterFieldRoleProtagonist,
    'schema.book_character.field.role.antagonist' =>
      _l10n.schemaBookCharacterFieldRoleAntagonist,
    'schema.book_character.field.role.supporting' =>
      _l10n.schemaBookCharacterFieldRoleSupporting,
    'schema.book_character.field.role.minor' =>
      _l10n.schemaBookCharacterFieldRoleMinor,
    'schema.book_character.field.age' => _l10n.schemaBookCharacterFieldAge,
    'schema.book_character.field.goal' => _l10n.schemaBookCharacterFieldGoal,
    'schema.book_character.field.conflict' =>
      _l10n.schemaBookCharacterFieldConflict,
    'schema.book_character.field.arc' => _l10n.schemaBookCharacterFieldArc,
    'schema.book_character.field.attachments' =>
      _l10n.schemaBookCharacterFieldAttachments,
    'schema.book_place.label' => _l10n.schemaBookPlaceLabel,
    'schema.book_place.field.name' => _l10n.schemaBookPlaceFieldName,
    'schema.book_place.field.description' =>
      _l10n.schemaBookPlaceFieldDescription,
    'schema.book_place.field.kind' => _l10n.schemaBookPlaceFieldKind,
    'schema.book_place.field.period' => _l10n.schemaBookPlaceFieldPeriod,
    'schema.book_place.field.attachments' =>
      _l10n.schemaBookPlaceFieldAttachments,
    'schema.recipe.label' => _l10n.schemaRecipeLabel,
    'schema.recipe.field.title' => _l10n.schemaRecipeFieldTitle,
    'schema.recipe.field.description' => _l10n.schemaRecipeFieldDescription,
    'schema.recipe.field.photos' => _l10n.schemaRecipeFieldPhotos,
    'schema.recipe.field.servings' => _l10n.schemaRecipeFieldServings,
    'schema.recipe.field.ingredients' => _l10n.schemaRecipeFieldIngredients,
    'schema.recipe.field.steps' => _l10n.schemaRecipeFieldSteps,
    'schema.recipe.field.prep_time' => _l10n.schemaRecipeFieldPrepTime,
    'schema.recipe.field.cook_time' => _l10n.schemaRecipeFieldCookTime,
    'schema.recipe.field.rest_time' => _l10n.schemaRecipeFieldRestTime,
    'schema.recipe.field.methods' => _l10n.schemaRecipeFieldMethods,
    'schema.recipe.field.oven_temperature' =>
      _l10n.schemaRecipeFieldOvenTemperature,
    'schema.recipe.field.oven_mode' => _l10n.schemaRecipeFieldOvenMode,
    'schema.recipe.field.difficulty' => _l10n.schemaRecipeFieldDifficulty,
    'schema.recipe.field.tags' => _l10n.schemaRecipeFieldTags,
    'schema.recipe.field.methods.oven' => _l10n.schemaRecipeFieldMethodsOven,
    'schema.recipe.field.methods.stovetop' =>
      _l10n.schemaRecipeFieldMethodsStovetop,
    'schema.recipe.field.methods.air_fryer' =>
      _l10n.schemaRecipeFieldMethodsAirFryer,
    'schema.recipe.field.methods.microwave' =>
      _l10n.schemaRecipeFieldMethodsMicrowave,
    'schema.recipe.field.methods.steam' => _l10n.schemaRecipeFieldMethodsSteam,
    'schema.recipe.field.methods.grill' => _l10n.schemaRecipeFieldMethodsGrill,
    'schema.recipe.field.methods.pressure_cooker' =>
      _l10n.schemaRecipeFieldMethodsPressureCooker,
    'schema.recipe.field.methods.slow_cooker' =>
      _l10n.schemaRecipeFieldMethodsSlowCooker,
    'schema.recipe.field.methods.barbecue' =>
      _l10n.schemaRecipeFieldMethodsBarbecue,
    'schema.recipe.field.methods.no_cook' =>
      _l10n.schemaRecipeFieldMethodsNoCook,
    'schema.recipe.field.oven_mode.static' =>
      _l10n.schemaRecipeFieldOvenModeStatic,
    'schema.recipe.field.oven_mode.fan' => _l10n.schemaRecipeFieldOvenModeFan,
    'schema.recipe.field.oven_mode.grill' =>
      _l10n.schemaRecipeFieldOvenModeGrill,
    'schema.credential.label' => _l10n.schemaCredentialLabel,
    'schema.credential.field.description' =>
      _l10n.schemaCredentialFieldDescription,
    'schema.credential.field.username' => _l10n.schemaCredentialFieldUsername,
    'schema.credential.field.password' => _l10n.schemaCredentialFieldPassword,
    'schema.credential.field.link' => _l10n.schemaCredentialFieldLink,
    'schema.credential.field.password_expiry' =>
      _l10n.schemaCredentialFieldPasswordExpiry,
    'schema.journal.label' => _l10n.schemaJournalLabel,
    'schema.journal.field.title' => _l10n.schemaJournalFieldTitle,
    'schema.journal.field.date' => _l10n.schemaJournalFieldDate,
    'schema.journal.field.page' => _l10n.schemaJournalFieldPage,
    'schema.journal.field.mood' => _l10n.schemaJournalFieldMood,
    'schema.journal.field.mood.great' => _l10n.schemaJournalFieldMoodGreat,
    'schema.journal.field.mood.good' => _l10n.schemaJournalFieldMoodGood,
    'schema.journal.field.mood.neutral' => _l10n.schemaJournalFieldMoodNeutral,
    'schema.journal.field.mood.low' => _l10n.schemaJournalFieldMoodLow,
    'schema.journal.field.mood.hard' => _l10n.schemaJournalFieldMoodHard,
    'schema.journal.field.recording' => _l10n.schemaJournalFieldRecording,
    'schema.journal.field.attachments' => _l10n.schemaJournalFieldAttachments,
    'schema.journal.field.tags' => _l10n.schemaJournalFieldTags,
    _ => null,
  };
}
