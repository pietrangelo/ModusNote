import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'markdown/markdown_document.dart';

/// What a note is called in lists: its primary text, or for an untitled
/// to-do the tasks still open. Empty when there is nothing to show.
abstract final class NoteTitle {
  static String of(DynamicEntry entry, SchemaDefinition? schema) {
    final primary = schema?.primaryTextField;
    final named = switch (primary == null ? null : entry.valueOf(primary.key)) {
      // A Markdown title shows its words, not its markup.
      TextValue(:final text) when primary!.type is MarkdownFieldType =>
        MarkdownDocument.parse(text).plainText,
      TextValue(:final text) => text.trim(),
      _ => '',
    };
    if (named.isNotEmpty) return named;
    final tasks = entry.attributes.values.whereType<ChecklistValue>();
    if (tasks.isEmpty) return named;
    // An untitled list is named by the tasks still to do.
    return [
      for (final item in tasks.first.items)
        if (!item.done) item.text,
    ].join(', ');
  }
}
