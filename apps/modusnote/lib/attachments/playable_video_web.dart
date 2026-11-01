import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

/// [bytes] ready to play, from memory. [PlayableVideo.release] must be
/// called once the player closes.
Future<PlayableVideo> playableVideo(Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  final url = web.URL.createObjectURL(blob);
  return PlayableVideo._(VideoPlayerController.networkUrl(Uri.parse(url)), url);
}

/// Nothing is written to disk in a browser.
Future<void> sweepPlayableVideos() async {}

final class PlayableVideo {
  PlayableVideo._(this.controller, this._url);

  final VideoPlayerController controller;
  final String _url;

  Future<void> release() async {
    await controller.dispose();
    web.URL.revokeObjectURL(_url);
  }
}
