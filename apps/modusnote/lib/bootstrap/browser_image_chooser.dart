import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:web/web.dart' as web;

import '../attachments/note_images.dart';

/// Picks a file with the browser's own dialog and reads it into memory:
/// no object URL, no request, nothing stored by the browser.
final class BrowserImageChooser implements ImageChooser {
  @override
  Future<Uint8List?> choose() => _pick(
    [for (final f in ImageFormat.values) f.mimeType].join(','),
    ImageProbe.maxBytes,
  );
}

/// A video file, the same way; the browser has no camera of its own here.
final class BrowserVideoChooser implements VideoChooser {
  @override
  Future<Uint8List?> choose({required bool camera}) =>
      _pick('video/mp4,video/quicktime', VideoProbe.maxBytes, video: true);
}

/// One file the person picks, read into memory; null when they cancel.
Future<Uint8List?> _pick(String accept, int max, {bool video = false}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accept;
  final picked = Completer<web.File?>();
  input
    ..addEventListener(
      'change',
      ((web.Event _) {
        if (!picked.isCompleted) picked.complete(input.files?.item(0));
      }).toJS,
    )
    ..addEventListener(
      'cancel',
      ((web.Event _) {
        if (!picked.isCompleted) picked.complete(null);
      }).toJS,
    )
    ..click();
  final file = await picked.future;
  if (file == null) return null;
  if (file.size > max) {
    throw video
        ? const VideoTooLargeException()
        : const ImageTooLargeException();
  }
  final buffer = await file.arrayBuffer().toDart;
  // A copy in Dart's own memory: under WebAssembly the browser's buffer
  // would otherwise be read through JS on every access.
  return Uint8List.fromList(buffer.toDart.asUint8List());
}
