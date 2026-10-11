import 'dart:async';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'note_recorder.dart';

/// The sheet shown while a take is recorded: elapsed time, stop to attach,
/// discard to throw it away. Dismissing it any other way discards too.
class RecordingSheet extends StatefulWidget {
  const RecordingSheet({required this.recorder, super.key});

  final NoteRecorder recorder;

  /// The take, or null when it was discarded or could not be recorded.
  static Future<KeyedRecording?> show(
    BuildContext context,
    NoteRecorder recorder,
  ) => showModalBottomSheet<KeyedRecording>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => RecordingSheet(recorder: recorder),
  );

  @override
  State<RecordingSheet> createState() => _RecordingSheetState();
}

enum _Failure { denied, failed }

class _RecordingSheetState extends State<RecordingSheet> {
  RecordingTake? _take;
  _Failure? _failure;
  var _finishing = false;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final take = await widget.recorder.start();
      if (!mounted) {
        await take.cancel();
        return;
      }
      setState(() => _take = take);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } on MicrophonePermissionDeniedException {
      if (mounted) setState(() => _failure = _Failure.denied);
    } on Object {
      if (mounted) setState(() => _failure = _Failure.failed);
    }
  }

  Future<void> _finish({required bool keep}) async {
    final take = _take;
    if (take == null || _finishing) return;
    setState(() => _finishing = true);
    _ticker?.cancel();
    final navigator = Navigator.of(context);
    try {
      if (keep) {
        navigator.pop(await take.stop());
      } else {
        await take.cancel();
        navigator.pop();
      }
    } on Object {
      if (mounted) {
        setState(() {
          _failure = _Failure.failed;
          _finishing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final failure = switch (_failure) {
      null => null,
      _Failure.denied => l10n.microphoneDenied,
      _Failure.failed => l10n.recordingFailed,
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              failure == null ? Icons.mic : Icons.mic_off,
              size: IconSizes.prominent,
              color: ModusColors.rhythmVioletText,
            ),
            const SizedBox(height: Spacing.m),
            if (failure != null) ...[
              Text(
                failure,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.l),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.close),
              ),
            ] else ...[
              Text(
                l10n.recordingInProgress,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.s),
              Text(
                formatLength(_elapsed),
                key: const ValueKey('recording-elapsed'),
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.s),
              Text(
                l10n.recordingEncrypted,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ModusColors.dustSilver,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.l),
              FilledButton.icon(
                icon: const Icon(Icons.stop),
                label: Text(l10n.stopRecording),
                onPressed: _take == null || _finishing
                    ? null
                    : () => _finish(keep: true),
              ),
              const SizedBox(height: Spacing.s),
              TextButton(
                onPressed: _take == null || _finishing
                    ? null
                    : () => _finish(keep: false),
                child: Text(l10n.cancelRecording),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `m:ss`, the way a length is read aloud in every supported language.
String formatLength(Duration length) {
  final seconds = length.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
