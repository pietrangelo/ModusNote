import 'package:meta/meta.dart';

import 'identifiers.dart';

enum ViolationCode {
  schemaMismatch,
  unknownField,
  missingRequired,
  typeMismatch,
  tooLong,
  outOfRange,
  notAnInteger,
  invalidChoice,
  tooManyTags,
  invalidCharacters,
}

/// One reason an entry does not satisfy its schema. [field] is null for
/// entry-wide problems such as a schema mismatch.
@immutable
final class Violation {
  const Violation(this.code, [this.field]);

  final ViolationCode code;
  final FieldKey? field;

  @override
  bool operator ==(Object other) =>
      other is Violation && other.code == code && other.field == field;

  @override
  int get hashCode => Object.hash(code, field);

  @override
  String toString() => 'Violation(${code.name}, $field)';
}

/// Outcome of a state transition users can get wrong: either the new value,
/// or every violation at once so the UI can mark all offending fields.
@immutable
sealed class Validated<T> {
  const Validated();
}

final class Valid<T> extends Validated<T> {
  const Valid(this.value);

  final T value;
}

final class Invalid<T> extends Validated<T> {
  Invalid(List<Violation> violations)
    : violations = List.unmodifiable(violations);

  final List<Violation> violations;
}
