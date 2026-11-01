import 'package:flutter/widgets.dart';

import '../publishing/publish_sheet.dart';
import '../vault/auto_lock.dart';

/// What a screen opened over the library needs from the open vault.
///
/// A pushed route sits beside the library in the navigator, not under it,
/// so the scopes the vault puts around the library do not reach it: they
/// are read here, where the route is pushed, and given to it again. On a
/// phone every note opens this way; without [PublishingScope] its editor
/// would offer no publishing (it did, in 0.4.0).
final class VaultScopes {
  VaultScopes.of(BuildContext context)
    : _autoLock = AutoLockScope.maybeOf(context),
      _publishing = PublishingScope.maybeOf(context);

  final AutoLock? _autoLock;
  final PublishingAccess? _publishing;

  /// [screen] under the scopes read when this was made.
  Widget around(Widget screen) {
    var child = screen;
    if (_publishing case final access?) {
      child = PublishingScope(access: access, child: child);
    }
    if (_autoLock case final autoLock?) {
      child = AutoLockScope(autoLock: autoLock, child: child);
    }
    return child;
  }
}
