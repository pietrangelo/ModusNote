import 'dart:typed_data';

/// Port: hands a file to the person, and takes one from them, through the
/// platform's own dialogs. Only the web has one for now.
abstract interface class FileExchange {
  /// Offers [bytes] to save as [name].
  Future<void> save(String name, String mimeType, Uint8List bytes);

  /// The file picked, or null when none was. Throws [FileTooLargeException]
  /// for one over [maxBytes], before reading it.
  Future<Uint8List?> pick({required String accept, required int maxBytes});
}

final class FileTooLargeException implements Exception {
  const FileTooLargeException();
}
