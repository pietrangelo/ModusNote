import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../attachments/playable_video.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../../theme/modus_palette.dart';

/// Plays a step's video, full screen, only when asked: decrypted when the
/// viewer opens, handed to the platform's player ([playableVideo]) and
/// taken back from it when the viewer closes.
class VideoViewer extends StatefulWidget {
  const VideoViewer({required this.bytes, super.key});

  final Future<Uint8List> bytes;

  static Future<void> show(
    BuildContext context, {
    required Future<Uint8List> bytes,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => VideoViewer(bytes: bytes),
    ),
  );

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  PlayableVideo? _video;
  var _failed = false;
  var _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final video = await playableVideo(await widget.bytes);
      if (_closed) {
        await video.release();
        return;
      }
      _video = video;
      await video.controller.initialize();
      if (!mounted) return;
      setState(() {});
      await video.controller.play();
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_video?.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ModusPalette.of(context);
    final controller = _video?.controller;
    final ready = controller != null && controller.value.isInitialized;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        foregroundColor: palette.text,
        title: Text(l10n.stepVideo),
      ),
      body: Center(
        child: _failed
            ? Text(
                l10n.videoOpenFailed,
                key: const ValueKey('video-failed'),
                style: TextStyle(color: palette.text),
              )
            : !ready
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
                  ),
                  VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.all(Spacing.s),
                  ),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => IconButton(
                      key: const ValueKey('video-play'),
                      iconSize: IconSizes.inline * 2,
                      color: palette.text,
                      tooltip: value.isPlaying
                          ? l10n.videoPause
                          : l10n.videoPlay,
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: () => value.isPlaying
                          ? controller.pause()
                          : controller.play(),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
