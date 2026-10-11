import 'dart:async';

import 'package:flutter/widgets.dart';

/// Decides when an open vault locks itself: after [idle] without any
/// touch, key or edit, and once the app has spent [background] out of
/// sight. Work that must not be cut short (a take being recorded) holds
/// the vault open until it ends.
///
/// The background rule is checked against the clock as well as a timer:
/// a suspended process does not run timers, so on return the elapsed time
/// decides, before anything is drawn again.
final class AutoLock {
  AutoLock({
    required this.onLock,
    this.idle = defaultIdle,
    this.background = defaultBackground,
    this._clock = DateTime.now,
  }) {
    _armIdle();
  }

  /// Long enough to read a note or listen to a short take untouched.
  static const defaultIdle = Duration(minutes: 5);

  /// Long enough to answer a notification and come back.
  static const defaultBackground = Duration(seconds: 30);

  final VoidCallback onLock;
  final Duration idle;
  final Duration background;
  final DateTime Function() _clock;

  Timer? _idleTimer;
  Timer? _backgroundTimer;
  DateTime? _hiddenSince;
  var _holds = 0;
  var _done = false;

  /// The user did something: the idle countdown starts over.
  void touch() {
    if (_done) return;
    _armIdle();
  }

  /// Keeps the vault open until the returned callback is called, which may
  /// happen only once.
  VoidCallback hold() {
    _holds++;
    _idleTimer?.cancel();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holds--;
      if (_done || _holds > 0) return;
      _armIdle();
      if (_hiddenSince != null) _armBackground();
    };
  }

  /// The app went out of sight.
  void hidden() {
    if (_done || _hiddenSince != null) return;
    _hiddenSince = _clock();
    _armBackground();
  }

  /// The app is in sight again; locks at once if it was away too long.
  void shown() {
    final since = _hiddenSince;
    if (_done || since == null) return;
    _hiddenSince = null;
    _backgroundTimer?.cancel();
    if (_holds == 0 && _clock().difference(since) >= background) {
      _lock();
    } else {
      _armIdle();
    }
  }

  void dispose() {
    _done = true;
    _idleTimer?.cancel();
    _backgroundTimer?.cancel();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    if (_holds == 0) _idleTimer = Timer(idle, _lock);
  }

  void _armBackground() {
    _backgroundTimer?.cancel();
    if (_holds > 0) return;
    final elapsed = _clock().difference(_hiddenSince!);
    _backgroundTimer = Timer(
      elapsed >= background ? Duration.zero : background - elapsed,
      _lock,
    );
  }

  void _lock() {
    if (_done || _holds > 0) return;
    dispose();
    onLock();
  }
}

/// Gives the screens of an open vault access to its [AutoLock], so edits
/// count as activity and recordings can hold the vault open.
class AutoLockScope extends InheritedWidget {
  const AutoLockScope({
    required this.autoLock,
    required super.child,
    super.key,
  });

  final AutoLock autoLock;

  /// Null outside an open vault (the web preview, tests of single screens).
  static AutoLock? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AutoLockScope>()?.autoLock;

  @override
  bool updateShouldNotify(AutoLockScope old) => old.autoLock != autoLock;
}
