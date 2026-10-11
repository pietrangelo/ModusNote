import 'package:meta/meta.dart';

import 'field_value.dart';
import 'list_equality.dart';
import 'schema_exception.dart';
import 'violation.dart';

final _optionKey = RegExp(r'^[a-z0-9][a-z0-9_]{0,63}$');

/// The kind of a field together with its constraints.
///
/// Sealed, so every consumer (validation, codec, the UI renderer) is forced
/// by the compiler to handle each kind; adding one is a deliberate change.
@immutable
sealed class FieldType {
  const FieldType();

  /// Why [value] does not fit this field, or nothing if it does.
  List<ViolationCode> check(FieldValue value);
}

int _length(String text) => text.runes.length;

void _requireRange(bool ok) {
  if (!ok) throw const InvalidSchemaException(SchemaInvariant.invalidRange);
}

List<ViolationCode> _textWithin(FieldValue value, int maxLength) =>
    switch (value) {
      TextValue(:final text) when _length(text) > maxLength => const [
        ViolationCode.tooLong,
      ],
      TextValue() => const [],
      _ => const [ViolationCode.typeMismatch],
    };

final class TextFieldType extends FieldType {
  TextFieldType({this.maxLength = 1000}) {
    _requireRange(maxLength > 0 && maxLength <= RichTextFieldType.maxLength);
  }

  final int maxLength;

  @override
  List<ViolationCode> check(FieldValue value) => _textWithin(value, maxLength);

  @override
  bool operator ==(Object other) =>
      other is TextFieldType && other.maxLength == maxLength;

  @override
  int get hashCode => Object.hash(TextFieldType, maxLength);
}

final class RichTextFieldType extends FieldType {
  const RichTextFieldType();

  static const maxLength = 100000;

  @override
  List<ViolationCode> check(FieldValue value) => _textWithin(value, maxLength);

  @override
  bool operator ==(Object other) => other is RichTextFieldType;

  @override
  int get hashCode => (RichTextFieldType).hashCode;
}

final class MarkdownFieldType extends FieldType {
  const MarkdownFieldType();

  @override
  List<ViolationCode> check(FieldValue value) =>
      _textWithin(value, RichTextFieldType.maxLength);

  @override
  bool operator ==(Object other) => other is MarkdownFieldType;

  @override
  int get hashCode => (MarkdownFieldType).hashCode;
}

final class NumberFieldType extends FieldType {
  NumberFieldType({this.min, this.max, this.integerOnly = false}) {
    final low = min, high = max;
    _requireRange(
      (low == null || low.isFinite) &&
          (high == null || high.isFinite) &&
          (low == null || high == null || low <= high),
    );
  }

  final num? min;
  final num? max;
  final bool integerOnly;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! NumberValue) return const [ViolationCode.typeMismatch];
    final n = value.number;
    final low = min, high = max;
    return [
      if (integerOnly && n != n.truncate()) ViolationCode.notAnInteger,
      if ((low != null && n < low) || (high != null && n > high))
        ViolationCode.outOfRange,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is NumberFieldType &&
      other.min == min &&
      other.max == max &&
      other.integerOnly == integerOnly;

  @override
  int get hashCode => Object.hash(NumberFieldType, min, max, integerOnly);
}

final class DateFieldType extends FieldType {
  const DateFieldType();

  @override
  List<ViolationCode> check(FieldValue value) =>
      value is DateValue ? const [] : const [ViolationCode.typeMismatch];

  @override
  bool operator ==(Object other) => other is DateFieldType;

  @override
  int get hashCode => (DateFieldType).hashCode;
}

final class DateTimeFieldType extends FieldType {
  const DateTimeFieldType();

  @override
  List<ViolationCode> check(FieldValue value) =>
      value is DateTimeValue ? const [] : const [ViolationCode.typeMismatch];

  @override
  bool operator ==(Object other) => other is DateTimeFieldType;

  @override
  int get hashCode => (DateTimeFieldType).hashCode;
}

final class BooleanFieldType extends FieldType {
  const BooleanFieldType();

  @override
  List<ViolationCode> check(FieldValue value) =>
      value is BooleanValue ? const [] : const [ViolationCode.typeMismatch];

  @override
  bool operator ==(Object other) => other is BooleanFieldType;

  @override
  int get hashCode => (BooleanFieldType).hashCode;
}

final class RatingFieldType extends FieldType {
  RatingFieldType({required this.min, required this.max}) {
    _requireRange(0 <= min && min < max && max <= 10);
  }

  final int min;
  final int max;

  @override
  List<ViolationCode> check(FieldValue value) => switch (value) {
    RatingValue(:final rating) when rating < min || rating > max => const [
      ViolationCode.outOfRange,
    ],
    RatingValue() => const [],
    _ => const [ViolationCode.typeMismatch],
  };

  @override
  bool operator ==(Object other) =>
      other is RatingFieldType && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(RatingFieldType, min, max);
}

/// A closed set of options, used for both "select" and "enum" fields.
/// Options are identifiers the UI localizes, not display text.
final class ChoiceFieldType extends FieldType {
  ChoiceFieldType(List<String> options) : options = List.unmodifiable(options) {
    if (options.isEmpty ||
        options.length > maxOptions ||
        options.toSet().length != options.length ||
        !options.every(_optionKey.hasMatch)) {
      throw const InvalidSchemaException(SchemaInvariant.invalidChoiceOptions);
    }
  }

  static const maxOptions = 64;

  final List<String> options;

  @override
  List<ViolationCode> check(FieldValue value) => switch (value) {
    ChoiceValue(:final option) when !options.contains(option) => const [
      ViolationCode.invalidChoice,
    ],
    ChoiceValue() => const [],
    _ => const [ViolationCode.typeMismatch],
  };

  @override
  bool operator ==(Object other) =>
      other is ChoiceFieldType && listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(ChoiceFieldType, Object.hashAll(options));
}

final class TagListFieldType extends FieldType {
  TagListFieldType({this.maxTags = 32}) {
    _requireRange(maxTags > 0 && maxTags <= 256);
  }

  static const maxTagLength = 64;

  final int maxTags;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! TagListValue) return const [ViolationCode.typeMismatch];
    return [
      if (value.tags.length > maxTags) ViolationCode.tooManyTags,
      if (value.tags.any((t) => t.trim().isEmpty || _length(t) > maxTagLength))
        ViolationCode.tooLong,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is TagListFieldType && other.maxTags == maxTags;

  @override
  int get hashCode => Object.hash(TagListFieldType, maxTags);
}

final class AudioBlobFieldType extends FieldType {
  const AudioBlobFieldType();

  @override
  List<ViolationCode> check(FieldValue value) =>
      value is AudioBlobValue ? const [] : const [ViolationCode.typeMismatch];

  @override
  bool operator ==(Object other) => other is AudioBlobFieldType;

  @override
  int get hashCode => (AudioBlobFieldType).hashCode;
}
