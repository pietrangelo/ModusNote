import 'dart:async';
import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import 'live_link.dart';

enum SyncState {
  /// The sync is not turned on, or the vault left the server: edits stay
  /// queued on the device.
  off,
  syncing,
  synced,

  /// The server could not be reached; the next attempt retries.
  offline,

  /// The server refused or served data that failed verification.
  failed,
}

enum SyncProblem {
  /// The server turned the request down (a policy, a ceiling).
  refused,

  /// The server does not know this device in the vault's workspace: an
  /// owner deleted it from the server, or this device was never let in.
  notAdmitted,

  /// The server hid or forged part of the workspace: nothing of it was
  /// applied.
  untrusted,

  /// The workspace reached its storage quota on the server (HTTP 413):
  /// edits that grow it stay queued until notes are deleted.
  full,

  /// Another device removed this one from the vault: it no longer syncs.
  removed,

  /// The notes synced, but the server turned down a recording or a
  /// picture (too large, or the vault's file space is full); the others
  /// went up.
  blobRefused,
}

/// Keeps an open vault in step with the server, once its sync is turned
/// on: right after unlock and [enable], a moment after each saved edit, every [interval] and when the
/// app returns to the foreground. While syncs find nothing, the periodic
/// one slows down to every [maxQuietTicks] + 1 intervals. One sync runs at a time; a request while
/// one runs makes it go round once more.
///
/// Where the server offers a live channel, it opens after the first sync
/// that reached the server ([LiveLink]): another device's change syncs at
/// once, and while the channel is open the periodic sync only checks every
/// [livePolling]. A device removed or no longer admitted, and a vault
/// deleted from the server, close it until the next unlock.
///
/// Created on unlock and disposed on lock, before the keys are released:
/// whatever an in-flight sync does after that is ignored.
final class SyncController extends ChangeNotifier {
  SyncController({
    required this._engine,
    required this._onPulled,
    this._onLost,
    this._afterSync,
    this._enabled = false,
    this._turnOn,
    this._retired = false,
    this._retire,
    this._debounce = const Duration(seconds: 2),
    this._interval = const Duration(minutes: 1),
    Stream<LiveSignal> Function()? live,
    LiveTimings liveTimings = const LiveTimings(),
    this._livePolling = const Duration(minutes: 30),
    Random? random,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (live != null) {
      _live = LiveLink(
        connect: live,
        sync: syncNow,
        lastSynced: () => _lastSynced,
        timings: liveTimings,
        random: random,
        clock: _clock,
      );
    }
  }

  final SyncEngine _engine;
  final Future<void> Function() _onPulled;

  /// Keeps this device's edits that lost a conflict, before [_onPulled]
  /// reads the notes again.
  final Future<void> Function(List<LostEdit> lost)? _onLost;

  /// Remembers in the vault that its sync is on.
  final Future<void> Function()? _turnOn;

  /// Runs after each sync that reached the server: uploads recordings.
  final Future<void> Function(SyncReport report)? _afterSync;

  /// Remembers in the vault that its data was deleted from the server.
  final Future<void> Function()? _retire;
  final Duration _debounce;
  final Duration _interval;

  /// How often the periodic sync checks while the live channel is open.
  final Duration _livePolling;
  final DateTime Function() _clock;
  LiveLink? _live;

  /// Periodic ticks skipped at most after syncs that moved nothing.
  static const maxQuietTicks = 4;

  var _state = SyncState.off;
  SyncProblem? _problem;
  DateTime? _lastSynced;
  Timer? _soon;
  Timer? _periodic;
  Future<void>? _running;
  var _again = false;
  var _quiet = 0;
  var _skip = 0;
  var _disposed = false;
  bool _enabled;
  bool _retired;

  SyncState get state => _state;

  /// Why the last sync failed, while [state] is [SyncState.failed].
  SyncProblem? get problem => _problem;

  DateTime? get lastSynced => _lastSynced;

  /// Whether the sync was turned on: a new vault stays on the device
  /// until its person does, a vault joined with a code syncs from the
  /// start.
  bool get enabled => _enabled;

  /// The vault's data was deleted from the server: it no longer syncs.
  /// The server forgot the workspace while this vault still counts what it
  /// pushed and pulled there, so syncing again would send none of its notes.
  bool get retired => _retired;

  /// Whether the live channel is open: the server tells this device when
  /// another one changes the vault.
  bool get liveOpen => _live?.isOpen ?? false;

  void start() {
    _periodic = Timer.periodic(_interval, (_) {
      if (liveOpen) {
        // The channel says when something changed: a check now and then
        // covers a signal the server did not send.
        final last = _lastSynced;
        if (last == null || _clock().difference(last) >= _livePolling) {
          unawaited(syncNow());
        }
      } else if (_skip > 0) {
        _skip--;
      } else {
        unawaited(syncNow());
      }
    });
    unawaited(syncNow());
  }

  /// The app went to the background: the live channel closes.
  void pause() => _live?.pause();

  /// The app is back in the foreground: the live channel opens again, if
  /// it was open.
  void resume() => _live?.resume();

  /// An edit was saved: sync once edits stop coming for a moment.
  void changed() {
    if (_disposed) return;
    _quiet = _skip = 0;
    _soon?.cancel();
    _soon = Timer(_debounce, syncNow);
  }

  /// Turns the sync on, for good, and syncs.
  Future<void> enable() async {
    if (_enabled || _retired || _disposed) return;
    await _turnOn?.call();
    _enabled = true;
    await syncNow();
  }

  /// Deletes the vault's workspace from the server, with everything it
  /// holds: notes, recordings, pictures, members and codes, for every
  /// device. Throws what [SyncEngine.deleteFromServer] throws, with
  /// nothing deleted yet. The notes stay on the devices.
  Future<void> deleteFromServer() async {
    if (_retired) return;
    // A sync in flight would only fail against a vanishing workspace.
    for (var running = _running; running != null; running = _running) {
      await running;
    }
    await _engine.deleteFromServer();
    _live?.stop();
    _retired = true;
    await _retire?.call();
    _set(SyncState.off);
  }

  /// Who belongs to the vault, in the order they joined.
  List<WorkspaceMember> get members =>
      _engine.ledger.workspace.members.values.toList();

  /// The line two devices compare to learn that the server shows them the
  /// same member log.
  LedgerFingerprint get ledgerFingerprint => _engine.ledger.fingerprint;

  /// This device, among [members].
  MemberId get me => _engine.me;

  /// Whether this device may remove others: an owner still in the vault.
  bool get managesMembers =>
      _engine.ledger.workspace.member(_engine.me)?.role.managesMembers ?? false;

  /// Removes [member] and rotates the vault's key; see [SyncEngine.revoke].
  /// No sync runs meanwhile. Throws what the engine throws; when the
  /// removal was recorded but could not be sent, the next sync sends it.
  Future<void> revoke(MemberId member) async {
    for (var running = _running; running != null; running = _running) {
      await running;
    }
    final done = Completer<void>();
    _running = done.future;
    try {
      await _engine.revoke(member);
    } finally {
      _running = null;
      done.complete();
      if (!_disposed) {
        notifyListeners();
        unawaited(syncNow());
      }
    }
  }

  Future<void> syncNow() {
    if (_disposed) return Future.value();
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again && !_disposed);
  }

