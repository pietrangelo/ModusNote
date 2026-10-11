/// Offline Sync: revisioni cifrate e firmate, risoluzione dei conflitti,
/// coda offline.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/application/ports.dart';
export 'src/application/revision_authenticator.dart';
export 'src/application/sync_engine.dart';
export 'src/application/vault_keeper.dart';
export 'src/core/conflict_resolver.dart';
export 'src/core/local_record.dart';
export 'src/core/outbox.dart';
export 'src/core/record_revision.dart';
export 'src/core/sync_exception.dart';
export 'src/core/sync_row.dart';
export 'src/core/vault_header.dart';
export 'src/core/version_vector.dart';
