import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// One recipe as the book prints it: the same page serv.pub would show
/// ([PageDocument] with the recipe layout, private links and ids already
/// gone), the files it shows, and its published address, if any.
final class CookbookRecipe {
  CookbookRecipe({
    required this.entry,
    required this.document,
    required Map<MediaId, BlobId> media,
    this.page,
  }) : media = Map.unmodifiable(media) {
    if (document.recipe == null) {
      throw ArgumentError.value(document, 'document', 'not a recipe page');
    }
  }

  final EntryId entry;
  final PageDocument document;

  /// Where each file the page shows comes from.
  final Map<MediaId, BlobId> media;

  /// The recipe's page on serv.pub: what a video's code points to.
  final Uri? page;

  String get title => document.title;
  PageRecipe get recipe => document.recipe!;
}

/// The recipes filed directly in one category of the book.
final class CookbookChapter {
  CookbookChapter({
    required List<String> path,
    required this.colours,
    required List<CookbookRecipe> recipes,
  }) : path = List.unmodifiable(path),
       recipes = List.unmodifiable(recipes);

  /// The names from just under the book's own category down to this
  /// one; empty for the recipes filed in the book's category itself.
  final List<String> path;
  final CategoryColours colours;
  final List<CookbookRecipe> recipes;

  /// The chapter's own name; empty for the book's category itself.
  String get name => path.isEmpty ? '' : path.last;

  /// 0 for the book's category, 1 just under it, and so on.
  int get depth => path.length;
}

/// One line of the index of ingredients: a name and the recipes that use
/// it, in the order of the book.
final class CookbookIngredient {
  CookbookIngredient(this.name, List<CookbookRecipe> recipes)
    : recipes = List.unmodifiable(recipes);

  final String name;
  final List<CookbookRecipe> recipes;
}

/// A cookbook: the recipes of a category and of every category inside
/// it, a chapter per category in the order of the library, the recipes of
/// a chapter by title, and the ingredients in alphabetical order. Built on
/// the device from the vault, and so private until the person shares the
/// file.
final class Cookbook {
  Cookbook._(this.title, this.palette, this.chapters, this.ingredients);

  /// The most recipes in one book.
  static const maxRecipes = 2584;

  /// Collects the book of [root]. [compose] gives a note's page, null for
  /// one that cannot be shown; [pageOf] its address on serv.pub.
  factory Cookbook.collect({
    required CategoryTree tree,
    required CategoryId root,
    required Iterable<DynamicEntry> entries,
    required CategoryId? Function(EntryId id) categoryOf,
    required CookbookRecipe? Function(DynamicEntry entry) compose,
    required SitePalette palette,
  }) {
    final top = tree[root];
    if (top == null) {
      throw ArgumentError.value(root, 'root', 'not in the tree');
    }
    final inside = tree.subtree(root);
    final filed = <CategoryId, List<DynamicEntry>>{};
    var count = 0;
    for (final entry in entries) {
      if (entry.schemaId.name != Recipe.schema) continue;
      final at = tree.resolve(categoryOf(entry.id));
      if (at == null || !inside.contains(at)) continue;
      if (count++ == maxRecipes) throw const CookbookTooLargeException();
      filed.putIfAbsent(at, () => []).add(entry);
    }
    final order = [
      top,
      for (final category in tree.ordered)
        if (category.id != root && inside.contains(category.id)) category,
    ];
    final chapters = <CookbookChapter>[];
    for (final category in order) {
      final notes = filed[category.id];
      if (notes == null) continue;
      final recipes = [for (final entry in notes) ?compose(entry)]
        ..sort(_byTitle);
      if (recipes.isEmpty) continue;
      final path = tree.pathTo(category.id);
      final below = path.indexWhere((c) => c.id == root);
      chapters.add(
        CookbookChapter(
          path: [for (final c in path.skip(below + 1)) c.name.value],
          colours: CategoryColours.of(palette, chapters.length),
          recipes: recipes,
        ),
      );
    }
    return Cookbook._(
      top.name.value,
      palette,
      List.unmodifiable(chapters),
      List.unmodifiable(_index(chapters)),
    );
  }

  /// The name of the book's category.
  final String title;
  final SitePalette palette;
  final List<CookbookChapter> chapters;
  final List<CookbookIngredient> ingredients;

  /// Every recipe, in the order of the book.
  Iterable<CookbookRecipe> get recipes =>
      chapters.expand((chapter) => chapter.recipes);

  bool get isEmpty => chapters.isEmpty;

  /// The chapter [recipe] is in.
  CookbookChapter chapterOf(CookbookRecipe recipe) =>
      chapters.firstWhere((c) => c.recipes.contains(recipe));

  static int _byTitle(CookbookRecipe a, CookbookRecipe b) {
    final folded = EntrySearch.fold(a.title)
        .compareTo(EntrySearch.fold(b.title));
    if (folded != 0) return folded;
    final exact = a.title.compareTo(b.title);
    return exact != 0 ? exact : a.entry.value.compareTo(b.entry.value);
  }

  /// Ingredients by their name without case, accents or repeated spaces:
  /// «Farina 00» and «farina  00» are one line, named as first written.
  static List<CookbookIngredient> _index(List<CookbookChapter> chapters) {
    final names = <String, String>{};
    final uses = <String, List<CookbookRecipe>>{};
    for (final chapter in chapters) {
      for (final recipe in chapter.recipes) {
        for (final item in recipe.recipe.ingredients) {
          final name = item.name.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (name.isEmpty) continue;
          final key = EntrySearch.fold(name);
          names.putIfAbsent(key, () => name);
          final list = uses.putIfAbsent(key, () => []);
          if (list.isEmpty || !identical(list.last, recipe)) list.add(recipe);
        }
      }
    }
    final keys = names.keys.toList()..sort();
    return [
      for (final key in keys) CookbookIngredient(names[key]!, uses[key]!),
    ];
  }
}

/// More recipes than [Cookbook.maxRecipes] in the category.
final class CookbookTooLargeException implements Exception {
  const CookbookTooLargeException();
}
