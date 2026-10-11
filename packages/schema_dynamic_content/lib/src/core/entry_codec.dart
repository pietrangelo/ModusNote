import 'dart:convert';
import 'dart:typed_data';

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
  };

  static FieldValue _decodeValue(JsonObject json) {
    json.allowOnly({'kind', 'value'});
    final kind = json.string('kind');
    return switch (kind) {
      'text' => TextValue(json.string('value')),
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
      _ => throw const EntryFormatException('unknown value kind'),
    };
  }
}
