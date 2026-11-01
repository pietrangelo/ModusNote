import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'layout.dart';
import 'media.dart';
import 'publication_policy.dart';
import 'publishing_exception.dart';

/// One part of a published page, as serv.pub takes it: a field of the note
/// the person chose, already cleaned by [PublicationPolicy].
@immutable
sealed class PageBlock {
  const PageBlock(this.label);

  /// The field's name, one safe line, possibly empty.
  final String label;

  Map<String, Object> toJson();
}

final class MarkdownBlock extends PageBlock {
  const MarkdownBlock(super.label, this.text);

  final String text;

  @override
  Map<String, Object> toJson() => {
    'kind': 'markdown',
    'label': label,
    'text': text,
  };
}

final class TextBlock extends PageBlock {
  const TextBlock(super.label, this.text);

  final String text;

  @override
  Map<String, Object> toJson() => {
    'kind': 'text',
    'label': label,
    'text': text,
  };
}

final class TagsBlock extends PageBlock {
  const TagsBlock(super.label, this.items);

  final List<String> items;

  @override
  Map<String, Object> toJson() => {
    'kind': 'tags',
    'label': label,
    'items': items,
  };
}

final class ChecklistBlock extends PageBlock {
  const ChecklistBlock(super.label, this.items);

  final List<ChecklistItem> items;

  @override
  Map<String, Object> toJson() => {
    'kind': 'checklist',
    'label': label,
    'items': [
      for (final item in items) {'text': item.text, 'done': item.done},
    ],
  };
}

final class LinksBlock extends PageBlock {
  const LinksBlock(super.label, this.items);

  final List<WebLink> items;

  @override
  Map<String, Object> toJson() => {
    'kind': 'links',
    'label': label,
    'items': [
      for (final link in items) {'url': link.url, 'title': link.title},
    ],
  };
}

final class ImageBlock extends PageBlock {
  const ImageBlock(super.label, this.media, this.caption);

  final MediaId media;
  final String caption;

  @override
  Map<String, Object> toJson() => {
    'kind': 'image',
    'label': label,
    'media': media.value,
    'caption': caption,
  };
}

final class AudioBlock extends PageBlock {
  const AudioBlock(super.label, this.media);

  final MediaId media;

  @override
  Map<String, Object> toJson() => {
    'kind': 'audio',
    'label': label,
    'media': media.value,
  };
}

/// A page as serv.pub takes it (`PUT /api/s/<site>/p/<slug>`): its title,
/// layout, whether the site's home lists it, and its parts.
@immutable
final class PageDocument {
  PageDocument({
    required this.title,
    required this.layout,
    required this.listed,
    required List<PageBlock> blocks,
  }) : blocks = List.unmodifiable(blocks);

  final String title;
  final PublicationLayout layout;
  final bool listed;
  final List<PageBlock> blocks;

  /// Every file the page shows, each once, in order.
  List<MediaId> get media {
    final out = <MediaId>{};
    for (final block in blocks) {
      switch (block) {
        case ImageBlock(:final media) || AudioBlock(:final media):
          out.add(media);
        case MarkdownBlock(:final text):
          out.addAll(PageComposer.mediaIn(text));
        default:
      }
    }
    return out.toList();
  }

  Map<String, Object> toJson() => {
    'title': title,
    // A page is never a grid of cards: that is the home's layout.
    'layout': switch (layout) {
      PublicationLayout.essay || PublicationLayout.collection => 'essay',
      PublicationLayout.goldenSection => 'golden_section',
      PublicationLayout.goldenCover => 'golden_cover',
      PublicationLayout.book => 'book',
    },
    'listed': listed,
    'blocks': [for (final block in blocks) block.toJson()],
  };
}

