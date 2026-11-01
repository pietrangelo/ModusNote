import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// [bytes] ready to play. [PlayableVideo.release] must be called once the
/// player closes.
Future<PlayableVideo> playableVideo(Uint8List bytes) async {
  final folder = await _folder();
  await folder.create(recursive: true);
  final random = Random.secure();
  final name = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final file = File('${folder.path}${Platform.pathSeparator}$name.mp4');
  await file.writeAsBytes(bytes, flush: true);
  return PlayableVideo._(VideoPlayerController.file(file), file);
}

/// Deletes what a player stopped before closing left behind.
Future<void> sweepPlayableVideos() async {
  try {
    final folder = await _folder();
    if (await folder.exists()) await folder.delete(recursive: true);
  } on FileSystemException {
    // Nothing to sweep, or it goes next time.
  }
}

Future<Directory> _folder() async => Directory(
  '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}videos',
);

final class PlayableVideo {
  PlayableVideo._(this.controller, this._file);

  final VideoPlayerController controller;
  final File _file;

  Future<void> release() async {
    await controller.dispose();
    try {
      final length = await _file.length();
      await _file.writeAsBytes(Uint8List(length), flush: true);
      await _file.delete();
    } on FileSystemException {
      // Already gone; the next sweep checks.
    }
  }
}
