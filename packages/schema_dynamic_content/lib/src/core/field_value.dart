import 'package:meta/meta.dart';

import 'attachment.dart';
import 'dynamic_entry.dart';
import 'identifiers.dart';
import 'list_equality.dart';
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

/// A password, or anything else that must not show by default: held
/// like text, but never searched, shown on a card or printed.
final class SecretValue extends FieldValue {
  const SecretValue(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is SecretValue && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SecretValue(hidden)';
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

/// One task of a [ChecklistValue].
@immutable
final class ChecklistItem {
  const ChecklistItem(this.text, {this.done = false});

  final String text;
  final bool done;

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem && other.text == text && other.done == done;

  @override
  int get hashCode => Object.hash(text, done);

  @override
  String toString() => 'ChecklistItem(${text.length} chars, done: $done)';
}

/// A list of tasks, in the order the user wrote them.
final class ChecklistValue extends FieldValue {
  ChecklistValue(List<ChecklistItem> items) : items = List.unmodifiable(items);

  final List<ChecklistItem> items;

  int get total => items.length;
  int get done => items.where((item) => item.done).length;
  bool get allDone => items.isNotEmpty && done == total;

  @override
  bool operator ==(Object other) {
    if (other is! ChecklistValue || other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'ChecklistValue($done/$total)';
}

/// The pictures and links of a page, in the order the person put them.
final class AttachmentsValue extends FieldValue {
  AttachmentsValue(List<Attachment> items) : items = List.unmodifiable(items);

  final List<Attachment> items;

  /// The pictures every attachments field and every step of [entry]
  /// holds, in order and each once: the blobs the note needs beside it.
  static List<BlobId> imagesOf(DynamicEntry entry) => {
    for (final value in entry.attributes.values)
      ...switch (value) {
        AttachmentsValue(:final items) => [
          for (final item in items)
            if (item is ImageAttachment) item.blob,
        ],
        StepsValue(:final pictures) => pictures,
        _ => const <BlobId>[],
      },
  }.toList();

  @override
  bool operator ==(Object other) =>
      other is AttachmentsValue && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'AttachmentsValue(${items.length} items)';
}

/// What an amount of an [Ingredient] is counted in. Identifiers the app
/// names in the person's language; a number alone counts pieces.
enum IngredientUnit {
  gram,
  kilogram,
  millilitre,
  centilitre,
  decilitre,
  litre,
  teaspoon,
  tablespoon,
  cup,
  piece,
  slice,
  clove,
  pinch,
  ounce,
  pound,
}

/// One line of a recipe's ingredients: what, how much, and where to buy it.
///
/// [amount] (with an optional [unit]) is what servings scale; [quantity]
/// holds words a number cannot say, such as «q.b.» or «a piacere». The
/// name and words are checked by [IngredientsFieldType], like the text of
/// a task; the amount and unit always make sense on their own.
@immutable
final class Ingredient {
  Ingredient(
    this.name, {
    this.amount,
    this.unit,
    this.quantity = '',
    this.link,
  }) {
    final n = amount;
    if (n != null && (!n.isFinite || n <= 0 || n > maxAmount)) {
      throw const InvalidValueException('an amount is positive and finite');
    }
    if (unit != null && n == null) {
      throw const InvalidValueException('a unit needs an amount');
    }
  }

  static const maxAmount = 1000000;

  final String name;
  final num? amount;
  final IngredientUnit? unit;
  final String quantity;

  /// Where to buy it; only ever opened by the person, never fetched.
  final WebLink? link;

  /// This ingredient with [amount] in place of its own.
  Ingredient withAmount(num? amount) => Ingredient(
    name,
    amount: amount,
    unit: amount == null ? null : unit,
    quantity: quantity,
    link: link,
  );

  @override
  bool operator ==(Object other) =>
      other is Ingredient &&
      other.name == name &&
      other.amount == amount &&
      other.unit == unit &&
      other.quantity == quantity &&
      other.link == link;

  @override
  int get hashCode => Object.hash(name, amount, unit, quantity, link);

  @override
  String toString() => 'Ingredient(${name.length} chars, $amount $unit)';
}

/// A recipe's ingredients, in the order the person wrote them.
final class IngredientsValue extends FieldValue {
  IngredientsValue(List<Ingredient> items) : items = List.unmodifiable(items);

  final List<Ingredient> items;

  @override
  bool operator ==(Object other) =>
      other is IngredientsValue && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'IngredientsValue(${items.length} items)';
}

/// One step of a preparation: what to do, in Markdown, and pictures of it.
@immutable
final class PreparationStep {
  PreparationStep(this.text, {List<ImageAttachment> pictures = const []})
    : pictures = List.unmodifiable(pictures);

  final String text;
  final List<ImageAttachment> pictures;

  @override
  bool operator ==(Object other) =>
      other is PreparationStep &&
      other.text == text &&
      listEquals(other.pictures, pictures);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(pictures));

  @override
  String toString() =>
      'PreparationStep(${text.length} chars, ${pictures.length} pictures)';
}

/// The steps of a preparation, in order.
final class StepsValue extends FieldValue {
  StepsValue(List<PreparationStep> steps) : steps = List.unmodifiable(steps);

  final List<PreparationStep> steps;

  /// Every picture of every step, in order.
  Iterable<BlobId> get pictures => [
    for (final step in steps)
      for (final picture in step.pictures) picture.blob,
  ];

  @override
  bool operator ==(Object other) =>
      other is StepsValue && listEquals(other.steps, steps);

  @override
  int get hashCode => Object.hashAll(steps);

  @override
  String toString() => 'StepsValue(${steps.length} steps)';
}

/// Some options of a [ChoiceSetFieldType], in no order.
final class ChoiceSetValue extends FieldValue {
  ChoiceSetValue(Set<String> options) : options = Set.unmodifiable(options);

  final Set<String> options;

  @override
  bool operator ==(Object other) =>
      other is ChoiceSetValue &&
      other.options.length == options.length &&
      other.options.containsAll(options);

  @override
  int get hashCode => Object.hashAllUnordered(options);
}
