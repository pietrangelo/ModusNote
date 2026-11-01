import 'package:intl/intl.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/schema_text.dart';

/// [value] of [field] as a published page or a printed book shows it, in
/// [locale]; empty for a value they show in a block of its own.
String describeField(
  SchemaText texts,
  String locale,
  FieldDefinition field,
  FieldValue value,
) => switch (value) {
  NumberValue(:final number) => NumberFormat.decimalPattern(
    locale,
  ).format(number),
  DateValue(:final year, :final month, :final day) => DateFormat.yMMMMd(
    locale,
  ).format(DateTime(year, month, day)),
  DateTimeValue(:final instant) => DateFormat.yMMMMd(
    locale,
  ).add_Hm().format(instant.toLocal()),
  BooleanValue(value: final yes) => yes ? '✓' : '✗',
  RatingValue(:final rating) => switch (field.type) {
    RatingFieldType(:final max) => '${'★' * rating}${'☆' * (max - rating)}',
    _ => '$rating',
  },
  ChoiceValue(:final option) => texts.option(field, option),
  ChoiceSetValue(:final options) => [
    for (final option in switch (field.type) {
      ChoiceSetFieldType(options: final all) => all.where(options.contains),
      _ => options,
    })
      texts.option(field, option),
  ].join(', '),
  _ => '',
};
