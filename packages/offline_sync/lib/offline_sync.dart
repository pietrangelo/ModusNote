/// Offline Sync: revisioni cifrate e firmate, risoluzione dei conflitti,
/// coda offline.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/application/ports.dart';
export 'src/application/request_signer.dart';
export 'src/application/revision_authenticator.dart';
export 'src/application/service_notice_board.dart';
export 'src/application/sync_engine.dart';
export 'src/application/vault_keeper.dart';
export 'src/core/conflict_resolver.dart';
export 'src/core/invite.dart';
export 'src/core/live_signal.dart';
export 'src/core/local_record.dart';
export 'src/core/notice_settings.dart';
export 'src/core/outbox.dart';
export 'src/core/passkey_slot.dart';
export 'src/core/record_revision.dart';
export 'src/core/service_notice.dart';
export 'src/core/signed_request.dart';
export 'src/core/sync_exception.dart';
export 'src/core/sync_row.dart';
export 'src/core/vault_backup.dart';
export 'src/core/vault_header.dart';
export 'src/core/vault_shelf.dart';
export 'src/core/version_vector.dart';
