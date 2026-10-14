import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';

/// A picture written in the text of a note, where it sits.
final class InlineImage {
  const InlineImage({
    required this.start,
    required this.end,
    required this.caption,
    required this.blob,
  });

  /// Where its Markdown starts (the `!`) and ends (after the `)`).
  final int start;
  final int end;

  /// The caption made one safe line.
  final String caption;
  final BlobId blob;
}

/// Pictures in the text of a note, as Markdown images that point at a
/// sealed blob by id, `![caption](image:<blob id>)`, so they sit in the
/// flow of the text where they are written. The id is all the text holds:
/// the picture's metadata travels with the note (as for attachments) and
/// its bytes in the encrypted blob store. Nothing else is ever an image:
/// a Markdown image with any other address is shown as text and never
/// fetched.
abstract final class InlineImages {
  static const scheme = 'image:';

  /// The longest caption, in UTF-16 code units.
  static const maxCaption = 200;

  static final _reference = RegExp(
    '!\\[([^\\[\\]\\n]{0,$maxCaption})\\]\\($scheme([A-Za-z0-9_-]{1,128})\\)',
  );

  /// Brackets would close the caption early, line breaks end a paragraph,
  /// and control or bidirectional characters render as something else.
  static final _unsafe = RegExp(
    r'[\[\]\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// [caption] made one safe line of at most [maxCaption] code units, a
  /// character never cut in half.
  static String safeCaption(String caption) {
    var safe = caption
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(' {2,}'), ' ')
        .trim();
    if (safe.length > maxCaption) {
      var cut = maxCaption;
      final last = safe.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut--;
      safe = safe.substring(0, cut).trim();
    }
    return safe;
  }

  /// The Markdown for [blob] shown with [caption].
  static String markdown(String caption, BlobId blob) =>
      '![${safeCaption(caption)}]($scheme${blob.value})';

  /// Every picture written in [text], in order.
  static List<InlineImage> find(String text) => [
    for (final match in _reference.allMatches(text))
      InlineImage(
        start: match.start,
        end: match.end,
        caption: safeCaption(match.group(1)!),
        blob: BlobId(match.group(2)!),
      ),
  ];

  /// The pictures [values] show in their text, each once, in the order
  /// they first appear. Only text values hold pictures.
  static List<BlobId> blobsOf(Iterable<FieldValue> values) => {
    for (final value in values)
      if (value case TextValue(:final text))
        for (final match in _reference.allMatches(text))
          BlobId(match.group(2)!),
  }.toList();

  /// Every picture [entry] needs beside it, each once: those attached,
  /// then those in its text.
  static List<BlobId> picturesOf(DynamicEntry entry) => {
    ...AttachmentsValue.imagesOf(entry),
    ...blobsOf(entry.attributes.values),
  }.toList();
}