/// Turns a [PublicationContent] into the [PageDocument] serv.pub takes,
/// within the limits it checks, so the server never has to refuse a page
/// the app built.
abstract final class PageComposer {
  static const maxTitle = 200;
  static const maxLabel = 89;
  static const maxShort = 610;
  static const maxMarkdown = 500000;
  static const maxBlocks = 64;
  static const maxItems = 500;

  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\u2028\u2029]',
  );

  /// Control characters but line breaks and tabs.
  static final _unsafeInText = RegExp(
    r'[\x00-\x08\x0B-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\u2028\u2029]',
  );

  static final _residualImage = RegExp(r'image:([A-Za-z0-9_-]{1,128})');

  static final _mediaImage = RegExp(
    r'!\[[^\[\]\n]*\]\(image:([A-Za-z0-9_-]{16,64})\)',
  );

  /// The page of [content], whose fields come from [schema]. [media] names
  /// the uploaded copy of each picture and recording: one without a copy
  /// (a format serv.pub does not take) is left out, an inline picture
  /// keeping its caption. [labelOf] and [describe] give the field's name
  /// and a value without a block of its own (a number, a date) in the
  /// person's language. Throws [NotPublishableException] when nothing is
  /// left to show or the page has more parts than serv.pub takes.
  static PageDocument compose({
    required PublicationContent content,
    required SchemaDefinition schema,
    required Map<BlobId, MediaId> media,
    required String Function(FieldDefinition field) labelOf,
    required String Function(FieldDefinition field, FieldValue value) describe,
    required bool listed,
    String Function(Ingredient item)? ingredientLine,
    PublicationLayout? layout,
  }) {
    final blocks = <PageBlock>[];
    var first = true;
    for (final field in schema.fields) {
      final value = content.fields[field.key];
      if (value == null) continue;
      final label = line(labelOf(field), maxLabel);
      switch (value) {
        case TextValue(:final text) when field.type is UrlFieldType:
          if (WebLink.parse(text) case final link?) {
            blocks.add(LinksBlock(label, [link]));
          }
        case TextValue(:final text) when field.type is TextFieldType:
          final short = line(text, maxShort);
          if (short.isEmpty) break;
          // The note's first line is already the page's title.
          if (first && short == content.title) {
            first = false;
            break;
          }
          blocks.add(
            !text.contains('\n') && text.length <= maxShort
                ? TextBlock(label, short)
                : MarkdownBlock(label, _markdown(text, media)),
          );
        case TextValue(:final text):
          final body = first ? _withoutTitle(text, content.title) : text;
          final markdown = _markdown(body, media);
          if (markdown.trim().isNotEmpty) {
            // The text a page opens with needs no name above it.
            blocks.add(MarkdownBlock(blocks.isEmpty ? '' : label, markdown));
          }
        case TagListValue(:final tags):
          final items = _items(tags.map((t) => line(t, maxShort)));
          if (items.isNotEmpty) blocks.add(TagsBlock(label, items));
        case ChecklistValue(:final items):
          final kept = [
            for (final item in items.take(maxItems))
              if (line(item.text, maxShort) case final text
                  when text.isNotEmpty)
                ChecklistItem(text, done: item.done),
          ];
          if (kept.isNotEmpty) blocks.add(ChecklistBlock(label, kept));
        case AttachmentsValue(:final items):
          final links = <WebLink>[];
          var named = false;
          for (final item in items) {
            switch (item) {
              case ImageAttachment(:final blob, :final caption):
                if (media[blob] case final id?) {
                  blocks.add(
                    ImageBlock(named ? '' : label, id, line(caption, maxShort)),
                  );
                  named = true;
                }
              case WebLink():
                links.add(item);
            }
          }
          if (links.isNotEmpty) {
            blocks.add(
              LinksBlock(named ? '' : label, links.take(maxItems).toList()),
            );
          }
        case AudioBlobValue(:final blob):
          if (media[blob] case final id?) blocks.add(AudioBlock(label, id));
        case IngredientsValue(:final items):
          final lines = [
            for (final item in items.take(maxItems))
              if (_escaped(line((ingredientLine ?? _named)(item), maxShort))
                  case final text when text.isNotEmpty)
                switch (item.link) {
                  final link? when link.url.startsWith('https://') =>
                    '- $text ([${_escaped(link.host)}](<${_angled(link.url)}>))',
                  _ => '- $text',
                },
          ];
          if (lines.isNotEmpty) {
            blocks.add(MarkdownBlock(label, lines.join('\n')));
          }
        case StepsValue(:final steps):
          final out = StringBuffer();
          for (final (index, step) in steps.take(maxItems).indexed) {
            out.write(
              '**${index + 1}.** ${_markdown(step.text, media).trim()}',
            );
            for (final picture in step.pictures) {
              if (media[picture.blob] case final id?) {
                out.write(
                  '\n\n![${InlineImages.safeCaption(picture.caption)}]'
                  '(image:${id.value})',
                );
              }
            }
            out.write('\n\n');
          }
          final text = out.toString().trim();
          if (text.isNotEmpty) blocks.add(MarkdownBlock(label, text));
        case SecretValue():
          // Never published, whatever reached here.
          break;
        default:
          final text = line(describe(field, value), maxShort);
          if (text.isNotEmpty) blocks.add(TextBlock(label, text));
      }
      if (value is TextValue) first = false;
    }
    if (blocks.isEmpty) {
      throw const NotPublishableException('nothing to publish');
    }
    if (blocks.length > maxBlocks) {
      throw const NotPublishableException('too many parts');
    }
    return PageDocument(
      title: line(content.title, maxTitle),
      layout: layout ?? content.layout,
      listed: listed,
      blocks: blocks,
    );
  }

  static String _named(Ingredient item) => item.name;

  /// [text] shown as written inside a list item: every mark Markdown
  /// could read as emphasis, a link, code, a table or HTML escaped. Marks
  /// that only count at the start of a line (`#`, `-`, `1.`) cannot be
  /// there: the item starts with `- `.
  static String _escaped(String text) => text.replaceAllMapped(
    RegExp(r'[\\`*_{}\[\]()!|<>~&]'),
    (m) => '\\${m[0]}',
  );

  /// An address as a Markdown destination in angle brackets.
  static String _angled(String url) =>
      url.replaceAll('<', '%3C').replaceAll('>', '%3E');

  /// Files a page's Markdown shows.
  static Iterable<MediaId> mediaIn(String markdown) =>
      _mediaImage.allMatches(markdown).map((m) => MediaId(m.group(1)!));

  /// [text] as one safe line of at most [max] UTF-16 code units, a
  /// character never cut in half.
  static String line(String text, int max) {
    var safe = text
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    if (safe.length > max) {
      var cut = max;
      final last = safe.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut--;
      safe = safe.substring(0, cut).trim();
    }
    return safe;
  }

  static List<String> _items(Iterable<String> items) => [
    for (final item in items.take(maxItems))
      if (item.isNotEmpty) item,
  ];

  /// Pictures point at their uploaded copy, or become their caption.
  static String _markdown(String text, Map<BlobId, MediaId> media) {
    final out = StringBuffer();
    var at = 0;
    for (final image in InlineImages.find(text)) {
      out.write(text.substring(at, image.start));
      final id = media[image.blob];
      out.write(
        id == null ? image.caption : '![${image.caption}](image:${id.value})',
      );
      at = image.end;
    }
    out.write(text.substring(at));
    // Any other spelling of a picture's address (a reference definition,
    // brackets in the caption) loses its id, failing closed: a vault's
    // blob id never reaches the page, and serv.pub never sees a picture
    // that was not uploaded.
    final uploaded = {for (final id in media.values) id.value};
    var safe = out
        .toString()
        .replaceAllMapped(
          _residualImage,
          (m) => uploaded.contains(m.group(1)) ? m.group(0)! : 'image:',
        )
        .replaceAll(_unsafeInText, ' ');
    if (safe.length > maxMarkdown) {
      var cut = maxMarkdown;
      final last = safe.codeUnitAt(cut - 1);
      if (last >= 0xD800 && last <= 0xDBFF) cut--;
      safe = safe.substring(0, cut);
    }
    return safe;
  }

  /// The text without its first line when that line is the title.
  static String _withoutTitle(String text, String title) {
    if (title.isEmpty) return text;
    final lines = text.split('\n');
    final index = lines.indexWhere((l) => l.trim().isNotEmpty);
    if (index < 0) return text;
    final heading = lines[index].replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '');
    if (line(heading, maxTitle) != title) return text;
    return lines.sublist(index + 1).join('\n');
  }
}
