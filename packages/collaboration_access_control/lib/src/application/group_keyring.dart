import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/collaboration_exception.dart';
import '../core/identifiers.dart';

/// The GroupKeys this device holds for one workspace, one per epoch.
///
/// It owns the keys: [dispose] releases all of them, and keys added for an
/// epoch already held are disposed rather than allowed to replace it.
final class GroupKeyring {
  GroupKeyring(this.workspace);

  final WorkspaceId workspace;
  final _keys = <KeyEpoch, SymmetricKey>{};

  List<KeyEpoch> get epochs =>
      _keys.keys.toList()..sort((a, b) => a.value.compareTo(b.value));

  bool holds(KeyEpoch epoch) => _keys.containsKey(epoch);

  /// The first key granted for an epoch wins: a later, conflicting grant
  /// for the same epoch cannot swap the key under existing ciphertext.
  void add(KeyEpoch epoch, SymmetricKey key) {
    if (_keys.containsKey(epoch)) {
      key.dispose();
      return;
    }
    _keys[epoch] = key;
  }

  SymmetricKey keyFor(KeyEpoch epoch) =>
      _keys[epoch] ?? (throw const MissingGroupKeyException());

  void dispose() {
    for (final key in _keys.values) {
      key.dispose();
    }
    _keys.clear();
  }
}
