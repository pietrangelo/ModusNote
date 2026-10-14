import 'dart:convert';
import 'dart:typed_data';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/note_title.dart';
import '../notes/schema_text.dart';
import 'zip_writer.dart';

/// The words the export writes that are not the user's own.
typedef MarkdownExportText = ({
  String untitled,
  String recording,
  String picture,
  String Function(DateTime) date,
});

/// Every note as a Markdown file, in a folder per category, packed into a
/// ZIP: readable anywhere, and so in clear. Recordings and pictures stay
/// out (their files are sealed); a line says where they were.
final class MarkdownExport {
  MarkdownExport({
    required this.schemas,
    required this.labels,
    required this.words,
    required this.categories,
    required this.categoryOf,
  });

  final List<SchemaDefinition> schemas;
  final SchemaText labels;
  final MarkdownExportText words;
  final CategoryTree categories;
  final CategoryId? Function(EntryId id) categoryOf;

  /// Longest file or folder name, in characters, before `.md`.
  static const maxName = 80;

  Uint8List archive(Iterable<DynamicEntry> entries, {required DateTime at}) {
    final zip = ZipWriter(at: at);
    final taken = <String>{};
    for (final entry in entries) {
      final schema = _schemaOf(entry);
      final filed = categories.resolve(categoryOf(entry.id));
      final folder = [
        if (filed != null)
          for (final category in categories.pathTo(filed))
            safeName(category.name.value, fallback: words.untitled),
      ].join('/');
      final title = NoteTitle.of(entry, schema);
      final base = safeName(title, fallback: words.untitled);
      final stem = folder.isEmpty ? base : '$folder/$base';
      var name = '$stem.md';
      for (var n = 2; !taken.add(name.toLowerCase()); n++) {
        name = '$stem ($n).md';
      }
      zip.add(name, utf8.encode(render(entry, schema, title: title)));
    }
    return zip.finish();
  }

  /// One note's Markdown: the title as a heading, the body as written, the
  /// other fields as labelled lines.
  String render(
    DynamicEntry entry,
    SchemaDefinition? schema, {
    required String title,
  }) {
    final out = StringBuffer()
      ..writeln('# ${title.isEmpty ? words.untitled : _oneLine(title)}')
      ..writeln();
    final primary = schema?.primaryTextField;
    FieldKey? body;
    for (final field in schema?.fields ?? const <FieldDefinition>[]) {
      if (field.type is MarkdownFieldType || field.type is RichTextFieldType) {
        if (field.key != primary?.key) {
          body = field.key;
          break;
        }
      }
    }
    if (body != null) {
      if (entry.valueOf(body) case TextValue(:final text)
          when text.trim().isNotEmpty) {
        out
          ..writeln(_pictures(text, words).trimRight())
          ..writeln();
      }
    }
    for (final field in schema?.fields ?? const <FieldDefinition>[]) {
      if (field.key == primary?.key || field.key == body) continue;
      final value = entry.valueOf(field.key);
      if (value == null) continue;
      final label = labels.label(field.label);
      switch (value) {
        case ChecklistValue(:final items):
          if (items.isEmpty) continue;
          out.writeln('## $label');
          out.writeln();
          for (final item in items) {
            out.writeln('- [${item.done ? 'x' : ' '}] ${_oneLine(item.text)}');
          }
          out.writeln();
        case AttachmentsValue(:final items):
          if (items.isEmpty) continue;
          out.writeln('## $label');
          out.writeln();
          for (final item in items) {
            out.writeln(switch (item) {
              WebLink(:final url, :final title) =>
                '- [${_escape(title.isEmpty ? url : title)}](<${_angle(url)}>)',
              ImageAttachment(:final caption) =>
                '- ${words.picture}${caption.isEmpty ? '' : ': ${_oneLine(caption)}'}',
            });
          }
          out.writeln();
        case TextValue(:final text) when field.type is! TextFieldType:
          if (text.trim().isEmpty) continue;
          out
            ..writeln('## $label')
            ..writeln()
            ..writeln(_pictures(text, words).trimRight())
            ..writeln();
        default:
          final shown = _scalar(field, value);
          if (shown.isEmpty) continue;
          out.writeln('**$label:** $shown  ');
      }
    }
    return '${out.toString().trimRight()}\n';
  }

  String _scalar(FieldDefinition field, FieldValue value) => switch (value) {
    TextValue(:final text) => _oneLine(text),
    NumberValue(:final number) => '$number',
    DateValue(:final year, :final month, :final day) => words.date(
      DateTime(year, month, day),
    ),
    DateTimeValue(:final instant) => words.date(instant.toLocal()),
    BooleanValue(value: final yes) => yes ? '✓' : '✗',
    RatingValue(:final rating) => switch (field.type) {
      RatingFieldType(:final max) => '$rating/$max',
      _ => '$rating',
    },
    ChoiceValue(:final option) => labels.option(field, option),
    TagListValue(:final tags) => tags.map(_oneLine).join(', '),
    AudioBlobValue() => words.recording,
    _ => '',
  };

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  /// [text] as a file or folder name every system accepts: no separators,
  /// reserved or control characters, no leading or trailing dots and
  /// spaces, at most [maxName] characters; [fallback] when nothing is left.
  static String safeName(String text, {required String fallback}) {
    final cleaned = text
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
    final runes = cleaned.runes.take(maxName).toList();
    final cut = String.fromCharCodes(runes).replaceAll(RegExp(r'[\s.]+$'), '');
    if (cut.isEmpty || _reserved.hasMatch(cut)) return fallback;
    return cut;
  }

  static final _unsafe = RegExp(
    '[\\\\/:*?"<>|\\x00-\\x1F\\x7F'
    '\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]',
  );

  /// Names Windows keeps for devices.
  static final _reserved = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
    caseSensitive: false,
  );

  /// [text] with each picture written in it ([InlineImages]) as a line
  /// naming it: the export holds no pictures, and an `image:` address
  /// means nothing outside the app.
  static String _pictures(String text, MarkdownExportText words) {
    final pictures = InlineImages.find(text);
    if (pictures.isEmpty) return text;
    final out = StringBuffer();
    var from = 0;
    for (final picture in pictures) {
      final caption = picture.caption;
      out
        ..write(text.substring(from, picture.start))
        ..write('_${words.picture}')
        ..write(caption.isEmpty ? '' : ': ${_escape(caption)}')
        ..write('_');
      from = picture.end;
    }
    out.write(text.substring(from));
    return out.toString();
  }

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

  static String _angle(String url) =>
      url.replaceAll('<', '%3C').replaceAll('>', '%3E');

  static String _escape(String text) =>
      _oneLine(text).replaceAllMapped(RegExp(r'[\[\]\\]'), (m) => '\\${m[0]}');
}
