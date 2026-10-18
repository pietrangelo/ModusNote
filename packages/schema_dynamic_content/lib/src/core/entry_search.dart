import 'package:meta/meta.dart';

import 'dynamic_entry.dart';
import 'field_value.dart';

/// Full-text match over an entry's words: text, tags, choice options,
/// tasks and the captions and titles of attachments.
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
        _ => const <String>[],
      },
  ].map(fold).join('\n');

  /// Lower case without the accents of Latin scripts, so "citta" finds
  /// "Città" and the other way round.
  static String fold(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_unaccented[char] ?? char);
    }
    return buffer.toString();
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
      for (final char in accented.split('')) char: plain,
  };
}
