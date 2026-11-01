import 'package:meta/meta.dart';

import 'dynamic_entry.dart';
import 'field_value.dart';

/// Full-text match over an entry's words: text, tags, choice options,
/// tasks, ingredients, preparation steps and the captions and titles of
/// attachments.
///
/// Runs on decrypted entries in memory only. No index is built or stored,
/// so searching never leaves plaintext on disk beside the encrypted records.
@immutable
final class EntrySearch {
  EntrySearch(String query)
    : _terms = fold(query)
          .split(_whitespace)
          .where((term) => term.isNotEmpty)
          .toList();

  static final _whitespace = RegExp(r'\s+');

  final List<String> _terms;

  /// Entries are immutable, so each is folded once, not on every keystroke.
  static final _haystacks = Expando<String>();

  bool matches(DynamicEntry entry) {
    if (_terms.isEmpty) return true;
    final haystack = _haystacks[entry] ??= _haystackOf(entry);
    return _terms.every(haystack.contains);
  }

  static String _haystackOf(DynamicEntry entry) => [
    for (final value in entry.attributes.values)
      ...switch (value) {
        TextValue(:final text) => [text],
        TagListValue(:final tags) => tags,
        ChoiceValue(:final option) => [option],
        ChecklistValue(:final items) => [for (final i in items) i.text],
        // Captions and titles, not addresses: what the person wrote.
        AttachmentsValue(:final items) => [for (final i in items) i.text],
        IngredientsValue(:final items) => [
          for (final i in items) ...[i.name, i.quantity],
        ],
        StepsValue(:final steps) => [
          for (final step in steps) ...[
            step.text,
            for (final picture in step.pictures) picture.caption,
          ],
        ],
        ChoiceSetValue(:final options) => options,
        _ => const <String>[],
      },
  ].map(fold).join('\n');

  /// Lower case without the accents of Latin scripts, so "citta" finds
  /// "Città" and the other way round.
  ///
  /// Every accented letter folded here is one UTF-16 unit from U+00C0 up,
  /// so text below it (most of what people type) is only lowered, and
  /// the rest is folded unit by unit, in one pass either way.
  static String fold(String text) {
    final lower = text.toLowerCase();
    var start = 0;
    while (start < lower.length && lower.codeUnitAt(start) < 0xC0) {
      start++;
    }
    if (start == lower.length) return lower;
    final units = List.of(lower.codeUnits);
    for (var i = start; i < units.length; i++) {
      if (_unaccented[units[i]] case final plain?) units[i] = plain;
    }
    return String.fromCharCodes(units);
  }

  static final _unaccented = {
    for (final (plain, accented) in const [
      ('a', 'àáâãäåā'),
      ('c', 'çćč'),
      ('e', 'èéêëēė'),
      ('i', 'ìíîïī'),
      ('n', 'ñń'),
      ('o', 'òóôõöøō'),
      ('s', 'śšß'),
      ('u', 'ùúûüū'),
      ('y', 'ýÿ'),
      ('z', 'źżž'),
    ])
      for (final char in accented.codeUnits) char: plain.codeUnitAt(0),
  };
}
