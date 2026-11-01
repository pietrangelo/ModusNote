import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';

/// Notes of the `recipe` type, told by the type's name like [Journal]
/// pages, and what can be worked out from them: the total time, and the
/// ingredients for another number of servings.
abstract final class Recipe {
  static const schema = 'recipe';
  static final servings = FieldKey('servings');
  static final ingredients = FieldKey('ingredients');
  static final steps = FieldKey('steps');
  static final prepTime = FieldKey('prep_time');
  static final cookTime = FieldKey('cook_time');
  static final restTime = FieldKey('rest_time');

  /// The ways a dish is cooked; identifiers the app names.
  static const methods = [
    'oven',
    'stovetop',
    'air_fryer',
    'microwave',
    'steam',
    'grill',
    'pressure_cooker',
    'slow_cooker',
    'barbecue',
    'no_cook',
  ];

  static const ovenModes = ['static', 'fan', 'grill'];

  static bool isRecipe(DynamicEntry entry) => entry.schemaId.name == schema;

  static int? _whole(DynamicEntry entry, FieldKey key) =>
      switch (entry.attributes[key]) {
        NumberValue(:final number) => number.toInt(),
        _ => null,
      };

  /// How many the recipe serves, if it says.
  static int? servingsOf(DynamicEntry entry) => _whole(entry, servings);

  static List<Ingredient> ingredientsOf(DynamicEntry entry) =>
      switch (entry.attributes[ingredients]) {
        IngredientsValue(:final items) => items,
        _ => const [],
      };

  static List<PreparationStep> stepsOf(DynamicEntry entry) =>
      switch (entry.attributes[steps]) {
        StepsValue(steps: final all) => all,
        _ => const [],
      };

  /// Preparation, cooking and rest together, in minutes; null when the
  /// recipe states none of them.
  static int? totalMinutes(DynamicEntry entry) {
    final times = [
      for (final key in [prepTime, cookTime, restTime]) ?_whole(entry, key),
    ];
    return times.isEmpty ? null : times.fold<int>(0, (a, b) => a + b);
  }

  /// [items] written for [from] servings, made for [to]: each amount
  /// multiplied and rounded to what a cook can measure; words and links
  /// unchanged. The same servings change nothing.
  static List<Ingredient> scale(
    List<Ingredient> items, {
    required int from,
    required int to,
  }) {
    if (from < 1) throw ArgumentError.value(from, 'from');
    if (to < 1) throw ArgumentError.value(to, 'to');
    if (from == to) return items;
    return [
      for (final item in items)
        switch (item.amount) {
          null => item,
          final amount => item.withAmount(
            _measurable(amount * to / from, item.unit),
          ),
        },
    ];
  }

  /// Things counted (eggs, cloves, slices, pinches) by halves; spoons and
  /// cups by quarters; weights and volumes by tenths under 10, by one up
  /// to 100 and by five above. Never less than the smallest step.
  static num _measurable(num amount, IngredientUnit? unit) {
    final step = switch (unit) {
      null ||
      IngredientUnit.piece ||
      IngredientUnit.slice ||
      IngredientUnit.clove ||
      IngredientUnit.pinch => 0.5,
      IngredientUnit.teaspoon ||
      IngredientUnit.tablespoon ||
      IngredientUnit.cup => 0.25,
      _ when amount < 10 => 0.1,
      _ when amount < 100 => 1,
      _ => 5,
    };
    final steps = (amount / step).round();
    final rounded = (steps < 1 ? 1 : steps) * step;
    // 2.3000000000000003 is 2.3; 63.0 is 63.
    final tidy = num.parse(rounded.toStringAsFixed(2));
    return tidy == tidy.truncate() ? tidy.toInt() : tidy;
  }
}
