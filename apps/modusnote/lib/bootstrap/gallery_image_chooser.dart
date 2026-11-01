import 'dart:io';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../attachments/note_images.dart';

/// Picks from the phone's photos with the system picker (no permission
/// asked: Android's photo picker, iOS's PHPicker). The picker hands over a
/// copy in the app's cache; it is read into memory and deleted, so the
/// only plaintext left is the original the person already had.
final class GalleryImageChooser implements ImageChooser {
  final _picker = ImagePicker();

  @override
  Future<Uint8List?> choose() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    try {
      if (await file.length() > ImageProbe.maxBytes) {
        throw const ImageTooLargeException();
      }
      return await file.readAsBytes();
    } finally {
      await _deleteCopy(file.path);
    }
  }

  /// Only a file inside the app's own cache: never the person's original.
  static Future<void> _deleteCopy(String path) async {
    final cache = (await getTemporaryDirectory()).absolute.path;
    final copy = File(path).absolute;
    if (!copy.path.startsWith('$cache${Platform.pathSeparator}')) return;
    try {
      await copy.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// Picks a video from the phone's library, or records one with the camera
/// (asked for at most a minute), with the system's own screens. Like
/// [GalleryImageChooser], the cache copy is read and deleted.
final class GalleryVideoChooser implements VideoChooser {
  final _picker = ImagePicker();

  @override
  Future<Uint8List?> choose({required bool camera}) async {
    final file = await _picker.pickVideo(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxDuration: const Duration(seconds: 60),
    );
    if (file == null) return null;
    try {
      if (await file.length() > VideoProbe.maxBytes) {
        throw const VideoTooLargeException();
      }
      return await file.readAsBytes();
    } finally {
      await GalleryImageChooser._deleteCopy(file.path);
    }
  }
}
