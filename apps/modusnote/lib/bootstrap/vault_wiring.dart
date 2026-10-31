import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/remote_blobs.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:publishing/publishing.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/common.dart';

import '../notices/operator_keys.dart';
import '../sync/sync_config.dart';

/// The vault as every platform builds it: libsodium for the crypto and one
/// SQLite database (a file on mobile, IndexedDB in the browser) holding the
/// sealed header, the member log and the record envelopes. [passkeys] is
/// the second way in where the platform has one (WebAuthn in the browser);
/// without a [gateway] the vault never syncs.
VaultKeeper vaultKeeper({
  required SodiumSumo sodium,
  required CommonDatabase database,
  required KdfParameters kdf,
  SyncGateway? gateway,
  PasskeyPrf? passkeys,
}) => VaultKeeper(
  vaults: SqliteVaultStore(database),
  records: (workspace) =>
      SqliteLocalRecordStore(database, workspace: workspace),
  identities: SodiumIdentityService(sodium),
  hasher: SodiumContentHasher(sodium),
  keys: SodiumKeyDerivationService(sodium),
  subkeys: SodiumSubkeyDerivationService(sodium),
  envelopes: SodiumEnvelopeEncryptor(sodium),
  encapsulation: SodiumKeyEncapsulation(sodium),
  clock: const SystemClock(),
  random: Random.secure(),
  kdf: kdf,
  passkeys: passkeys,
  gateway: gateway,
);

/// The server the vaults sync with, the shared storage of their
/// recordings and pictures, the live channel that tells a vault when
/// another device changed it and the operator's signed notices; all null
/// in a build without one.
final class CloudWiring {
  const CloudWiring({
    this.gateway,
    this.remoteBlobs,
    this.live,
    this.serviceNotices,
    this.sites,
  });

  final SyncGateway? gateway;

  /// serv.pub's signed API, on the same server.
  final SiteGateway? sites;

  /// The blobs of an open vault's workspace on the server, every request
  /// signed by the vault's device.
  final RemoteBlobStore Function(UnlockedVault vault)? remoteBlobs;

  final LiveChannel? live;
  final ServiceNoticeBoard? serviceNotices;
}

/// Our server when the build names one, or the web page's own ([SyncConfig]).
/// [blake2b] hashes the proof of work a new workspace and an answer to a
/// code carry: plain Dart on native platforms, libsodium.js on the web.
/// [identities] checks the operator's signature on service notices,
/// against the keys the app pins ([operatorKeys]).
CloudWiring cloudWiring(
  SyncConfig? config, {
  required Uint8List Function(Uint8List message) blake2b,
  required IdentityService identities,
}) {
  if (config == null) return const CloudWiring();
  final server = ModusServer(origin: config.origin, blake2b: blake2b);
  return CloudWiring(
    gateway: server,
    sites: server.sites(),
    live: ModusLiveChannel(origin: config.origin),
    serviceNotices: ServiceNoticeBoard(
      source: ModusServiceNotices(origin: config.origin),
      identities: identities,
      keys: operatorKeys(),
      clock: const SystemClock(),
    ),
    remoteBlobs: (vault) => ModusRemoteBlobStore(
      origin: config.origin,
      workspace: vault.workspace.hex,
      authorize: vault.signer.authorize,
      serverTime: vault.signer.adjustClock,
    ),
  );
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// The device's list of vaults, beside their databases.
const shelfDatabaseName = 'vaults.sqlite';

/// Where a vault of the shelf keeps its database and its blobs: the first
/// vault under the names the app always used, so a device that had one
/// vault opens it unchanged, the others under their own id.
({String database, String blobs}) vaultStorageNames(ShelfId id) =>
    id == ShelfId.first
    ? (database: 'vault.sqlite', blobs: 'blobs')
    : (database: 'vault-$id.sqlite', blobs: 'blobs-$id');
