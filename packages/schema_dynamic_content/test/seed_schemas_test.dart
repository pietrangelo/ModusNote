import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('ships the reference types', () {
    expect(SeedSchemas.all.map((s) => s.id.name), [
      'song_sketch',
      'dream_log',
      'task',
      'quick_note',
      'document',
    ]);
  });

  test('song_sketch_v1 matches the spec', () {
    final s = SeedSchemas.songSketchV1;
    expect(s.fields.map((f) => f.key.value), [
      'title',
      'bpm',
      'key',
      'lyrics',
      'guide_track',
    ]);
    expect(s.fieldFor(key('bpm'))!.type, isA<NumberFieldType>());
    expect(s.fieldFor(key('key'))!.type, isA<ChoiceFieldType>());
    expect(s.fieldFor(key('lyrics'))!.type, isA<RichTextFieldType>());
    expect(s.fieldFor(key('guide_track'))!.type, isA<AudioBlobFieldType>());
  });

  test('song keys cover all 12 major and 12 minor keys', () {
    final type =
        SeedSchemas.songSketchV1.fieldFor(key('key'))!.type as ChoiceFieldType;
    expect(type.options, hasLength(24));
  });

  test('dream_log_v1 matches the spec', () {
    final s = SeedSchemas.dreamLogV1;
    expect(s.fields.map((f) => f.key.value), [
      'title',
      'dream_date',
      'lucidity',
      'transcription',
      'wake_audio',
    ]);
    final lucidity = s.fieldFor(key('lucidity'))!.type as RatingFieldType;
    expect((lucidity.min, lucidity.max), (1, 5));
  });

  test('task_v1 matches the spec', () {
    final s = SeedSchemas.taskV1;
    expect(s.fields.map((f) => f.key.value), [
      'description',
      'due',
      'priority',
      'completed',
    ]);
    expect(s.fieldFor(key('due'))!.type, isA<DateTimeFieldType>());
    expect(s.fieldFor(key('completed'))!.type, isA<BooleanFieldType>());
  });

  test('quick_note_v1 matches the spec', () {
    final s = SeedSchemas.quickNoteV1;
    expect(s.fields.map((f) => f.key.value), ['content', 'tags']);
    expect(s.fieldFor(key('content'))!.type, isA<MarkdownFieldType>());
    expect(s.fieldFor(key('tags'))!.type, isA<TagListFieldType>());
  });

  test('document_v1 matches the spec', () {
    final s = SeedSchemas.documentV1;
    expect(s.fields.map((f) => f.key.value), [
      'title',
      'body',
      'attachments',
      'tags',
    ]);
    expect(s.fieldFor(key('title'))!.required, isTrue);
    expect(s.fieldFor(key('body'))!.type, isA<MarkdownFieldType>());
    expect(s.fieldFor(key('attachments'))!.type, isA<AttachmentsFieldType>());
    expect((s.icon, s.tint), (NoteIcon.page, NoteTint.silver));
  });

  test('every seed label is a localization key under its schema', () {
    for (final schema in [...SeedSchemas.all, SeedSchemas.taskV1]) {
      final prefix = 'schema.${schema.id.name}.';
      expect(schema.label, LocalizedLabel('${prefix}label'));
      for (final f in schema.fields) {
        expect(f.label, LocalizedLabel('${prefix}field.${f.key.value}'));
      }
    }
  });

  test('every seed survives the codec', () {
    for (final schema in SeedSchemas.all) {
      expect(SchemaCodec.decode(SchemaCodec.encode(schema)), schema);
    }
  });
}
