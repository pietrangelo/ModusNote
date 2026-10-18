import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';

/// Links from one note to another, written in Markdown as
/// `[label](note:<entry id>)`. They point at the note's id, never at its
/// title, so renaming a note keeps every link to it; and they never leave
/// the vault: the app opens the note, nothing is fetched.
abstract final class NoteLinks {
  static const scheme = 'note:';

  static final _target = RegExp(r'\]\(note:([A-Za-z0-9_-]{1,128})\)');

  /// Brackets would close the label early, line breaks end a paragraph,
  /// and control or bidirectional characters render as something else.
  static final _unsafeLabel = RegExp(
    r'[\[\]\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// The Markdown for a link to [target] reading [label], made one safe
  /// line; a label with nothing left reads `→`.
  static String markdown(String label, EntryId target) {
    final safe = label
        .replaceAll(_unsafeLabel, ' ')
        .replaceAll(RegExp(' {2,}'), ' ')
        .trim();
    return '[${safe.isEmpty ? '→' : safe}]($scheme${target.value})';
  }

  /// The notes [values] link to, each once, in the order they first
  /// appear. Only text values hold links.
  static List<EntryId> targets(Iterable<FieldValue> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value case TextValue(:final text))
          for (final match in _target.allMatches(text))
            if (seen.add(match.group(1)!)) EntryId(match.group(1)!),
    ];
  }

  static final _ofEntry = Expando<List<EntryId>>();

  /// [targets] of [entry]'s values, found once per entry: entries are
  /// immutable, and every note's links are read on each editor rebuild.
  static List<EntryId> of(DynamicEntry entry) =>
      _ofEntry[entry] ??= List.unmodifiable(targets(entry.attributes.values));
}
