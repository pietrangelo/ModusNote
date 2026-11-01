import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'media.dart';

/// A picture of a recipe, by its uploaded copy.
@immutable
final class RecipePicture {
  const RecipePicture(this.media, [this.caption = '']);

  final MediaId media;
  final String caption;

  Map<String, Object> toJson() => {'media': media.value, 'caption': caption};
}

/// One ingredient as serv.pub takes it: the amount stays a number, so the
/// site can scale it for other servings, with the unit's name for one and
/// for any other amount in the person's language.
@immutable
final class RecipeIngredient {
  const RecipeIngredient(
    this.name, {
    this.amount,
    this.unit,
    this.one = '',
    this.other = '',
    this.quantity = '',
    this.link,
  });

  final String name;
  final num? amount;
  final IngredientUnit? unit;
  final String one;
  final String other;
  final String quantity;

  /// Where to buy it: `https` only.
  final String? link;

  Map<String, Object> toJson() => {
    'name': name,
    'amount': ?amount,
    // The wire's names are the enum's, in snake_case: one word each.
    'unit': ?unit?.name,
    'one': one,
    'other': other,
    'quantity': quantity,
    'link': ?link,
  };
}

/// One step: Markdown, and its pictures.
@immutable
final class RecipeStep {
  RecipeStep(this.text, [List<RecipePicture> pictures = const []])
    : pictures = List.unmodifiable(pictures);

  final String text;
  final List<RecipePicture> pictures;

  Map<String, Object> toJson() => {
    'text': text,
    'pictures': [for (final p in pictures) p.toJson()],
  };
}

/// What a page of the `recipe` layout says about the dish, structured so
/// serv.pub can scale it, list it in the site's cookbook and describe it
/// to search engines. Only what the person chose to publish is here.
@immutable
final class PageRecipe {
  PageRecipe({
    this.category = '',
    this.description = '',
    List<RecipePicture> cover = const [],
    this.servings,
    this.prep,
    this.cook,
    this.rest,
    List<String> methods = const [],
    this.difficulty,
    List<RecipeIngredient> ingredients = const [],
    List<RecipeStep> steps = const [],
    List<String> tags = const [],
  }) : cover = List.unmodifiable(cover),
       methods = List.unmodifiable(methods),
       ingredients = List.unmodifiable(ingredients),
       steps = List.unmodifiable(steps),
       tags = List.unmodifiable(tags);

  // serv.pub's limits, the same as the note type's.
  static const maxCategory = 89;
  static const maxDescription = 2584;
  static const maxCover = 13;
  static const maxServings = 100;
  static const maxMinutes = 10080;
  static const maxMethods = 13;
  static const maxIngredients = 233;
  static const maxName = 200;
  static const maxUnit = 34;
  static const maxQuantity = 80;
  static const maxSteps = 89;
  static const maxStep = 10000;
  static const maxStepPictures = 8;
  static const maxPictures = 89;
  static const maxTags = 89;
  static const maxTag = 89;

  /// The note's category, the cookbook's section; empty for none.
  final String category;

  /// Markdown; the site shows its first paragraph as plain text.
  final String description;
  final List<RecipePicture> cover;
  final int? servings;

  /// Minutes.
  final int? prep;
  final int? cook;
  final int? rest;

  /// Ways of cooking, in the person's language.
  final List<String> methods;

  /// 1 easy, 2 medium, 3 hard.
  final int? difficulty;
  final List<RecipeIngredient> ingredients;
  final List<RecipeStep> steps;
  final List<String> tags;

  /// Every file the recipe shows.
  Iterable<MediaId> get media => [
    for (final p in cover) p.media,
    for (final step in steps) ...[for (final p in step.pictures) p.media],
  ];

  Map<String, Object> toJson() => {
    'category': category,
    'description': description,
    'cover': [for (final p in cover) p.toJson()],
    'servings': ?servings,
    'prep': ?prep,
    'cook': ?cook,
    'rest': ?rest,
    'methods': methods,
    'difficulty': ?difficulty,
    'ingredients': [for (final i in ingredients) i.toJson()],
    'steps': [for (final s in steps) s.toJson()],
    'tags': tags,
  };
}
