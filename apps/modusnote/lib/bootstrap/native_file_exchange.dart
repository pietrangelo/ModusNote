import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../backup/file_exchange.dart';

/// Saves and picks through the system's own document dialogs (the
/// Storage Access Framework on Android, the document picker on iOS): the
/// person chooses where the file goes, and the bytes are written there
/// straight from memory. A picked file is copied by the system into the
/// app's cache to be read; the copy is removed as soon as it has been.
final class NativeFileExchange implements FileExchange {
  @override
  Future<void> save(String name, String mimeType, Uint8List bytes) async {
    await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mimeType);
  }

  @override
  Future<Uint8List?> pick({
    required String accept,
    required int maxBytes,
  }) async {
    try {
      final picked = await FilePicker.pickFiles();
      if (picked.isEmpty) return null;
      final file = picked.first;
      final size = await file.length();
      if (size != null && size > maxBytes) throw const FileTooLargeException();
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) throw const FileTooLargeException();
      return bytes;
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }
}
