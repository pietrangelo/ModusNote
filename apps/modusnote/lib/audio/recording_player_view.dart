import 'dart:async';
import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'audio_diagnostics.dart';
import 'note_playback.dart';
import 'recording_sheet.dart' show formatLength;

/// Play, pause and scrub a note's recording. Nothing is decrypted until
/// the first tap on play; the samples are freed when the field goes away.
class RecordingPlayerView extends StatefulWidget {
  const RecordingPlayerView({
    required this.open,
    required this.length,
    super.key,
  });

  final Future<OpenedRecording> Function() open;

  /// The length from the recording's metadata, shown before it is opened.
  final Duration length;

  @override
  State<RecordingPlayerView> createState() => _RecordingPlayerViewState();
}

enum _Failure { tooLong, unsupported, missing, offline, damaged }

class _RecordingPlayerViewState extends State<RecordingPlayerView> {
  OpenedRecording? _opened;
  var _opening = false;
  _Failure? _failure;
  Timer? _ticker;
  var _disposed = false;

  /// How often the position redraws while playing: smooth enough for a
  /// bar of a 55-bar outline, cheap enough to leave running.
  static const _frame = Duration(milliseconds: 89);

  Future<void> _toggle() async {
    if (_opening) return;
    final opened = _opened ?? await _openOnce();
    if (opened == null) return;
    final sound = opened.sound;
    if (sound.playing) {
      sound.pause();
      _ticker?.cancel();
    } else {
      await sound.play();
      _ticker?.cancel();
      _ticker = Timer.periodic(_frame, (_) {
        if (!sound.playing) _ticker?.cancel();
        if (mounted) setState(() {});
      });
    }
    if (mounted) setState(() {});
  }

  Future<OpenedRecording?> _openOnce() async {
    setState(() {
      _opening = true;
      _failure = null;
    });
    try {
      final opened = await widget.open();
      if (_disposed) {
        await opened.sound.dispose();
        return null;
      }
      setState(() => _opened = opened);
      return opened;
    } on RecordingTooLongException {
      _fail(_Failure.tooLong);
    } on UnsupportedAudioFormatException {
      _fail(_Failure.unsupported);
    } on BlobNotFoundException {
      _fail(_Failure.missing);
    } on RemoteBlobUnavailableException {
      _fail(_Failure.offline);
    } on Object catch (error, stack) {
      reportAudioFailure('opening a recording', error, stack);
      // A chunk that fails authentication, a container that does not
      // parse, a key the device lacks: none of them is played.
      _fail(_Failure.damaged);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    return null;
  }

  void _fail(_Failure failure) {
    if (mounted) setState(() => _failure = failure);
  }

  void _seek(double fraction, LoadedSound sound) {
    sound.seek(sound.length * fraction.clamp(0.0, 1.0));
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _opened?.sound.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final opened = _opened;
    final playing = opened?.sound.playing ?? false;
    final failure = switch (_failure) {
      null => null,
      _Failure.tooLong => l10n.recordingTooLong,
      _Failure.unsupported => l10n.recordingUnsupported,
      _Failure.missing => l10n.recordingMissing,
      _Failure.offline => l10n.recordingOffline,
      _Failure.damaged => l10n.recordingDamaged,
    };
    return Row(
      children: [
        if (_opening)
          const Padding(
            padding: EdgeInsets.all(Spacing.m),
            child: SizedBox.square(
              dimension: IconSizes.inline,
              child: CircularProgressIndicator(strokeWidth: Spacing.xxs),
            ),
          )
        else
          IconButton(
            icon: Icon(
              playing ? Icons.pause : Icons.play_arrow,
              size: IconSizes.inline,
            ),
            color: ModusColors.rhythmVioletText,
            tooltip: playing ? l10n.pauseRecording : l10n.playRecording,
            onPressed: failure == null ? _toggle : null,
          ),
        const SizedBox(width: Spacing.xs),
        Expanded(
          child: switch ((opened, failure)) {
            (_, final String failure) => Text(
              failure,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            (final OpenedRecording opened, null) => _Scrubber(
              opened: opened,
              onSeek: (fraction) => _seek(fraction, opened.sound),
            ),
            (null, null) => Text(
              l10n.recordingAttachedLength(formatLength(widget.length)),
              style: theme.textTheme.labelMedium,
            ),
          },
        ),
      ],
    );
  }
}

class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.opened, required this.onSeek});

  final OpenedRecording opened;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sound = opened.sound;
    final length = sound.length;
    final position = sound.position;
    final progress = length == Duration.zero
        ? 0.0
        : min(1.0, position.inMicroseconds / length.inMicroseconds);
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              void seekAt(Offset local) =>
                  onSeek(local.dx / constraints.maxWidth);
              return GestureDetector(
                key: const ValueKey('waveform'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => seekAt(details.localPosition),
                onHorizontalDragUpdate: (details) =>
                    seekAt(details.localPosition),
                child: CustomPaint(
                  size: Size(constraints.maxWidth, Spacing.xl),
                  painter: WaveformPainter(
                    peaks: opened.waveform.peaks,
                    progress: progress,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: Spacing.s),
        Text(
          l10n.playbackPosition(formatLength(position), formatLength(length)),
          key: const ValueKey('playback-position'),
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: ModusColors.dustSilver),
        ),
      ],
    );
  }
}

/// One bar per peak, centred; bars already played in the audio violet,
/// the rest in muted silver. Bars take the golden share of their slot.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({required this.peaks, required this.progress});

  final List<double> peaks;

  /// From 0 to 1.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final slot = size.width / peaks.length;
    final played = Paint()
      ..color = ModusColors.rhythmVioletText
      ..strokeWidth = slot * LayoutSplit.primary
      ..strokeCap = StrokeCap.round;
    final ahead = Paint()
      ..color = ModusColors.dustSilver
      ..strokeWidth = played.strokeWidth
      ..strokeCap = StrokeCap.round;
    final middle = size.height / 2;
    // Silence still shows as a dot, so the outline reads as a recording.
    final floor = played.strokeWidth / size.height;
    for (final (index, peak) in peaks.indexed) {
      final x = slot * (index + 0.5);
      final half = max(peak, floor) * middle;
      canvas.drawLine(
        Offset(x, middle - half),
        Offset(x, middle + half),
        (index + 1) / peaks.length <= progress ? played : ahead,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.progress != progress || old.peaks != peaks;
}
