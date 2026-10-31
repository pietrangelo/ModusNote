import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:publishing/publishing.dart';

/// [SiteKeys] in the open vault: each site's key is a detached identity
/// ([VaultKeeper.createDetachedIdentity]), sealed under the vault's local
/// key on this device, never in the members' log.
final class VaultSiteKeys implements SiteKeys {
  VaultSiteKeys(this._keeper, this._vault);

  final VaultKeeper _keeper;
  final UnlockedVault _vault;

  static String _slot(SiteName name) => 'site.${name.value}';

  @override
  Future<SiteKey?> open(SiteName name) async {
    final identity = await _keeper.openDetachedIdentity(_vault, _slot(name));
    return identity == null
        ? null
        : _Key(identity, _keeper.signerFor(identity));
  }

  @override
  Future<SiteKey> create(SiteName name) async {
    final identity = await _keeper.createDetachedIdentity(_vault, _slot(name));
    return _Key(identity, _keeper.signerFor(identity));
  }

  @override
  Future<void> forget(SiteName name) =>
      _keeper.forgetDetachedIdentity(_vault, _slot(name));
}

final class _Key implements SiteKey {
  _Key(this._identity, this._signer);

  final IdentityKeyPair _identity;
  final RequestSigner _signer;

  @override
  Future<String> authorize(String method, String path, Uint8List body) =>
      _signer.authorize(method, path, body);

  @override
  void adjustClock(DateTime server) => _signer.adjustClock(server);

  @override
  void release() => _identity.dispose();
}

/// [SiteBookStore] as a sealed setting of the open vault: device-only,
/// like the site's key beside it.
final class VaultSiteBooks implements SiteBookStore {
  VaultSiteBooks(this._keeper, this._vault);

  final VaultKeeper _keeper;
  final UnlockedVault _vault;

  static const _setting = 'publishing.site';

  @override
  Future<SiteBook?> load() async {
    final bytes = await _keeper.loadSetting(_vault, _setting);
    return bytes == null ? null : SiteBook.fromBytes(bytes);
  }

  @override
  Future<void> save(SiteBook? book) =>
      _keeper.saveSetting(_vault, _setting, book?.toBytes());
}
