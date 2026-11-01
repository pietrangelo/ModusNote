import 'dart:convert';
import 'dart:typed_data';

import 'attachment.dart';
import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';
import 'json_reader.dart';
import 'schema_definition.dart';
import 'schema_exception.dart';
import 'violation.dart';

/// Bytes form of a [DynamicEntry], the plaintext that the Offline Sync
/// context signs and seals: it never leaves the device unencrypted.
///
/// Decoding treats its input as hostile, like [SchemaCodec]: bounded size
/// and nesting, strict types, no stray properties, and
/// [EntryFormatException] as the only exception. A well-formed entry is
/// then validated against its schema again.
abstract final class EntryCodec {
  static const maxDocumentLength = 1024 * 1024;
  static const _maxNestingDepth = 5;
  static const _format = 1;

  static Uint8List encode(DynamicEntry entry) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': _format,
        'id': entry.id.value,
        'schema': entry.schemaId.name,
        'version': entry.schemaId.version,
        'createdAt': entry.audit.createdAt.microsecondsSinceEpoch,
        'updatedAt': entry.audit.updatedAt.microsecondsSinceEpoch,
        'revision': entry.audit.revision,
        'attributes': {
          for (final MapEntry(:key, :value) in entry.attributes.entries)
            key.value: _encodeValue(value),
        },
      }),
    ),
  );

  /// [schemas] resolves the schema an entry names; an entry whose schema
  /// this device does not hold yet comes back [Invalid] with
  /// [ViolationCode.schemaMismatch], not as a format error.
  static Validated<DynamicEntry> decode(
    List<int> bytes, {
    required SchemaDefinition? Function(SchemaId) schemas,
  }) {
    if (bytes.length > maxDocumentLength) {
      throw const EntryFormatException('document too large');
    }
    try {
      final json = JsonObject.of(
        parseBoundedJson(utf8.decode(bytes), maxDepth: _maxNestingDepth),
        'entry',
      )..allowOnly(_properties);
      if (json.integer('format') != _format) {
        throw const EntryFormatException('unknown entry format');
      }
      final schemaId = SchemaId(json.string('schema'), json.integer('version'));
      final id = EntryId(json.string('id'));
      final audit = _decodeAudit(json);
      final attributes = {
        for (final MapEntry(:key, :value)
            in json.object('attributes').entries.entries)
          FieldKey(key): _decodeValue(JsonObject.of(value, 'attribute')),
      };
      final schema = schemas(schemaId);
      if (schema == null) {
        return Invalid(const [Violation(ViolationCode.schemaMismatch)]);
      }
      return DynamicEntry.restore(
        schema: schema,
        id: id,
        attributes: attributes,
        audit: audit,
      );
    } on FormatException {
      throw const EntryFormatException('not UTF-8');
    } on JsonShapeException catch (e) {
      throw EntryFormatException(e.message);
    } on InvalidSchemaException catch (e) {
      throw EntryFormatException('invalid identifier: ${e.invariant.name}');
    } on InvalidValueException catch (e) {
      throw EntryFormatException(e.message);
    }
  }

  static const _properties = {
    'format',
    'id',
    'schema',
    'version',
    'createdAt',
    'updatedAt',
    'revision',
    'attributes',
  };

  static AuditTrail _decodeAudit(JsonObject json) {
    final createdAt = _instant(json.integer('createdAt'));
    final updatedAt = _instant(json.integer('updatedAt'));
    final revision = json.integer('revision');
    if (revision < 1 || updatedAt.isBefore(createdAt)) {
      throw const EntryFormatException('impossible audit trail');
    }
    return AuditTrail(
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: revision,
    );
  }

  static DateTime _instant(int micros) {
    try {
      return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
    } on ArgumentError {
      throw const EntryFormatException('instant out of range');
    }
  }

  static Map<String, Object?> _encodeValue(FieldValue value) => switch (value) {
    TextValue(:final text) => {'kind': 'text', 'value': text},
    SecretValue(:final text) => {'kind': 'secret', 'value': text},
    NumberValue(:final number) => {'kind': 'number', 'value': number},
    DateValue(:final year, :final month, :final day) => {
      'kind': 'date',
      'value': [year, month, day],
    },
    DateTimeValue(:final instant) => {
      'kind': 'datetime',
      'value': instant.microsecondsSinceEpoch,
    },
    BooleanValue(:final value) => {'kind': 'boolean', 'value': value},
    RatingValue(:final rating) => {'kind': 'rating', 'value': rating},
    ChoiceValue(:final option) => {'kind': 'choice', 'value': option},
    TagListValue(:final tags) => {
      'kind': 'tags',
      'value': [...tags],
    },
    AudioBlobValue(:final blob) => {'kind': 'audio', 'value': blob.value},
    ChecklistValue(:final items) => {
      'kind': 'checklist',
      'value': [
        for (final item in items) [item.text, item.done],
      ],
    },
    AttachmentsValue(:final items) => {
      'kind': 'attachments',
      'value': [
        for (final item in items)
          switch (item) {
            ImageAttachment(:final blob, :final caption) => [
              'image',
              blob.value,
              caption,
            ],
            WebLink(:final url, :final title) => ['link', url, title],
          },
      ],
    },
    // [name, amount or null, unit or null, quantity, link or null].
    IngredientsValue(:final items) => {
      'kind': 'ingredients',
      'value': [
        for (final item in items)
          [
            item.name,
            item.amount,
            item.unit?.name,
            item.quantity,
            item.link?.url,
          ],
      ],
    },
    // [text, blob, caption, blob, caption, ..., video?]: flat, so a step
    // stays within the nesting the decoder allows; an odd one out at the
    // end is the step's video.
    StepsValue(:final steps) => {
      'kind': 'steps',
      'value': [
        for (final step in steps)
          [
            step.text,
            for (final picture in step.pictures) ...[
              picture.blob.value,
              picture.caption,
            ],
            ?step.video?.value,
          ],
      ],
    },
    ChoiceSetValue(:final options) => {
      'kind': 'choice_set',
      'value': [...options]..sort(),
    },
  };

  static FieldValue _decodeValue(JsonObject json) {
    json.allowOnly({'kind', 'value'});
    final kind = json.string('kind');
    return switch (kind) {
      'text' => TextValue(json.string('value')),
      'secret' => SecretValue(json.string('value')),
      'number' => NumberValue(json.number('value')),
      'date' => switch (json.integers('value')) {
        [final year, final month, final day] => DateValue(year, month, day),
        _ => throw const EntryFormatException('a date is [year, month, day]'),
      },
      'datetime' => DateTimeValue(_instant(json.integer('value'))),
      'boolean' => BooleanValue(json.boolean('value')),
      'rating' => RatingValue(json.integer('value')),
      'choice' => ChoiceValue(json.string('value')),
      'tags' => switch (json.strings('value')) {
        final tags when tags.toSet().length == tags.length => TagListValue(
          tags.toSet(),
        ),
        _ => throw const EntryFormatException('duplicate tags'),
      },
      'audio' => AudioBlobValue(BlobId(json.string('value'))),
      'checklist' => ChecklistValue([
        for (final item in json.list('value'))
          switch (item) {
            [final String text, final bool done] => ChecklistItem(
              text,
              done: done,
            ),
            _ => throw const EntryFormatException('a task is [text, done]'),
          },
      ]),
      'attachments' => AttachmentsValue([
        for (final item in json.list('value'))
          switch (item) {
            ['image', final String blob, final String caption] =>
              ImageAttachment(BlobId(blob), caption: caption),
            ['link', final String url, final String title] => WebLink(
              url,
              title: title,
            ),
            _ => throw const EntryFormatException(
              'an attachment is [kind, target, text]',
            ),
          },
      ]),
      'ingredients' => IngredientsValue([
        for (final item in json.list('value'))
          switch (item) {
            [
              final String name,
              final num? amount,
              final String? unit,
              final String quantity,
              final String? link,
            ] =>
              Ingredient(
                name,
                amount: amount,
                unit: unit == null ? null : _unitNamed(unit),
                quantity: quantity,
                link: link == null ? null : WebLink(link),
              ),
            _ => throw const EntryFormatException(
              'an ingredient is [name, amount, unit, quantity, link]',
            ),
          },
      ]),
      'steps' => StepsValue([
        for (final step in json.list('value'))
          switch (step) {
            [final String text, ...final rest] => PreparationStep(
              text,
              pictures: [
                for (var i = 0; i + 1 < rest.length; i += 2)
                  switch ((rest[i], rest[i + 1])) {
                    (final String blob, final String caption) =>
                      ImageAttachment(BlobId(blob), caption: caption),
                    _ => throw const EntryFormatException(
                      'a step picture is a blob and a caption',
                    ),
                  },
              ],
              video: rest.length.isOdd
                  ? switch (rest.last) {
                      final String blob => BlobId(blob),
                      _ => throw const EntryFormatException(
                        'a step video is a blob',
                      ),
                    }
                  : null,
            ),
            _ => throw const EntryFormatException(
              'a step is [text, blob, caption, ..., video]',
            ),
          },
      ]),
      'choice_set' => switch (json.strings('value')) {
        final options when options.toSet().length == options.length =>
          ChoiceSetValue(options.toSet()),
        _ => throw const EntryFormatException('duplicate options'),
      },
      _ => throw const EntryFormatException('unknown value kind'),
    };
  }

  static IngredientUnit _unitNamed(String name) {
    for (final unit in IngredientUnit.values) {
      if (unit.name == name) return unit;
    }
    throw const EntryFormatException('unknown unit');
  }
}
