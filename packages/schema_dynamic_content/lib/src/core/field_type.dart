import 'package:meta/meta.dart';

import 'attachment.dart';
import 'field_value.dart';
import 'list_equality.dart';
import 'schema_exception.dart';
import 'unsafe_text.dart';
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
      if (value.tags.any(containsUnsafeCharacters))
        ViolationCode.invalidCharacters,
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

/// A list of one-line tasks, each done or not.
final class ChecklistFieldType extends FieldType {
  ChecklistFieldType({this.maxItems = 200}) {
    _requireRange(maxItems > 0 && maxItems <= maxAllowedItems);
  }

  static const maxAllowedItems = 1000;
  static const maxItemLength = 500;

  final int maxItems;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! ChecklistValue) return const [ViolationCode.typeMismatch];
    final items = value.items;
    return [
      // An empty list is no list: the UI removes the field instead.
      if (items.isEmpty) ViolationCode.missingRequired,
      if (items.length > maxItems) ViolationCode.tooManyItems,
      if (items.any((item) => item.text.trim().isEmpty))
        ViolationCode.emptyItem,
      if (items.any((item) => _length(item.text) > maxItemLength))
        ViolationCode.tooLong,
      if (items.any((item) => containsUnsafeCharacters(item.text)))
        ViolationCode.invalidCharacters,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is ChecklistFieldType && other.maxItems == maxItems;

  @override
  int get hashCode => Object.hash(ChecklistFieldType, maxItems);
}

/// Pictures and links placed in a page ([AttachmentsValue]). An image
/// appears once; captions and titles are checked when they are made.
final class AttachmentsFieldType extends FieldType {
  AttachmentsFieldType({this.maxItems = 34}) {
    _requireRange(maxItems > 0 && maxItems <= maxAllowedItems);
  }

  /// Bounds the blobs one note can pull in.
  static const maxAllowedItems = 89;

  final int maxItems;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! AttachmentsValue) return const [ViolationCode.typeMismatch];
    final items = value.items;
    final images = [
      for (final item in items)
        if (item is ImageAttachment) item.blob,
    ];
    return [
      // As for tasks: an empty list is no list.
      if (items.isEmpty) ViolationCode.missingRequired,
      if (items.length > maxItems) ViolationCode.tooManyItems,
      if (images.toSet().length != images.length) ViolationCode.duplicateItem,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentsFieldType && other.maxItems == maxItems;

  @override
  int get hashCode => Object.hash(AttachmentsFieldType, maxItems);
}

/// A password: a [SecretValue] of one line. Any printable character is
/// allowed, so a generated or pasted password is kept as it is; control
/// and bidirectional characters are not, since they would make the text
/// copied differ from the text shown.
final class PasswordFieldType extends FieldType {
  PasswordFieldType({this.maxLength = 1024}) {
    _requireRange(maxLength > 0 && maxLength <= maxAllowed);
  }

  static const maxAllowed = 4096;

  final int maxLength;

  @override
  List<ViolationCode> check(FieldValue value) => switch (value) {
    SecretValue(:final text) => [
      if (_length(text) > maxLength) ViolationCode.tooLong,
      if (containsUnsafeCharacters(text)) ViolationCode.invalidCharacters,
    ],
    _ => const [ViolationCode.typeMismatch],
  };

  @override
  bool operator ==(Object other) =>
      other is PasswordFieldType && other.maxLength == maxLength;

  @override
  int get hashCode => Object.hash(PasswordFieldType, maxLength);
}

/// An address on the web, as a [TextValue] written exactly as [WebLink]
/// writes it: the same rules as a link attached to a page, so what is
/// shown is what opens.
final class UrlFieldType extends FieldType {
  const UrlFieldType();

  @override
  List<ViolationCode> check(FieldValue value) => switch (value) {
    TextValue(:final text) when WebLink.parse(text)?.url == text => const [],
    TextValue() => const [ViolationCode.invalidUrl],
    _ => const [ViolationCode.typeMismatch],
  };

  @override
  bool operator ==(Object other) => other is UrlFieldType;

  @override
  int get hashCode => (UrlFieldType).hashCode;
}

