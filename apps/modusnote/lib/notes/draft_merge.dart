import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// What the open note becomes when another device saved it meanwhile: a
/// three-way merge, field by field, of the version the editor opened
/// ([base]), what is being typed ([mine]) and the version now stored
/// ([theirs]).
///
/// A field only one side changed takes that side; a field both changed
/// the same way is that value; a field both changed differently keeps
/// [mine] and is named in [clashes], so the other value can be kept
/// elsewhere before the next save replaces it.
final class DraftMerge {
  DraftMerge._(this.values, this.clashes);

  factory DraftMerge.of({
    required Map<FieldKey, FieldValue> base,
    required Map<FieldKey, FieldValue> mine,
    required Map<FieldKey, FieldValue> theirs,
  }) {
    final values = <FieldKey, FieldValue>{};
    final clashes = <FieldKey>{};
    for (final key in {...base.keys, ...mine.keys, ...theirs.keys}) {
      final was = base[key];
      final ours = mine[key];
      final other = theirs[key];
      final FieldValue? value;
      if (ours == was) {
        value = other;
      } else if (other == was || other == ours) {
        value = ours;
      } else {
        value = ours;
        clashes.add(key);
      }
      if (value != null) values[key] = value;
    }
    return DraftMerge._(Map.unmodifiable(values), Set.unmodifiable(clashes));
  }

  final Map<FieldKey, FieldValue> values;
  final Set<FieldKey> clashes;
}
