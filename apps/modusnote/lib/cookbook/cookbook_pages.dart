import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/recipes/recipe_text.dart';
import '../notes/schema_text.dart';
import '../publishing/field_description.dart';
import 'cookbook.dart';

/// Turns a recipe note into the page the book prints: every field the
/// note type lets one publish, pictures included, through the same
/// [PublicationPolicy] and [PageComposer] as serv.pub. Links to other
/// notes keep only their words unless that note is published, and no id
/// of the vault is left in the text.
final class CookbookPages {
  CookbookPages({
    required this.schemas,
    required this.texts,
    required this.recipes,
    required this.locale,
    this.site,
  });

  final List<SchemaDefinition> schemas;
  final SchemaText texts;
  final RecipeText recipes;

  /// The language tag numbers and dates are written in.
  final String locale;

  /// The device's site, for the addresses of the published recipes.
  final SiteBook? site;

  var _next = 0;

  /// [entry]'s page; null for a note that is not a recipe or cannot be
  /// shown.
  CookbookRecipe? compose(DynamicEntry entry) {
    final schema = _schemaOf(entry);
    if (schema == null || schema.id.name != Recipe.schema) return null;
    try {
      final content = PublicationPolicy.compose(
        entry: entry,
        schema: schema,
        fields: {
          for (final field in PublicationPolicy.publishableFields(schema))
            field.key,
        },
        published: site?.slugs ?? const {},
      );
      final media = <BlobId, MediaId>{
        for (final blob in [...content.images, ...content.videos])
          blob: _mediaId(),
      };
      final document = PageComposer.compose(
        content: content,
        schema: schema,
        media: media,
        labelOf: (field) => texts.label(field.label),
        describe: (field, value) => describeField(texts, locale, field, value),
        listed: true,
        ingredientLine: recipes.line,
        recipeWords: RecipeWords(unit: recipes.unit, option: texts.option),
        layout: PublicationLayout.recipe,
      );
      final page = switch ((site, site?.pages[entry.id])) {
        (final site?, final published?) => site.pageUrl(published.slug),
        _ => null,
      };
      return CookbookRecipe(
        entry: entry.id,
        document: document,
        media: {for (final MapEntry(:key, :value) in media.entries) value: key},
        page: page,
      );
    } on PublishingException {
      return null;
    }
  }

  /// An id of the book's own, never one the site uses.
  MediaId _mediaId() => MediaId('book${(_next++).toString().padLeft(18, '0')}');

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }
}