  Future<void> _once() async {
    if (_retired || !_enabled) return _set(SyncState.off);
    _set(SyncState.syncing);
    try {
      final report = await _engine.sync();
      if (_disposed) return;
      if (report.offline) return _set(SyncState.offline);
      if (report.pushed > 0 || report.pulled > 0) {
        _quiet = _skip = 0;
      } else {
        _skip = _quiet = min(_quiet + 1, maxQuietTicks);
      }
      if (report.lost.isNotEmpty) await _onLost?.call(report.lost);
      if (_disposed) return;
      if (report.pulled > 0) await _onPulled();
      if (_disposed) return;
      await _afterSync?.call(report);
      if (_disposed) return;
      _lastSynced = _clock();
      _set(SyncState.synced);
      _live?.start();
    } on SyncServerRejectedException catch (e) {
      _fail(e.status == 413 ? SyncProblem.full : SyncProblem.refused);
    } on RemoteBlobUnavailableException {
      // The notes went through; the recordings follow next time.
      if (!_disposed) _set(SyncState.offline);
    } on RemoteBlobRejectedException {
      _fail(SyncProblem.blobRefused);
    } on MalformedBlobException {
      _fail(SyncProblem.untrusted);
    } on LedgerRollbackException {
      _fail(SyncProblem.untrusted);
    } on TamperedWorkspaceDataException {
      _fail(SyncProblem.untrusted);
    } on MalformedSyncDataException {
      _fail(SyncProblem.untrusted);
    } on RemovedFromWorkspaceException {
      _fail(SyncProblem.removed);
    } on NotAdmittedException {
      _fail(SyncProblem.notAdmitted);
    } on Object {
      // The vault locked under a running sync and its keys are gone.
      if (_disposed) return;
      // Never left showing "syncing" with the button off.
      _fail(SyncProblem.refused);
      rethrow;
    }
  }

  void _fail(SyncProblem problem) {
    if (_disposed) return;
    if (problem == SyncProblem.removed || problem == SyncProblem.notAdmitted) {
      _live?.stop();
    }
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
    _live?.dispose();
    _soon?.cancel();
    _periodic?.cancel();
    super.dispose();
  }
}
