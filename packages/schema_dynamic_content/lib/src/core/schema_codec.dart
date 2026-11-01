import 'dart:convert';

import 'field_type.dart';
import 'identifiers.dart';
import 'json_reader.dart';
import 'label.dart';
import 'schema_definition.dart';
import 'schema_exception.dart';

/// JSON form of [SchemaDefinition], for storage and sync (always inside an
/// encrypted envelope).
///
/// Decoding treats its input as hostile: size and nesting are bounded before
/// parsing, every property is type-checked, unknown properties are refused,
/// and the only exception that can escape is [SchemaFormatException].
abstract final class SchemaCodec {
  static const maxDocumentLength = 64 * 1024;
  static const maxNestingDepth = 8;

  static String encode(SchemaDefinition schema) => jsonEncode({
    'id': schema.id.name,
    'version': schema.id.version,
    'label': _encodeLabel(schema.label),
    'fields': [for (final f in schema.fields) _encodeField(f)],
    'uiHints': [
      for (final h in schema.uiHints)
        {'field': h.field.value, 'section': h.section, 'order': h.order},
    ],
    if (schema.icon != null || schema.tint != null)
      'appearance': {'icon': ?schema.icon?.name, 'tint': ?schema.tint?.name},
  });

  static SchemaDefinition decode(String document) {
    if (document.length > maxDocumentLength) {
      throw const SchemaFormatException('document too large');
    }
    try {
      return _decodeSchema(
        JsonObject.of(
          parseBoundedJson(document, maxDepth: maxNestingDepth),
          'schema',
        ),
      );
    } on JsonShapeException catch (e) {
      throw SchemaFormatException(e.message);
    } on InvalidSchemaException catch (e) {
      throw SchemaFormatException('invariant broken: ${e.invariant.name}');
    } on InvalidValueException catch (e) {
      throw SchemaFormatException(e.message);
    }
  }

  static Map<String, Object?> _encodeLabel(Label label) => switch (label) {
    LocalizedLabel(:final key) => {'key': key},
    LiteralLabel(:final text) => {'text': text},
  };

  static Map<String, Object?> _encodeField(FieldDefinition field) => {
    'key': field.key.value,
    'label': _encodeLabel(field.label),
    'required': field.required,
    'type': _encodeType(field.type),
  };

  static Map<String, Object?> _encodeType(FieldType type) => switch (type) {
    TextFieldType(:final maxLength) => {'kind': 'text', 'maxLength': maxLength},
    RichTextFieldType() => {'kind': 'rich_text'},
    MarkdownFieldType() => {'kind': 'markdown'},
    NumberFieldType(:final min, :final max, :final integerOnly) => {
      'kind': 'number',
      'min': ?min,
      'max': ?max,
      'integerOnly': integerOnly,
    },
    DateFieldType() => {'kind': 'date'},
    DateTimeFieldType() => {'kind': 'date_time'},
    BooleanFieldType() => {'kind': 'boolean'},
    RatingFieldType(:final min, :final max) => {
      'kind': 'rating',
      'min': min,
      'max': max,
    },
    ChoiceFieldType(:final options) => {'kind': 'choice', 'options': options},
    TagListFieldType(:final maxTags) => {
      'kind': 'tag_list',
      'maxTags': maxTags,
    },
    AudioBlobFieldType() => {'kind': 'audio_blob'},
    ChecklistFieldType(:final maxItems) => {
      'kind': 'checklist',
      'maxItems': maxItems,
    },
    AttachmentsFieldType(:final maxItems) => {
      'kind': 'attachments',
      'maxItems': maxItems,
    },
    PasswordFieldType(:final maxLength) => {
      'kind': 'password',
      'maxLength': maxLength,
    },
    UrlFieldType() => {'kind': 'url'},
    IngredientsFieldType(:final maxItems) => {
      'kind': 'ingredients',
      'maxItems': maxItems,
    },
    StepsFieldType(:final maxItems) => {'kind': 'steps', 'maxItems': maxItems},
    ChoiceSetFieldType(:final options) => {
      'kind': 'choice_set',
      'options': options,
    },
  };

