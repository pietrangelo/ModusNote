import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_awake_stub.dart'
    if (dart.library.js_interop) 'screen_awake_web.dart'
    as web;

/// Keeps the screen on while cooking: hands in the dough should not have
/// to wake the phone. Android and iOS take a window flag through the app's
/// own channel, the browser a Screen Wake Lock. Best effort: where none is
/// offered the screen sleeps as usual.
abstract final class ScreenAwake {
  static const _native = MethodChannel('run.serv.modus/screen');

  static Future<void> keep(bool on) async {
    try {
      if (kIsWeb) {
        await web.keepAwake(on);
      } else {
        await _native.invokeMethod<void>('keepOn', {'on': on});
      }
    } on Object {
      // MissingPluginException in tests and on desktops; a browser that
      // refuses the lock (a hidden tab). Nothing to recover.
    }
  }
}
