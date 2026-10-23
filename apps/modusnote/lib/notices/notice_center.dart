import 'dart:async';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';

import '../sync/sync_controller.dart';

/// A record of the membership log as the notices show it.
@immutable
final class SecurityNotice {
  const SecurityNotice(
    this.notice, {
    required this.unread,
    required this.byThisDevice,
    this.rotated = false,
  });

  final MembershipNotice notice;

  /// Written after the mark of what the person saw, by another device.
  final bool unread;

  /// This device wrote the record: an invitation or a removal made here.
  final bool byThisDevice;

  /// For a removal, whether this device holds the key of the epoch after
  /// it: what is written from now on is sealed under a new key. Without
  /// it, the device is waiting for that key.
  final bool rotated;

  @override
  bool operator ==(Object other) =>
      other is SecurityNotice &&
      other.notice == notice &&
      other.unread == unread &&
      other.byThisDevice == byThisDevice &&
      other.rotated == rotated;

  @override
  int get hashCode => Object.hash(notice, unread, byThisDevice, rotated);
}

/// The notices of an open vault, inside the app only.
///
/// Security notices come from the membership log this device verified
/// itself (a device came in, was removed, left, changed role), so the
/// server can delay them but never invent one; those after the sealed
/// [NoticeMark] and written by another device are unread. Service notices
/// are the operator's, signed by a key the app pins ([ServiceNoticeBoard]),
/// read only while the vault syncs: after the first sync of the unlock,
/// then at most every six hours. The person closes them one by one.
///
/// Lives while the vault is open, beside its [SyncController].
final class NoticeCenter extends ChangeNotifier {
  NoticeCenter({
    required this._engine,
    required this._sync,
    required NoticeMark mark,
    required this._saveMark,
    this._board,
    Set<int> dismissed = const {},
    this._saveDismissed,
    this._serviceEvery = const Duration(hours: 6),
    DateTime Function()? clock,
  }) : _seen = mark.seen,
       _dismissed = {...dismissed},
       _clock = clock ?? DateTime.now {
    _security = _read();
    _sync.addListener(_synced);
  }

  final SyncEngine _engine;
  final SyncController _sync;
  final Future<void> Function(NoticeMark mark) _saveMark;
  final ServiceNoticeBoard? _board;
  final Future<void> Function(Set<int> serials)? _saveDismissed;
  final Duration _serviceEvery;
  final DateTime Function() _clock;

  int _seen;
  final Set<int> _dismissed;
  final _serviceSeen = <int>{};
  List<SecurityNotice> _security = const [];
  List<ServiceNotice> _service = const [];
  DateTime? _fetched;
  var _fetching = false;
  var _disposed = false;

  /// The membership notices, newest first.
  List<SecurityNotice> get security => _security;

  /// The operator's notices still to show, newest first.
  List<ServiceNotice> get service => _service;

  int get unreadSecurity => _security.where((n) => n.unread).length;

  int get unreadService =>
      _service.where((n) => !_serviceSeen.contains(n.serial)).length;

  int get unread => unreadSecurity + unreadService;

  /// This device, as the notices name it.
  MemberId get me => _engine.me;

  /// The person opened the notices: everything shown counts as read.
  Future<void> markRead() async {
    final seen = _engine.ledger.records.length;
    final read = [for (final notice in _service) notice.serial];
    if (seen == _seen && _serviceSeen.containsAll(read)) return;
    _seen = seen;
    _serviceSeen.addAll(read);
    _security = _read();
    notifyListeners();
    await _saveMark(NoticeMark(seen));
  }

  /// Closes a service notice for good, in this vault.
  Future<void> dismiss(int serial) async {
    if (!_dismissed.add(serial)) return;
    _service = [
      for (final notice in _service)
        if (notice.serial != serial) notice,
    ];
    notifyListeners();
    await _saveDismissed?.call({..._dismissed});
  }

  List<SecurityNotice> _read() {
    final me = _engine.me;
    return [
      for (final notice in MembershipNotices.of(_engine.ledger).reversed)
        SecurityNotice(
          notice,
          unread: notice.sequence >= _seen && notice.author != me,
          byThisDevice: notice.author == me,
          rotated: switch (notice) {
            MemberRemoved(:final epoch) => _holds(epoch),
            _ => false,
          },
        ),
    ];
  }

  bool _holds(KeyEpoch epoch) {
    try {
      _engine.contentKeyFor(epoch);
      return true;
    } on MissingGroupKeyException {
      return false;
    }
  }

  void _synced() {
    if (_disposed) return;
    final security = _read();
    if (!listEquals(security, _security)) {
      _security = security;
      notifyListeners();
    }
    if (_sync.state == SyncState.synced) unawaited(_fetchService());
  }

  /// Only for a vault that syncs, and seldom: a notice is not urgent.
  Future<void> _fetchService() async {
    final board = _board;
    if (board == null || _fetching || !_sync.enabled || _sync.retired) {
      return;
    }
    final fetched = _fetched;
    final now = _clock();
    if (fetched != null && now.difference(fetched) < _serviceEvery) return;
    _fetching = true;
    _fetched = now;
    try {
      final service = await board.current(dismissed: {..._dismissed});
      if (_disposed) return;
      _service = [
        for (final notice in service)
          if (!_dismissed.contains(notice.serial)) notice,
      ];
      notifyListeners();
    } on Exception {
      // Anything that goes wrong is no notice.
    } finally {
      _fetching = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sync.removeListener(_synced);
    super.dispose();
  }
}