  static SchemaDefinition _decodeSchema(JsonObject json) {
    json.allowOnly({
      'id',
      'version',
      'label',
      'fields',
      'uiHints',
      'appearance',
    });
    final appearance = json.has('appearance')
        ? (json.object('appearance')..allowOnly({'icon', 'tint'}))
        : null;
    return SchemaDefinition(
      icon: _named(NoteIcon.values, appearance, 'icon'),
      tint: _named(NoteTint.values, appearance, 'tint'),
      id: SchemaId(json.string('id'), json.integer('version')),
      label: _decodeLabel(json.object('label')),
      fields: [for (final f in json.objects('fields')) _decodeField(f)],
      uiHints: [
        for (final h in json.objects('uiHints'))
          (h..allowOnly({'field', 'section', 'order'})).let(
            (h) => WidgetPlacement(
              field: FieldKey(h.string('field')),
              section: h.string('section'),
              order: h.integer('order'),
            ),
          ),
      ],
    );
  }

  /// A name this device does not know is dropped, not refused: a newer
  /// device may offer more icons and tints than this one draws.
  static T? _named<T extends Enum>(
    List<T> values,
    JsonObject? json,
    String property,
  ) {
    if (json == null || !json.has(property)) return null;
    final name = json.string(property);
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static Label _decodeLabel(JsonObject json) {
    if (json.has('key')) {
      json.allowOnly({'key'});
      return LocalizedLabel(json.string('key'));
    }
    json.allowOnly({'text'});
    return LiteralLabel(json.string('text'));
  }

  static FieldDefinition _decodeField(JsonObject json) {
    json.allowOnly({'key', 'label', 'required', 'type'});
    return FieldDefinition(
      key: FieldKey(json.string('key')),
      label: _decodeLabel(json.object('label')),
      required: json.boolean('required'),
      type: _decodeType(json.object('type')),
    );
  }

  static FieldType _decodeType(JsonObject json) {
    final kind = json.string('kind');
    final (allowed, build) = switch (kind) {
      'text' => (
        {'maxLength'},
        () => TextFieldType(maxLength: json.integer('maxLength')),
      ),
      'rich_text' => (<String>{}, () => const RichTextFieldType()),
      'markdown' => (<String>{}, () => const MarkdownFieldType()),
      'number' => (
        {'min', 'max', 'integerOnly'},
        () => NumberFieldType(
          min: json.optionalNumber('min'),
          max: json.optionalNumber('max'),
          integerOnly: json.boolean('integerOnly'),
        ),
      ),
      'date' => (<String>{}, () => const DateFieldType()),
      'date_time' => (<String>{}, () => const DateTimeFieldType()),
      'boolean' => (<String>{}, () => const BooleanFieldType()),
      'rating' => (
        {'min', 'max'},
        () =>
            RatingFieldType(min: json.integer('min'), max: json.integer('max')),
      ),
      'choice' => ({'options'}, () => ChoiceFieldType(json.strings('options'))),
      'tag_list' => (
        {'maxTags'},
        () => TagListFieldType(maxTags: json.integer('maxTags')),
      ),
      'audio_blob' => (<String>{}, () => const AudioBlobFieldType()),
      'checklist' => (
        {'maxItems'},
        () => ChecklistFieldType(maxItems: json.integer('maxItems')),
      ),
      'attachments' => (
        {'maxItems'},
        () => AttachmentsFieldType(maxItems: json.integer('maxItems')),
      ),
      'password' => (
        {'maxLength'},
        () => PasswordFieldType(maxLength: json.integer('maxLength')),
      ),
      'url' => (<String>{}, () => const UrlFieldType()),
      'ingredients' => (
        {'maxItems'},
        () => IngredientsFieldType(maxItems: json.integer('maxItems')),
      ),
      'steps' => (
        {'maxItems'},
        () => StepsFieldType(maxItems: json.integer('maxItems')),
      ),
      'choice_set' => (
        {'options'},
        () => ChoiceSetFieldType(json.strings('options')),
      ),
      _ => throw SchemaFormatException('unknown field kind "$kind"'),
    };
    json.allowOnly({'kind', ...allowed});
    return build();
  }
}
