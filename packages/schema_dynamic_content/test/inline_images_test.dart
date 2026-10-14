import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'fixtures.dart';

DynamicEntry documentEntry({
  required String body,
  List<Attachment> attachments = const [],
}) => valueOf(
  DynamicEntry.create(
    schema: SeedSchemas.documentV1,
    id: EntryId('00000000000000000000000000000001'),
    attributes: {
      key('title'): const TextValue('Manuale'),
      key('body'): TextValue(body),
      if (attachments.isNotEmpty)
        key('attachments'): AttachmentsValue(attachments),
    },
    at: at,
  ),
);

void main() {
  final a = BlobId('0123456789abcdef0123456789abcdef');
  final b = BlobId('fedcba9876543210fedcba9876543210');

  test('writes a picture as Markdown pointing at its blob', () {
    expect(
      InlineImages.markdown('Il palco', a),
      '![Il palco](image:0123456789abcdef0123456789abcdef)',
    );
    expect(InlineImages.markdown('', a), '![](image:${a.value})');
  });

  test('makes the caption one safe line that cannot close early', () {
    expect(
      InlineImages.markdown(' a]b[c\nd\u202Ee\u0000f ', a),
      startsWith('![a b c d e f]('),
    );
  });

  test('cuts a long caption without splitting a character', () {
    final long = '${'x' * (InlineImages.maxCaption - 1)}🎵🎵';
    final written = InlineImages.markdown(long, a);
    final found = InlineImages.find(written).single;
    expect(found.caption, 'x' * (InlineImages.maxCaption - 1));
    expect(found.blob, a);
  });

  test('finds each picture with where it sits and its caption', () {
    const before = 'Prima\n';
    final text =
        '$before${InlineImages.markdown('Uno', a)} e '
        '${InlineImages.markdown('', b)}';
    final found = InlineImages.find(text);
    expect(found, hasLength(2));
    expect(found[0].start, before.length);
    expect(
      found[0].end,
      before.length + InlineImages.markdown('Uno', a).length,
    );
    expect(found[0].caption, 'Uno');
    expect(found[0].blob, a);
    expect(text.substring(found[1].start, found[1].end), endsWith(')'));
    expect(found[1].caption, '');
    expect(found[1].blob, b);
  });

  test('ignores what is not a picture of the note', () {
    final text = [
      '[Uno](image:${a.value})', // a link, not a picture
      '![Uno](https://example.org/x.png)', // never fetched
      '![Uno](image:a b)',
      '![Uno](image:)',
      '![a\nb](image:${a.value})',
      '![${'x' * (InlineImages.maxCaption + 1)}](image:${a.value})',
    ].join('\n');
    expect(InlineImages.find(text), isEmpty);
  });

  test('a caption with bidirectional marks reads without them', () {
    final found = InlineImages.find('![a\u202Eb](image:${a.value})').single;
    expect(found.caption, 'a b');
  });

  test('every picture of a note: attachments first, then the text', () {
    final entry = documentEntry(
      body:
          'Testo ${InlineImages.markdown('B', b)} e '
          '${InlineImages.markdown('A', a)} '
          '${InlineImages.markdown('B di nuovo', b)}',
      attachments: [ImageAttachment(a)],
    );
    expect(InlineImages.picturesOf(entry), [a, b]);
  });

  test('pictures are found in text values only', () {
    expect(
      InlineImages.blobsOf([
        TagListValue({'![x](image:${a.value})'}),
        TextValue(InlineImages.markdown('x', b)),
      ]),
      [b],
    );
  });

  test('a written picture is always found again', () {
    for (final caption in ['', 'x', 'a](image:zz)', '\n\n', 'é ♯', '!']) {
      expect(
        InlineImages.blobsOf([TextValue(InlineImages.markdown(caption, a))]),
        [a],
        reason: caption,
      );
    }
  });

  Glados(any.letterOrDigits)
      .test('any caption is found back as written', (caption) {
        final written = InlineImages.markdown(caption, a);
        final found = InlineImages.find('x $written y').single;
        expect(InlineImages.markdown(found.caption, a), written);
      });

  test('a long text full of near misses is read in linear time', () {
    final text = '![${'[' * 50000}](image:' * 20;
    final watch = Stopwatch()..start();
    expect(InlineImages.find(text), isEmpty);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
