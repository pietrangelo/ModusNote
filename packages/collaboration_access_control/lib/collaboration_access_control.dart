/// Collaboration & Access Control: spazi condivisi, membri e rotazione delle GroupKey.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/core/collaboration_exception.dart';
export 'src/core/identifiers.dart';
export 'src/core/key_bundle.dart';
export 'src/core/membership_change.dart';
export 'src/core/membership_record.dart';
export 'src/core/role.dart';
export 'src/core/workspace.dart';
