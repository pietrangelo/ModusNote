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
  Future<Uint8List?> choose() async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = [for (final f in ImageFormat.values) f.mimeType].join(',');
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
    if (file.size > ImageProbe.maxBytes) throw const ImageTooLargeException();
    final buffer = await file.arrayBuffer().toDart;
    // A copy in Dart's own memory: under WebAssembly the browser's buffer
    // would otherwise be read through JS on every access.
    return Uint8List.fromList(buffer.toDart.asUint8List());
  }
}
