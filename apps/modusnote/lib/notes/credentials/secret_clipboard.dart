import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies a password and takes it back off the clipboard after [keep],
/// unless something else was copied meanwhile.
///
/// On the web the clipboard cannot be read without asking the person, so
/// there it is emptied whatever it holds by then; a browser refuses the
/// write while the page is in the background, in which case the password
/// stays until the next copy. Other apps can read the clipboard while it
/// holds the password: copying is the person's choice, revealing is not
/// needed for it. On Android and iOS the copy is marked sensitive (hidden
/// in the clipboard preview and keyboard histories), and on iOS it stays on
/// this device and expires by itself after [keep].
abstract final class SecretClipboard {
  static const keep = Duration(seconds: 30);

  static const _native = MethodChannel('run.serv.modus/clipboard');

  static Timer? _timer;
  static String? _copied;

  static Future<void> copy(String secret) async {
    try {
      if (kIsWeb) throw MissingPluginException();
      await _native.invokeMethod<void>('copySecret', {
        'text': secret,
        'seconds': keep.inSeconds,
      });
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: secret));
    }
    _copied = secret;
    _timer?.cancel();
    _timer = Timer(keep, _clear);
  }

  static Future<void> _clear() async {
    final copied = _copied;
    _copied = null;
    _timer = null;
    if (copied == null) return;
    try {
      if (!kIsWeb) {
        final now = await Clipboard.getData(Clipboard.kTextPlain);
        if (now?.text != copied) return;
      }
      await Clipboard.setData(const ClipboardData(text: ''));
    } on PlatformException {
      // Nothing to do: the next copy replaces it.
    }
  }

  /// Clears now what is still pending; for tests.
  @visibleForTesting
  static Future<void> flush() async {
    _timer?.cancel();
    await _clear();
  }
}
