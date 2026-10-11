import 'field_value.dart';
import 'identifiers.dart';
import 'schema_definition.dart';

/// Turning a note being written into another type keeps what still fits.
abstract final class SchemaSwitch {
  /// The [values] of a [from] entry that [to] accepts as they are: those
  /// under a key [to] also has, plus the primary text moved to [to]'s
  /// primary text field. A value [to]'s field would reject is dropped,
  /// never shortened, so nothing the user wrote changes behind their back.
  static Map<FieldKey, FieldValue> carryOver({
    required SchemaDefinition from,
    required Map<FieldKey, FieldValue> values,
    required SchemaDefinition to,
  }) {
    bool fits(FieldKey key, FieldValue value) =>
        to.fieldFor(key)?.type.check(value).isEmpty ?? false;

    final carried = <FieldKey, FieldValue>{
      for (final MapEntry(:key, :value) in values.entries)
        if (fits(key, value)) key: value,
    };

    final source = from.primaryTextField?.key;
    final target = to.primaryTextField?.key;
    final text = source == null ? null : values[source];
    if (target != null &&
        text != null &&
        !carried.containsKey(target) &&
        !carried.containsKey(source) &&
        fits(target, text)) {
      carried[target] = text;
    }
    return carried;
  }
}
