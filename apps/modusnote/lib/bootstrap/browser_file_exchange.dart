import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../backup/file_exchange.dart';

/// Saves with a download and picks with the browser's file dialog. The
/// bytes stay on the device: the download's object URL points at memory
/// and is revoked once the browser has taken it.
final class BrowserFileExchange implements FileExchange {
  @override
  Future<void> save(String name, String mimeType, Uint8List bytes) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    try {
      (web.HTMLAnchorElement()
            ..href = url
            ..download = name)
          .click();
      // The click starts the download asynchronously; the URL must outlive
      // that start.
      await Future<void>.delayed(const Duration(seconds: 1));
    } finally {
      web.URL.revokeObjectURL(url);
    }
  }

  @override
  Future<Uint8List?> pick({
    required String accept,
    required int maxBytes,
  }) async {
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
    if (file.size > maxBytes) throw const FileTooLargeException();
    final buffer = await file.arrayBuffer().toDart;
    // A copy in Dart's own memory, as for pictures.
    return Uint8List.fromList(buffer.toDart.asUint8List());
  }
}
