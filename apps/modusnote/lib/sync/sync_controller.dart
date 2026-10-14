import 'dart:async';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

enum SyncState {
  /// No account: edits stay queued on the device.
  signedOut,
  syncing,
  synced,

  /// The server could not be reached; the next attempt retries.
  offline,

  /// The server refused or served data that failed verification.
  failed,
}

enum SyncProblem {
  /// The server turned the request down (an expired account, a policy).
  refused,

  /// The server hid or forged part of the workspace: nothing of it was
  /// applied.
  untrusted,
}

/// Keeps an open vault in step with the server: right after unlock and
/// sign-in, a moment after each saved edit, every [interval] and when the
/// app returns to the foreground. One sync runs at a time; a request while
/// one runs makes it go round once more.
///
/// Created on unlock and disposed on lock, before the keys are released:
/// whatever an in-flight sync does after that is ignored.
final class SyncController extends ChangeNotifier {
  SyncController({
    required this._engine,
    required this._account,
    required this._onPulled,
    this._afterSync,
    this._retired = false,
    this._retire,
    this._debounce = const Duration(seconds: 2),
    this._interval = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SyncEngine _engine;
  final SyncAccount _account;
  final Future<void> Function() _onPulled;

  /// Runs after each sync that reached the server: uploads recordings.
  final Future<void> Function()? _afterSync;

  /// Remembers in the vault that its account was deleted.
  final Future<void> Function()? _retire;
  final Duration _debounce;
  final Duration _interval;
  final DateTime Function() _clock;

  var _state = SyncState.signedOut;
  SyncProblem? _problem;
  DateTime? _lastSynced;
  Timer? _soon;
  Timer? _periodic;
  Future<void>? _running;
  var _again = false;
  var _disposed = false;
  bool _retired;

  SyncState get state => _state;

  /// Why the last sync failed, while [state] is [SyncState.failed].
  SyncProblem? get problem => _problem;

  DateTime? get lastSynced => _lastSynced;

  bool get signedIn => _account.signedIn;

  String? get email => _account.email;

  /// The vault's account was deleted: it no longer syncs nor signs in.
  /// The server forgot the workspace while this vault still counts what it
  /// pushed and pulled there, so a new account would get none of its notes.
  bool get retired => _retired;

  void start() {
    _account.onChanged = _accountChanged;
    _periodic = Timer.periodic(_interval, (_) => syncNow());
    unawaited(syncNow());
  }

  /// An edit was saved: sync once edits stop coming for a moment.
  void changed() {
    if (_disposed) return;
    _soon?.cancel();
    _soon = Timer(_debounce, syncNow);
  }

  Future<void> sendCode(String email) => _account.sendCode(email);

  Future<void> signIn(String email, String code) =>
      _account.signIn(email, code);

  Future<void> signOut() => _account.signOut();

  /// Deletes the account and everything the server holds for it. Throws
  /// what [SyncAccount.deleteAccount] throws, with nothing deleted yet.
  Future<void> deleteAccount() async {
    if (_retired) return;
    // A sync in flight would only fail against a vanishing account.
    await _running;
    await _account.deleteAccount();
    _retired = true;
    await _retire?.call();
    _set(SyncState.signedOut);
  }

  Future<void> syncNow() {
    if (_disposed) return Future.value();
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  void _accountChanged() {
    if (_disposed) return;
    if (!_account.signedIn) _lastSynced = null;
    _set(_account.signedIn ? _state : SyncState.signedOut);
    unawaited(syncNow());
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again && !_disposed);
  }

  Future<void> _once() async {
    if (_retired || !_account.signedIn) return _set(SyncState.signedOut);
    _set(SyncState.syncing);
    try {
      final report = await _engine.sync();
      if (_disposed) return;
      if (report.offline) {
        return _set(
          _account.signedIn ? SyncState.offline : SyncState.signedOut,
        );
      }
      if (report.pulled > 0) await _onPulled();
      if (_disposed) return;
      await _afterSync?.call();
      if (_disposed) return;
      _lastSynced = _clock();
      _set(SyncState.synced);
    } on SyncServerRejectedException {
      _fail(SyncProblem.refused);
    } on RemoteBlobUnavailableException {
      // The notes went through; the recordings follow next time.
      if (!_disposed) _set(SyncState.offline);
    } on RemoteBlobRejectedException {
      _fail(SyncProblem.refused);
    } on MalformedBlobException {
      _fail(SyncProblem.untrusted);
    } on LedgerRollbackException {
      _fail(SyncProblem.untrusted);
    } on TamperedWorkspaceDataException {
      _fail(SyncProblem.untrusted);
    } on MalformedSyncDataException {
      _fail(SyncProblem.untrusted);
    } on Object {
      // The vault locked under a running sync and its keys are gone.
      if (_disposed) return;
      rethrow;
    }
  }

  void _fail(SyncProblem problem) {
    if (_disposed) return;
    _problem = problem;
    _set(SyncState.failed);
  }

  void _set(SyncState state) {
    if (_disposed) return;
    if (state != SyncState.failed) _problem = null;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _soon?.cancel();
    _periodic?.cancel();
    if (_account.onChanged == _accountChanged) _account.onChanged = null;
    super.dispose();
  }
}
