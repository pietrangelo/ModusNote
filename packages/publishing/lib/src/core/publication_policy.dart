import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'layout.dart';
import 'names.dart';
import 'publishing_exception.dart';

/// What a note becomes when published: a snapshot of the fields the person
/// chose, cleaned of anything that would reveal the rest of the vault.
@immutable
final class PublicationContent {
  PublicationContent._({
    required this.title,
    required this.slug,
    required this.layout,
    required Map<FieldKey, FieldValue> fields,
    required List<BlobId> images,
    required List<BlobId> audio,
  }) : fields = Map.unmodifiable(fields),
       images = List.unmodifiable(images),
       audio = List.unmodifiable(audio);

  /// One safe line, possibly empty (the app then shows its own words).
  final String title;
  final PageSlug slug;
  final PublicationLayout layout;

  /// The published values, in the order of the schema.
  final Map<FieldKey, FieldValue> fields;

  /// Pictures and recordings the page shows, each once: the app uploads a
  /// clean copy of each (pictures re-encoded without metadata).
  final List<BlobId> images;
  final List<BlobId> audio;
}

/// The rules on what may leave the vault when a note is published. Publishing
/// ends zero knowledge for the snapshot, so the rules fail closed: anything
/// not clearly safe to show is refused or left out.
abstract final class PublicationPolicy {
  static const maxTitle = 200;

  /// Credentials are never published, whatever is asked.
  static bool canPublish(SchemaDefinition schema) =>
      schema.id.name != 'credential' && publishableFields(schema).isNotEmpty;

  /// The fields the app may offer: never a password.
  static List<FieldDefinition> publishableFields(SchemaDefinition schema) => [
    for (final field in schema.fields)
      if (field.type is! PasswordFieldType) field,
  ];

  /// The snapshot of [entry] showing only [fields]. Links to other notes
  /// become links to their pages when [published] has them, plain text
  /// otherwise, so no id or page of a private note leaks. Without
  /// [includePictures] pictures in the text become their caption and
  /// pictures among the attachments are left out.
  static PublicationContent compose({
    required DynamicEntry entry,
    required SchemaDefinition schema,
    required Set<FieldKey> fields,
    Map<EntryId, PageSlug> published = const {},
    bool includePictures = true,
  }) {
    if (schema.id.name == 'credential') {
      throw const NotPublishableException('credentials are never published');
    }
    final offered = {for (final f in publishableFields(schema)) f.key};
    if (!offered.containsAll(fields)) {
      throw const NotPublishableException('field may not be published');
    }
    final out = <FieldKey, FieldValue>{};
    final images = <BlobId>{};
    final audio = <BlobId>{};
    String? title;
    for (final field in schema.fields) {
      if (!fields.contains(field.key)) continue;
      final value = entry.valueOf(field.key);
      final kept = switch (value) {
        null || SecretValue() => null,
        TextValue(:final text) => TextValue(
          _pictures(_links(text, published), includePictures, images),
        ),
        AttachmentsValue(:final items) => _attachments(
          items,
          includePictures,
          images,
        ),
        AudioBlobValue(:final blob) =>
          (audio..add(blob)).isEmpty ? null : value,
        _ => value,
      };
      if (kept == null) continue;
      out[field.key] = kept;
      if (title == null && kept is TextValue && _isText(field.type)) {
        title = _titleOf(kept.text);
      }
    }
    final safeTitle = title ?? '';
    return PublicationContent._(
      title: safeTitle,
      slug: PageSlug.fromTitle(safeTitle),
      layout: PublicationLayout.forSchemaName(schema.id.name),
      fields: out,
      images: images.toList(),
      audio: audio.toList(),
    );
  }

  static bool _isText(FieldType type) =>
      type is TextFieldType ||
      type is RichTextFieldType ||
      type is MarkdownFieldType;

  static final _noteLink = RegExp(
    r'\[([^\[\]\n]*)\]\(note:([A-Za-z0-9_-]{1,128})\)',
  );

  /// Any other spelling of a note's address (a title after it, an autolink,
  /// a reference definition): its id goes too, failing closed.
  static final _residualNote = RegExp(r'note:[A-Za-z0-9_-]{1,128}');

  static String _links(String text, Map<EntryId, PageSlug> published) => text
      .replaceAllMapped(_noteLink, (m) {
        final label = m.group(1)!;
        final slug = published[EntryId(m.group(2)!)];
        return slug == null ? label : '[$label](page:${slug.value})';
      })
      .replaceAll(_residualNote, 'note:');

  static String _pictures(String text, bool include, Set<BlobId> images) {
    final found = InlineImages.find(text);
    if (include) {
      images.addAll(found.map((i) => i.blob));
      return text;
    }
    final out = StringBuffer();
    var at = 0;
    for (final image in found) {
      out
        ..write(text.substring(at, image.start))
        ..write(image.caption);
      at = image.end;
    }
    return (out..write(text.substring(at))).toString();
  }

  static AttachmentsValue? _attachments(
    List<Attachment> items,
    bool includePictures,
    Set<BlobId> images,
  ) {
    final kept = [
      for (final item in items)
        if (item is! ImageAttachment || includePictures) item,
    ];
    images.addAll(kept.whereType<ImageAttachment>().map((i) => i.blob));
    return kept.isEmpty ? null : AttachmentsValue(kept);
  }

  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\u2028\u2029]',
  );

  static String _titleOf(String text) {
    final line = text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*#{1,6}\s+'), ''))
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    var safe = line
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    if (safe.length > maxTitle) {
      var cut = maxTitle;
      final last = safe.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut--;
      safe = safe.substring(0, cut).trim();
    }
    return safe;
  }
}
