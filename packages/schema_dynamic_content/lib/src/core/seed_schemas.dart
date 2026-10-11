import 'field_type.dart';
import 'identifiers.dart';
import 'label.dart';
import 'schema_definition.dart';

/// The reference note types every vault starts with. Labels and options are
/// localization keys (`schema.<id>.field.<key>`), resolved by the app.
abstract final class SeedSchemas {
  static final songSketchV1 = _seed('song_sketch', [
    ('title', TextFieldType(maxLength: 200), true),
    ('bpm', NumberFieldType(min: 20, max: 400, integerOnly: true), false),
    ('key', ChoiceFieldType(_musicalKeys), false),
    ('lyrics', const RichTextFieldType(), false),
    ('guide_track', const AudioBlobFieldType(), false),
  ]);

  static final dreamLogV1 = _seed('dream_log', [
    ('title', TextFieldType(maxLength: 200), true),
    ('dream_date', const DateFieldType(), true),
    ('lucidity', RatingFieldType(min: 1, max: 5), false),
    ('transcription', const RichTextFieldType(), false),
    ('wake_audio', const AudioBlobFieldType(), false),
  ]);

  static final taskV1 = _seed('task', [
    ('description', TextFieldType(maxLength: 500), true),
    ('due', const DateTimeFieldType(), false),
    ('priority', ChoiceFieldType(['low', 'medium', 'high', 'urgent']), false),
    ('completed', const BooleanFieldType(), true),
  ]);

  static final quickNoteV1 = _seed('quick_note', [
    ('content', const MarkdownFieldType(), true),
    ('tags', TagListFieldType(), false),
  ]);

  static final all = List<SchemaDefinition>.unmodifiable([
    songSketchV1,
    dreamLogV1,
    taskV1,
    quickNoteV1,
  ]);

  static final _musicalKeys = <String>[
    for (final tonic in [
      'c', 'c_sharp', 'd', 'e_flat', 'e', 'f', //
      'f_sharp', 'g', 'a_flat', 'a', 'b_flat', 'b',
    ]) ...['${tonic}_major', '${tonic}_minor'],
  ];

  static SchemaDefinition _seed(
    String name,
    List<(String, FieldType, bool)> fields,
  ) => SchemaDefinition(
    id: SchemaId(name, 1),
    label: LocalizedLabel('schema.$name.label'),
    fields: [
      for (final (key, type, required) in fields)
        FieldDefinition(
          key: FieldKey(key),
          label: LocalizedLabel('schema.$name.field.$key'),
          type: type,
          required: required,
        ),
    ],
  );
}
