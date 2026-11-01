import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.WakeLockSentinel? _sentinel;

/// A Screen Wake Lock, released when [on] is false. The browser drops it
/// by itself when the tab is hidden.
Future<void> keepAwake(bool on) async {
  if (on) {
    if (_sentinel case final held? when !held.released) return;
    _sentinel = await web.window.navigator.wakeLock.request('screen').toDart;
  } else {
    final sentinel = _sentinel;
    _sentinel = null;
    await sentinel?.release().toDart;
  }
}
