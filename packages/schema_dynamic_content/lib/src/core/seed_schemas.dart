import 'field_type.dart';
import 'field_value.dart';
import 'identifiers.dart';
import 'journal.dart';
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

  /// A book: what it is about and how long it should be. Its chapters,
  /// characters and places are notes of their own, filed in the same
  /// category as the book.
  static final bookV1 = _seed('book', NoteIcon.book, NoteTint.gold, [
    ('title', TextFieldType(maxLength: 200), true),
    ('synopsis', const MarkdownFieldType(), false),
    ('genre', TextFieldType(maxLength: 80), false),
    (
      'word_goal',
      NumberFieldType(min: 1, max: 10000000, integerOnly: true),
      false,
    ),
    ('attachments', AttachmentsFieldType(), false),
    ('tags', TagListFieldType(), false),
  ]);

  /// A chapter of a book: its text, its place in the book, how far along.
  static final bookChapterV1 = _seed(
    'book_chapter',
    NoteIcon.bookmark,
    NoteTint.gold,
    [
      ('title', TextFieldType(maxLength: 200), true),
      ('body', const MarkdownFieldType(), false),
      ('number', NumberFieldType(min: 1, max: 9999, integerOnly: true), false),
      ('status', ChoiceFieldType(['idea', 'draft', 'revised', 'final']), false),
      ('attachments', AttachmentsFieldType(), false),
    ],
  );

  /// A character sheet: who they are, what they want, what stands in the
  /// way and how they change.
  static final bookCharacterV1 = _seed(
    'book_character',
    NoteIcon.person,
    NoteTint.gold,
    [
      ('name', TextFieldType(maxLength: 200), true),
      ('profile', const MarkdownFieldType(), false),
      (
        'role',
        ChoiceFieldType(['protagonist', 'antagonist', 'supporting', 'minor']),
        false,
      ),
      ('age', TextFieldType(maxLength: 80), false),
      ('goal', TextFieldType(maxLength: 500), false),
      ('conflict', TextFieldType(maxLength: 500), false),
      ('arc', TextFieldType(maxLength: 500), false),
      ('attachments', AttachmentsFieldType(), false),
    ],
  );

  /// A place in a book: what it looks like, what kind of place, when.
  static final bookPlaceV1 = _seed(
    'book_place',
    NoteIcon.place,
    NoteTint.gold,
    [
      ('name', TextFieldType(maxLength: 200), true),
      ('description', const MarkdownFieldType(), false),
      ('kind', TextFieldType(maxLength: 80), false),
      ('period', TextFieldType(maxLength: 80), false),
      ('attachments', AttachmentsFieldType(), false),
    ],
  );

  /// A login: what it is for, the user name and password, where it is
  /// used and when the password expires. The password is a [SecretValue]:
  /// sealed with the note like everything else, and never searched or
  /// shown on a card.
  static final credentialV1 = _seed('credential', NoteIcon.key, NoteTint.cyan, [
    ('description', TextFieldType(maxLength: 200), true),
    ('username', TextFieldType(maxLength: 200), false),
    ('password', PasswordFieldType(), false),
    ('link', const UrlFieldType(), false),
    ('password_expiry', const DateFieldType(), false),
  ]);

  /// A page of a daily journal: the day it is about, a page of Markdown,
  /// the mood of the day, a recording, pictures and tags. The title is
  /// optional; without one the day names the page ([Journal]).
  static final journalV1 = _seed('journal', NoteIcon.calendar, NoteTint.rose, [
    ('title', TextFieldType(maxLength: 200), false),
    ('date', const DateFieldType(), true),
    ('page', const MarkdownFieldType(), false),
    ('mood', ChoiceFieldType(Journal.moods), false),
    ('recording', const AudioBlobFieldType(), false),
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
    journalV1,
    taskV2,
    documentV1,
    bookV1,
    bookChapterV1,
    bookCharacterV1,
    bookPlaceV1,
    credentialV1,
    // Last: the type a new note starts as.
    quickNoteV1,
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
