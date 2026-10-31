import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

FieldDefinition field(String name, FieldType type) => FieldDefinition(
  key: FieldKey(name),
  label: Label.literal(name),
  type: type,
  required: false,
);

SchemaDefinition schema(String name, List<FieldDefinition> fields) =>
    SchemaDefinition(
      id: SchemaId(name, 1),
      label: Label.literal(name),
      fields: fields,
    );

DynamicEntry entry(SchemaDefinition s, Map<String, FieldValue> values) {
  final at = DateTime.utc(2026, 10, 31, 12);
  final restored = DynamicEntry.restore(
    schema: s,
    id: EntryId('note-1'),
    attributes: {for (final e in values.entries) FieldKey(e.key): e.value},
    audit: AuditTrail(createdAt: at, updatedAt: at, revision: 1),
  );
  return switch (restored) {
    Valid(:final value) => value,
    Invalid(:final violations) => throw StateError('$violations'),
  };
}

void main() {
  final story = schema('book_chapter', [
    field('title', TextFieldType(maxLength: 200)),
    field('body', const MarkdownFieldType()),
    field('tags', TagListFieldType(maxTags: 10)),
    field('voice', const AudioBlobFieldType()),
    field('pin', PasswordFieldType()),
    field('files', AttachmentsFieldType()),
  ]);

  group('what can be published', () {
    test('credentials never, whatever is selected', () {
      final credential = schema('credential', [
        field('title', TextFieldType(maxLength: 200)),
      ]);
      expect(PublicationPolicy.canPublish(credential), isFalse);
      expect(
        () => PublicationPolicy.compose(
          entry: entry(credential, {'title': const TextValue('Banca')}),
          schema: credential,
          fields: {FieldKey('title')},
        ),
        throwsA(isA<NotPublishableException>()),
      );
    });

    test('password fields are never offered and refused if asked for', () {
      expect(
        PublicationPolicy.publishableFields(story).map((f) => f.key.value),
        isNot(contains('pin')),
      );
      expect(
        () => PublicationPolicy.compose(
          entry: entry(story, {'pin': const SecretValue('1234')}),
          schema: story,
          fields: {FieldKey('pin')},
        ),
        throwsA(isA<NotPublishableException>()),
      );
    });

    test('a field the schema does not have is refused', () {
      expect(
        () => PublicationPolicy.compose(
          entry: entry(story, {}),
          schema: story,
          fields: {FieldKey('nope')},
        ),
        throwsA(isA<NotPublishableException>()),
      );
    });

    test('only the selected fields, in schema order', () {
      final content = PublicationPolicy.compose(
        entry: entry(story, {
          'title': const TextValue('Capitolo uno'),
          'body': const TextValue('Testo'),
          'tags': TagListValue({'luna'}),
          'voice': AudioBlobValue(BlobId('voice-1')),
        }),
        schema: story,
        fields: {FieldKey('tags'), FieldKey('title')},
      );
      expect(content.fields.keys.map((k) => k.value), ['title', 'tags']);
      expect(content.audio, isEmpty);
      expect(content.title, 'Capitolo uno');
    });
  });

  group('links to other notes', () {
    test(
      'become page links when that note is published, plain text otherwise',
      () {
        final content = PublicationPolicy.compose(
          entry: entry(story, {
            'body': TextValue(
              'Vedi ${NoteLinks.markdown('Il faro', EntryId('faro'))} e '
              '${NoteLinks.markdown('Diario segreto', EntryId('segreto'))}.',
            ),
          }),
          schema: story,
          fields: {FieldKey('body')},
          published: {EntryId('faro'): PageSlug('il-faro')},
        );
        expect(
          (content.fields[FieldKey('body')] as TextValue).text,
          'Vedi [Il faro](page:il-faro) e Diario segreto.',
        );
      },
    );

    test('never carry the id of an unpublished note', () {
      final content = PublicationPolicy.compose(
        entry: entry(story, {
          'body': TextValue(NoteLinks.markdown('x', EntryId('hidden-id'))),
        }),
        schema: story,
        fields: {FieldKey('body')},
      );
      expect(
        (content.fields[FieldKey('body')] as TextValue).text,
        isNot(contains('hidden-id')),
      );
    });
    test('non-standard links to notes lose the id too', () {
      final content = PublicationPolicy.compose(
        entry: entry(story, {
          'body': const TextValue(
            '[a](note:id-one "t") <note:id-two> [b][r]\n\n[r]: note:id-three',
          ),
        }),
        schema: story,
        fields: {FieldKey('body')},
      );
      final text = (content.fields[FieldKey('body')] as TextValue).text;
      for (final id in ['id-one', 'id-two', 'id-three']) {
        expect(text, isNot(contains(id)));
      }
    });
  });

  group('pictures and audio', () {
    final withPicture = entry(story, {
      'body': TextValue(
        'Prima ${InlineImages.markdown('Il mare', BlobId('pic-1'))} dopo',
      ),
      'files': AttachmentsValue([
        ImageAttachment(BlobId('pic-2'), caption: 'Faro'),
        WebLink.parse('https://example.org', title: 'Fonte')!,
      ]),
      'voice': AudioBlobValue(BlobId('voice-1')),
    });

    test('are listed so the app uploads clean copies, each once', () {
      final content = PublicationPolicy.compose(
        entry: withPicture,
        schema: story,
        fields: {FieldKey('body'), FieldKey('files'), FieldKey('voice')},
      );
      expect(content.images.map((b) => b.value), ['pic-1', 'pic-2']);
      expect(content.audio.map((b) => b.value), ['voice-1']);
    });

    test('pictures left out become their caption, and are not uploaded', () {
      final content = PublicationPolicy.compose(
        entry: withPicture,
        schema: story,
        fields: {FieldKey('body'), FieldKey('files')},
        includePictures: false,
      );
      expect(
        (content.fields[FieldKey('body')] as TextValue).text,
        'Prima Il mare dopo',
      );
      final files = content.fields[FieldKey('files')] as AttachmentsValue;
      expect(files.items, everyElement(isA<WebLink>()));
      expect(content.images, isEmpty);
    });
  });

  test('the title falls back to the first line of text, made safe', () {
    final s = schema('note', [field('body', const MarkdownFieldType())]);
    final content = PublicationPolicy.compose(
      entry: entry(s, {'body': const TextValue('# Ciao\u202E mondo\nresto')}),
      schema: s,
      fields: {FieldKey('body')},
    );
    expect(content.title, 'Ciao mondo');
    expect(content.slug, PageSlug('ciao-mondo'));
    expect(content.layout, PublicationLayout.essay);
  });
}