/// A recipe's ingredients ([IngredientsValue]): each with a name of one
/// safe line, optional words of quantity, and a link to buy it that is
/// only ever `https`, since it may end up on a public page.
final class IngredientsFieldType extends FieldType {
  IngredientsFieldType({this.maxItems = 89}) {
    _requireRange(maxItems > 0 && maxItems <= maxAllowedItems);
  }

  static const maxAllowedItems = 233;
  static const maxName = 200;
  static const maxQuantity = 80;

  final int maxItems;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! IngredientsValue) return const [ViolationCode.typeMismatch];
    final items = value.items;
    return [
      if (items.isEmpty) ViolationCode.missingRequired,
      if (items.length > maxItems) ViolationCode.tooManyItems,
      if (items.any((item) => item.name.trim().isEmpty))
        ViolationCode.emptyItem,
      if (items.any(
        (item) =>
            _length(item.name) > maxName ||
            _length(item.quantity) > maxQuantity,
      ))
        ViolationCode.tooLong,
      if (items.any(
        (item) =>
            containsUnsafeCharacters(item.name) ||
            containsUnsafeCharacters(item.quantity),
      ))
        ViolationCode.invalidCharacters,
      if (items.any((item) => item.link?.url.startsWith('https://') == false))
        ViolationCode.invalidUrl,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is IngredientsFieldType && other.maxItems == maxItems;

  @override
  int get hashCode => Object.hash(IngredientsFieldType, maxItems);
}

/// The steps of a preparation ([StepsValue]): Markdown, pictures and a
/// short video each. The pictures of all the steps are bounded together,
/// like the attachments of a page, and each blob appears once.
final class StepsFieldType extends FieldType {
  StepsFieldType({this.maxItems = 55}) {
    _requireRange(maxItems > 0 && maxItems <= maxAllowedItems);
  }

  static const maxAllowedItems = 89;
  static const maxText = 10000;
  static const maxPicturesPerStep = 8;
  static const maxPictures = AttachmentsFieldType.maxAllowedItems;

  final int maxItems;

  @override
  List<ViolationCode> check(FieldValue value) {
    if (value is! StepsValue) return const [ViolationCode.typeMismatch];
    final steps = value.steps;
    final pictures = value.pictures.toList();
    final blobs = [...pictures, ...value.videos];
    return [
      if (steps.isEmpty) ViolationCode.missingRequired,
      if (steps.length > maxItems ||
          pictures.length > maxPictures ||
          steps.any((step) => step.pictures.length > maxPicturesPerStep))
        ViolationCode.tooManyItems,
      if (steps.any(
        (step) =>
            step.text.trim().isEmpty &&
            step.pictures.isEmpty &&
            step.video == null,
      ))
        ViolationCode.emptyItem,
      if (steps.any((step) => _length(step.text) > maxText))
        ViolationCode.tooLong,
      if (blobs.toSet().length != blobs.length) ViolationCode.duplicateItem,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is StepsFieldType && other.maxItems == maxItems;

  @override
  int get hashCode => Object.hash(StepsFieldType, maxItems);
}

/// Any number of options from a closed set ([ChoiceSetValue]), such as
/// the ways a dish is cooked. Options are identifiers, like those of a
/// [ChoiceFieldType].
final class ChoiceSetFieldType extends FieldType {
  ChoiceSetFieldType(List<String> options)
    : options = List.unmodifiable(options) {
    if (options.isEmpty ||
        options.length > ChoiceFieldType.maxOptions ||
        options.toSet().length != options.length ||
        !options.every(_optionKey.hasMatch)) {
      throw const InvalidSchemaException(SchemaInvariant.invalidChoiceOptions);
    }
  }

  final List<String> options;

  @override
  List<ViolationCode> check(FieldValue value) => switch (value) {
    ChoiceSetValue(:final options) when options.isEmpty => const [
      ViolationCode.missingRequired,
    ],
    ChoiceSetValue(options: final chosen)
        when !chosen.every(options.contains) =>
      const [ViolationCode.invalidChoice],
    ChoiceSetValue() => const [],
    _ => const [ViolationCode.typeMismatch],
  };

  @override
  bool operator ==(Object other) =>
      other is ChoiceSetFieldType && listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(ChoiceSetFieldType, Object.hashAll(options));
}
