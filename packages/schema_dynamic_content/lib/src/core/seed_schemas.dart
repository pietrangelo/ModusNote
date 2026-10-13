import 'field_type.dart';
import 'field_value.dart';
import 'identifiers.dart';
import 'label.dart';
import 'schema_catalog.dart';
import 'schema_definition.dart';
import 'schema_migration.dart';

/// The reference note types every vault starts with. Labels and options are
/// localization keys (`schema.<id>.field.<key>`), resolved by the app.
abstract final class SeedSchemas {
  static final songSketchV1 = _seed(
    'song_sketch',
    NoteIcon.music,
    NoteTint.violet,
    [
      ('title', TextFieldType(maxLength: 200), true),
      ('bpm', NumberFieldType(min: 20, max: 400, integerOnly: true), false),
      ('key', ChoiceFieldType(_musicalKeys), false),
      ('lyrics', const RichTextFieldType(), false),
      ('guide_track', const AudioBlobFieldType(), false),
    ],
  );

  static final dreamLogV1 = _seed('dream_log', NoteIcon.moon, NoteTint.rose, [
    ('title', TextFieldType(maxLength: 200), true),
    ('dream_date', const DateFieldType(), true),
    ('lucidity', RatingFieldType(min: 1, max: 5), false),
    ('transcription', const RichTextFieldType(), false),
    ('wake_audio', const AudioBlobFieldType(), false),
  ]);

  /// The first to-do: one task per note. Kept so old notes can be read
  /// and brought to [taskV2].
  static final taskV1 = _seed('task', NoteIcon.checklist, NoteTint.cyan, [
    ('description', TextFieldType(maxLength: 500), true),
    ('due', const DateTimeFieldType(), false),
    ('priority', ChoiceFieldType(['low', 'medium', 'high', 'urgent']), false),
    ('completed', const BooleanFieldType(), true),
  ]);

  static final quickNoteV1 = _seed('quick_note', NoteIcon.note, NoteTint.gold, [
    ('content', const MarkdownFieldType(), true),
    ('tags', TagListFieldType(), false),
  ]);

  /// A page of a manual or any document made of linked pages: a title,
  /// Markdown that links to other pages, pictures and links.
  static final documentV1 = _seed('document', NoteIcon.page, NoteTint.silver, [
    ('title', TextFieldType(maxLength: 200), true),
    ('body', const MarkdownFieldType(), false),
    ('attachments', AttachmentsFieldType(), false),
    ('tags', TagListFieldType(), false),
  ]);

  /// A to-do is a list of tasks, with an optional title. A [taskV1] note
  /// becomes a one-task list: its description, made one safe line, and
  /// its completed flag.
  static final taskV1ToV2 = SchemaMigration(
    from: taskV1,
    steps: [
      AddField(_field('task', 'title', TextFieldType(maxLength: 200), false)),
      DeriveField(
        _field('task', 'items', ChecklistFieldType(), true),
        (attributes) => switch (attributes[FieldKey('description')]) {
          TextValue(:final text) => ChecklistValue([
            ChecklistItem(
              _oneSafeLine(text),
              done:
                  attributes[FieldKey('completed')] == const BooleanValue(true),
            ),
          ]),
          _ => null,
        },
      ),
      RemoveField(FieldKey('description')),
      RemoveField(FieldKey('completed')),
    ],
    uiHints: [
      WidgetPlacement(field: FieldKey('title'), section: 'main', order: 0),
      WidgetPlacement(field: FieldKey('items'), section: 'main', order: 1),
    ],
  );

  static final taskV2 = taskV1ToV2.target;

  /// The current version of each type, in the order the app offers them.
  static final all = List<SchemaDefinition>.unmodifiable([
    songSketchV1,
    dreamLogV1,
    taskV2,
    quickNoteV1,
    documentV1,
  ]);

  static final catalog = SchemaCatalog(current: all, migrations: [taskV1ToV2]);

  static final _unsafeOrBreaking = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  static String _oneSafeLine(String text) => text
      .replaceAll(_unsafeOrBreaking, ' ')
      .replaceAll(RegExp(r' {2,}'), ' ')
      .trim();

  static final _musicalKeys = <String>[
    for (final tonic in [
      'c', 'c_sharp', 'd', 'e_flat', 'e', 'f', //
      'f_sharp', 'g', 'a_flat', 'a', 'b_flat', 'b',
    ]) ...['${tonic}_major', '${tonic}_minor'],
  ];

  static SchemaDefinition _seed(
    String name,
    NoteIcon icon,
    NoteTint tint,
    List<(String, FieldType, bool)> fields,
  ) => SchemaDefinition(
    id: SchemaId(name, 1),
    label: LocalizedLabel('schema.$name.label'),
    icon: icon,
    tint: tint,
    fields: [
      for (final (key, type, required) in fields)
        _field(name, key, type, required),
    ],
  );

  static FieldDefinition _field(
    String schema,
    String key,
    FieldType type,
    bool required,
  ) => FieldDefinition(
    key: FieldKey(key),
    label: LocalizedLabel('schema.$schema.field.$key'),
    type: type,
    required: required,
  );
}
