import 'package:intl/intl.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';

/// How the parts of a recipe read in the person's language: units,
/// amounts with the local decimal sign, ingredients and times.
final class RecipeText {
  RecipeText(this._l10n)
    : _number = NumberFormat.decimalPattern(_l10n.localeName)
        ..turnOffGrouping();

  final AppLocalizations _l10n;
  final NumberFormat _number;

  /// [amount] as the person writes numbers: «1,5» in Italian.
  String amount(num amount) => _number.format(amount);

  /// The name of [unit] for [count] of it.
  String unit(IngredientUnit unit, [num count = 1]) => switch (unit) {
    IngredientUnit.gram => _l10n.unitGram,
    IngredientUnit.kilogram => _l10n.unitKilogram,
    IngredientUnit.millilitre => _l10n.unitMillilitre,
    IngredientUnit.centilitre => _l10n.unitCentilitre,
    IngredientUnit.decilitre => _l10n.unitDecilitre,
    IngredientUnit.litre => _l10n.unitLitre,
    IngredientUnit.teaspoon => _l10n.unitTeaspoon(count),
    IngredientUnit.tablespoon => _l10n.unitTablespoon(count),
    IngredientUnit.cup => _l10n.unitCup(count),
    IngredientUnit.piece => _l10n.unitPiece(count),
    IngredientUnit.slice => _l10n.unitSlice(count),
    IngredientUnit.clove => _l10n.unitClove(count),
    IngredientUnit.pinch => _l10n.unitPinch(count),
    IngredientUnit.ounce => _l10n.unitOunce,
    IngredientUnit.pound => _l10n.unitPound,
  };

  /// How much of [item]: «250 g», «2», «q.b.», «1 cucchiaio, abbondante»;
  /// empty when it says nothing.
  String quantity(Ingredient item) {
    final measured = switch ((item.amount, item.unit)) {
      (final amount?, final unit?) =>
        '${this.amount(amount)} ${this.unit(unit, amount)}',
      (final amount?, null) => this.amount(amount),
      _ => '',
    };
    return [
      measured,
      item.quantity.trim(),
    ].where((part) => part.isNotEmpty).join(', ');
  }

  /// One line for [item]: its quantity, then its name.
  String line(Ingredient item) {
    final how = quantity(item);
    return how.isEmpty ? item.name.trim() : '$how ${item.name.trim()}';
  }

  /// [minutes] as «45 min», «2 h» or «1 h 15 min».
  String minutes(int minutes) => switch ((minutes ~/ 60, minutes % 60)) {
    (0, final m) => _l10n.recipeMinutes(m),
    (final h, 0) => _l10n.recipeWholeHours(h),
    (final h, final m) => _l10n.recipeHours(h, m),
  };
}
