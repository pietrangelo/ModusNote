import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// A to-do list made from a recipe: one task per ingredient still to buy,
/// written as the person reads it («500 g Farina»), in the recipe's order.
/// An ordinary to-do note from then on, sealed and synced like any other.
abstract final class ShoppingList {
  static final _title = FieldKey('title');
  static final _items = FieldKey('items');

  /// The note for [lines] titled [title]; null when there is nothing to
  /// buy. Text that would not fit a task is cut, never refused.
  static DynamicEntry? of({
    required EntryId id,
    required String title,
    required List<String> lines,
    required DateTime at,
  }) {
    final items = [
      for (final line in lines.take(ChecklistFieldType().maxItems))
        if (_cut(line, ChecklistFieldType.maxItemLength) case final text
            when text.isNotEmpty)
          ChecklistItem(text),
    ];
    if (items.isEmpty) return null;
    return switch (DynamicEntry.create(
      schema: SeedSchemas.taskV2,
      id: id,
      attributes: {
        _title: TextValue(_cut(title, 200)),
        _items: ChecklistValue(items),
      },
      at: at,
    )) {
      Valid(:final value) => value,
      // Every part was made to fit: a refusal is a bug, not input.
      Invalid(:final violations) => throw StateError('$violations'),
    };
  }

  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// [text] as one safe line of at most [max] characters.
  static String _cut(String text, int max) {
    final line = text
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(' {2,}'), ' ')
        .trim();
    final runes = line.runes.toList();
    return runes.length <= max
        ? line
        : String.fromCharCodes(runes.take(max)).trim();
  }
}
