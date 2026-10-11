import 'package:meta/meta.dart';

import 'identifiers.dart';
import 'schema_exception.dart';

/// A value held by a [DynamicEntry] attribute. Each variant is valid on its
/// own; whether it fits a particular field is the [FieldType]'s call.
@immutable
sealed class FieldValue {
  const FieldValue();
}

final class TextValue extends FieldValue {
  const TextValue(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is TextValue && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextValue(${text.length} chars)';
}

final class NumberValue extends FieldValue {
  NumberValue(this.number) {
    if (!number.isFinite) {
      throw const InvalidValueException('numbers must be finite');
    }
  }

  final num number;

  @override
  bool operator ==(Object other) =>
      other is NumberValue && other.number == number;

  @override
  int get hashCode => number.hashCode;
}

/// A calendar date with no time zone: a dream dated 3 March stays on 3 March
/// on every device, wherever it syncs.
final class DateValue extends FieldValue {
  DateValue(this.year, this.month, this.day) {
    final probe = DateTime.utc(year, month, day);
    if (probe.year != year || probe.month != month || probe.day != day) {
      throw InvalidValueException('$year-$month-$day is not a date');
    }
  }

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is DateValue &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}

final class DateTimeValue extends FieldValue {
  DateTimeValue(this.instant) {
    if (!instant.isUtc) {
      throw const InvalidValueException('date-times must be UTC');
    }
  }

  final DateTime instant;

  @override
  bool operator ==(Object other) =>
      other is DateTimeValue && other.instant == instant;

  @override
  int get hashCode => instant.hashCode;
}

final class BooleanValue extends FieldValue {
  const BooleanValue(this.value);

  final bool value;

  @override
  bool operator ==(Object other) =>
      other is BooleanValue && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class RatingValue extends FieldValue {
  const RatingValue(this.rating);

  final int rating;

  @override
  bool operator ==(Object other) =>
      other is RatingValue && other.rating == rating;

  @override
  int get hashCode => rating.hashCode;
}

final class ChoiceValue extends FieldValue {
  const ChoiceValue(this.option);

  final String option;

  @override
  bool operator ==(Object other) =>
      other is ChoiceValue && other.option == option;

  @override
  int get hashCode => option.hashCode;
}

final class TagListValue extends FieldValue {
  TagListValue(Set<String> tags) : tags = Set.unmodifiable(tags);

  final Set<String> tags;

  @override
  bool operator ==(Object other) =>
      other is TagListValue &&
      other.tags.length == tags.length &&
      other.tags.containsAll(tags);

  @override
  int get hashCode => Object.hashAllUnordered(tags);
}

final class AudioBlobValue extends FieldValue {
  const AudioBlobValue(this.blob);

  final BlobId blob;

  @override
  bool operator ==(Object other) =>
      other is AudioBlobValue && other.blob == blob;

  @override
  int get hashCode => blob.hashCode;
}
