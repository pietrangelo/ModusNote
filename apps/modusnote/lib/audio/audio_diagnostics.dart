import 'package:flutter/foundation.dart';

/// Prints why recording or playback failed, in debug builds only: the
/// screens show a fixed message, and without this the cause is lost.
///
/// Errors never carry audio or keys (our exception messages are fixed
/// strings), and release builds print nothing.
void reportAudioFailure(String during, Object error, StackTrace stack) {
  if (!kDebugMode) return;
  debugPrint('ModusNote audio: $during failed: ${error.runtimeType}: $error');
  debugPrintStack(stackTrace: stack, maxFrames: 12);
}
