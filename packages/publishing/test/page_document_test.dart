import 'dart:convert';
import 'dart:math';

import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final chapter = schema('book_chapter', [
    field('title', TextFieldType(maxLength: 200)),
    field('body', const MarkdownFieldType()),
    field('tags', TagListFieldType(maxTags: 10)),
    field('todo', ChecklistFieldType()),
    field('voice', const AudioBlobFieldType()),
    field('files', AttachmentsFieldType()),
    field('stars', RatingFieldType(min: 0, max: 5)),
    field('site', const UrlFieldType()),
  ]);
  final picture = BlobId('0123456789abcdef0123456789abcdef');
  final recording = BlobId('fedcba9876543210fedcba9876543210');
  final pictureCopy = MediaId('AAAAAAAAAAAAAAAAAAAAAA');
  final recordingCopy = MediaId('BBBBBBBBBBBBBBBBBBBBBB');

  PageDocument page(
    Map<String, FieldValue> values, {
    Iterable<String>? fields,
    Map<BlobId, MediaId>? media,
    bool listed = true,
  }) {
    final content = PublicationPolicy.compose(
      entry: entry(chapter, values),
      schema: chapter,
      fields: keys(fields ?? values.keys),
    );
    return PageComposer.compose(
      content: content,
      schema: chapter,
      media: media ?? {picture: pictureCopy, recording: recordingCopy},
      labelOf: labelOf,
      describe: describe,
      listed: listed,
    );
  }

  test('every kind of field becomes the block serv.pub takes', () {
    final doc = page({
      'title': const TextValue('Il faro'),
      'body': TextValue(
        'La luce *gira*.\n\n![Il molo](image:${picture.value})',
      ),
      'tags': TagListValue({'mare', 'notte'}),
      'todo': ChecklistValue([const ChecklistItem('Rileggere', done: true)]),
      'voice': AudioBlobValue(recording),
      'files': AttachmentsValue([
        ImageAttachment(picture, caption: 'Alba'),
        WebLink('https://example.org/faro', title: 'Fari'),
      ]),
      'stars': const RatingValue(4),
      'site': const TextValue('https://example.org'),
    });
    expect(doc.title, 'Il faro');
    expect(doc.layout, PublicationLayout.book);
    final json = jsonDecode(jsonEncode(doc.toJson())) as Map<String, Object?>;
    expect(json['layout'], 'book');
    expect(json['listed'], isTrue);
    final blocks = (json['blocks']! as List).cast<Map<String, Object?>>();
    expect(blocks.map((b) => b['kind']), [
      // The title field is the page's title, not a block of its own.
      'markdown',
      'tags',
      'checklist',
      'audio',
      'image',
      'links',
      'text',
      'links',
    ]);
    expect(blocks[0], {
      'kind': 'markdown',
      'label': '',
      'text': 'La luce *gira*.\n\n![Il molo](image:${pictureCopy.value})',
    });
    expect(blocks[3], {
      'kind': 'audio',
      'label': 'voice',
      'media': recordingCopy.value,
    });
    expect(blocks[4]['caption'], 'Alba');
    expect(blocks[5]['label'], '', reason: 'one name per field');
    expect(blocks[6], {'kind': 'text', 'label': 'stars', 'text': '4'});
    expect(doc.media, [pictureCopy, recordingCopy]);
  });

  test('no id of a blob of the vault ever reaches the page', () {
    final doc = page({
      'body': TextValue(
        '# Titolo\n\n![Molo](image:${picture.value}) e '
        '![a [b]](image:${picture.value}) e [r]\n\n'
        '[r]: image:${picture.value}',
      ),
      'voice': AudioBlobValue(recording),
      'files': AttachmentsValue([ImageAttachment(picture)]),
    }, media: {});
    final wire = jsonEncode(doc.toJson());
    expect(wire, isNot(contains(picture.value)));
    expect(wire, isNot(contains(recording.value)));
    expect(doc.media, isEmpty);
    // Without a copy a picture keeps only its caption.
    expect(wire, contains('Molo'));
  });

  test('the first line, already the title, is not repeated', () {
    final doc = page({'body': const TextValue('# Il faro\n\nLa luce.')});
    expect(doc.title, 'Il faro');
    expect((doc.blocks.single as MarkdownBlock).text.trim(), 'La luce.');
  });

  test('text is made safe for serv.pub', () {
    expect(PageComposer.line('a\u202Eb\n c', 89), 'a b c');
    expect(PageComposer.line('x' * 100, 89), hasLength(89));
    // A character is never cut in half.
    expect(PageComposer.line('${'x' * 88}\u{1F600}', 89), 'x' * 88);
  });

  test('nothing left to show is refused', () {
    expect(
      () => page({'title': const TextValue('Solo titolo')}),
      throwsA(isA<NotPublishableException>()),
    );
    expect(
      () => page({'voice': AudioBlobValue(recording)}, media: {}),
      throwsA(isA<NotPublishableException>()),
    );
  });

  test('a draft is not listed; a collection page is an essay', () {
    final doc = PageDocument(
      title: 't',
      layout: PublicationLayout.collection,
      listed: false,
      blocks: const [TextBlock('', 'x')],
    );
    expect(doc.toJson()['layout'], 'essay');
    expect(doc.toJson()['listed'], isFalse);
  });

  test('media ids are random, 22 symbols, and checked', () {
    final a = MediaId.random(Random(1));
    final b = MediaId.random(Random(2));
    expect(a.value, hasLength(22));
    expect(a, isNot(b));
    for (final bad in ['short', 'a/b' * 8, 'x' * 65]) {
      expect(() => MediaId(bad), throwsA(isA<InvalidMediaIdException>()));
    }
  });
}
