import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../note_store.dart';
import '../note_title.dart';

/// One category of a document's index and the pages filed directly in it.
final class IndexSection {
  const IndexSection(this.category, this.level, this.pages);

  final NoteCategory category;

  /// 0 for the document's own category, 1 for a category inside it, ...
  final int level;

  /// By title, numbers in titles compared as numbers ("2" before "10").
  final List<DynamicEntry> pages;
}

/// The index of a manual: the document pages filed in a page's category
/// and in the categories inside it, outside the trash, a section per
/// category in the tree's order. Pages are told by the type's name, so a
/// later version of the type is still a page.
abstract final class PageIndex {
  static const document = 'document';

  /// Null when the page is in no category: there is no manual to index.
  static List<IndexSection>? of({
    required CategoryId? category,
    required NoteStore store,
    required SchemaDefinition? Function(DynamicEntry) schemaOf,
  }) {
    if (category == null) return null;
    final tree = store.categories;
    final inside = tree.subtree(category);
    if (inside.isEmpty) return null;
    final byCategory = <CategoryId, List<DynamicEntry>>{};
    for (final entry in store.entries) {
      if (entry.schemaId.name != document) continue;
      final filed = store.categoryOf(entry.id);
      if (filed != null && inside.contains(filed)) {
        byCategory.putIfAbsent(filed, () => []).add(entry);
      }
    }
    final titles = <EntryId, String>{};
    String title(DynamicEntry entry) =>
        titles[entry.id] ??= NoteTitle.of(entry, schemaOf(entry)).toLowerCase();
    int byTitle(DynamicEntry a, DynamicEntry b) {
      final named = naturalCompare(title(a), title(b));
      return named != 0 ? named : a.id.value.compareTo(b.id.value);
    }

    final top = tree.depthOf(category);
    return [
      for (final section in tree.ordered)
        if (inside.contains(section.id) &&
            (section.id == category || byCategory.containsKey(section.id)))
          IndexSection(
            section,
            tree.depthOf(section.id) - top,
            (byCategory[section.id] ?? [])..sort(byTitle),
          ),
    ];
  }

  static final _digits = RegExp(r'\d+');
  static final _leadingZeros = RegExp('^0+(?=.)');

  /// Text order with runs of digits compared by value, so "2. Uso" comes
  /// before "10. Note". A run too long to be a number is compared by its
  /// length, then as text, in one pass and without big numbers.
  static int naturalCompare(String a, String b) {
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      final x = _digits.matchAsPrefix(a, i);
      final y = _digits.matchAsPrefix(b, j);
      if (x != null && y != null) {
        final p = x[0]!.replaceFirst(_leadingZeros, '');
        final q = y[0]!.replaceFirst(_leadingZeros, '');
        final byValue = p.length != q.length
            ? p.length.compareTo(q.length)
            : p.compareTo(q);
        if (byValue != 0) return byValue;
        i = x.end;
        j = y.end;
        continue;
      }
      final c = a.codeUnitAt(i).compareTo(b.codeUnitAt(j));
      if (c != 0) return c;
      i++;
      j++;
    }
    return (a.length - i).compareTo(b.length - j);
  }
}
