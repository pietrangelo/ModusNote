import 'package:publishing/publishing.dart';

import '../l10n/generated/app_localizations.dart';
import '../notes/recipes/recipe_text.dart';

/// The words a cookbook prints that are not the person's own.
final class CookbookWords {
  const CookbookWords({
    required this.contents,
    required this.ingredientIndex,
    required this.ingredients,
    required this.steps,
    required this.prep,
    required this.cook,
    required this.rest,
    required this.total,
    required this.difficulty,
    required this.scanForVideo,
    required this.watchVideo,
    required this.videoInNote,
    required this.madeWith,
    required this.recipeCount,
    required this.servings,
    required this.minutes,
    required this.amount,
  });

  factory CookbookWords.of(AppLocalizations l10n) {
    final text = RecipeText(l10n);
    return CookbookWords(
      contents: l10n.cookbookContents,
      ingredientIndex: l10n.cookbookIngredientIndex,
      ingredients: l10n.cookingIngredients,
      steps: l10n.cookbookSteps,
      prep: l10n.cookbookPrep,
      cook: l10n.cookbookCook,
      rest: l10n.cookbookRest,
      total: l10n.cookbookTotal,
      difficulty: l10n.cookbookDifficulty,
      scanForVideo: l10n.cookbookScanForVideo,
      watchVideo: l10n.cookbookWatchVideo,
      videoInNote: l10n.cookbookVideoInNote,
      madeWith: l10n.cookbookMadeWith,
      recipeCount: l10n.cookbookRecipeCount,
      servings: l10n.cookingServings,
      minutes: text.minutes,
      amount: text.amount,
    );
  }

  /// Words a test can read.
  static final plain = CookbookWords(
    contents: 'Contents',
    ingredientIndex: 'Index of ingredients',
    ingredients: 'Ingredients',
    steps: 'Method',
    prep: 'Prep',
    cook: 'Cook',
    rest: 'Rest',
    total: 'Total',
    difficulty: 'Difficulty',
    scanForVideo: 'Scan to watch the video',
    watchVideo: 'Watch the video',
    videoInNote: 'Video in the note',
    madeWith: 'Made with Modus Notes',
    recipeCount: (n) => n == 1 ? '1 recipe' : '$n recipes',
    servings: (n) => n == 1 ? '1 serving' : '$n servings',
    minutes: (m) => '$m min',
    amount: (n) => '$n',
  );

  final String contents;
  final String ingredientIndex;
  final String ingredients;
  final String steps;
  final String prep;
  final String cook;
  final String rest;
  final String total;
  final String difficulty;
  final String scanForVideo;
  final String watchVideo;
  final String videoInNote;
  final String madeWith;
  final String Function(int count) recipeCount;
  final String Function(int count) servings;
  final String Function(int minutes) minutes;
  final String Function(num amount) amount;

  /// How much of [item]: «250 g», «2 cucchiai», «q.b.»; empty when the
  /// recipe says nothing.
  String quantity(RecipeIngredient item) {
    final measured = switch ((item.amount, item.unit)) {
      (final amount?, _?) =>
        '${this.amount(amount)} ${amount == 1 ? item.one : item.other}'.trim(),
      (final amount?, null) => this.amount(amount),
      _ => '',
    };
    return [
      measured,
      item.quantity.trim(),
    ].where((part) => part.isNotEmpty).join(', ');
  }

  /// The times of [recipe], each with its label, and their sum.
  List<(String, String)> times(PageRecipe recipe) {
    final parts = [
      (prep, recipe.prep),
      (cook, recipe.cook),
      (rest, recipe.rest),
    ];
    final given = [
      for (final (label, value) in parts)
        if (value != null && value > 0) (label, value),
    ];
    return [
      for (final (label, value) in given) (label, minutes(value)),
      if (given.length > 1)
        (total, minutes(given.fold(0, (sum, part) => sum + part.$2))),
    ];
  }
}
