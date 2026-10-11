/// Collaboration & Access Control: spazi condivisi, membri e rotazione delle GroupKey.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/application/group_keyring.dart';
export 'src/application/membership_ledger.dart';
export 'src/application/workspace_administration.dart';
export 'src/application/workspace_content_cipher.dart';
export 'src/core/collaboration_exception.dart';
export 'src/core/identifiers.dart';
export 'src/core/invitation.dart';
export 'src/core/key_bundle.dart';
export 'src/core/membership_change.dart';
export 'src/core/membership_record.dart';
export 'src/core/role.dart';
export 'src/core/workspace.dart';
export 'src/core/workspace_ciphertext.dart';
