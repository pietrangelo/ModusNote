import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:offline_sync/offline_sync.dart';

/// Plays decoded audio from memory. The app's own port: the engine behind
/// it (flutter_soloud on devices, a fake in tests) never sees a file.
abstract interface class RecordingPlayer {
  Future<LoadedSound> load(DecodedAudio audio);
}

/// A recording loaded into the player, ready to play from any point.
abstract interface class LoadedSound {
  Duration get length;

  /// Where playback is, or would resume; back to zero once it has ended.
  Duration get position;

  bool get playing;

  Future<void> play();

  void pause();

  void seek(Duration position);

  /// Frees the samples held by the player.
  Future<void> dispose();
}

/// A recording ready on screen: its outline and the sound to play.
final class OpenedRecording {
  OpenedRecording({required this.waveform, required this.sound});

  final Waveform waveform;
  final LoadedSound sound;
}

/// Opens the recordings of the vault's notes for listening: decrypts each
/// with the GroupKey of the epoch it was sealed under, decodes it in
/// memory and loads it into the player.
final class NotePlayback {
  NotePlayback({
    required this._decoding,
    required this._engine,
    required this._player,
    this._ensureLocal,
  });

  /// Bars in a waveform: a Fibonacci number, like every count on screen.
  static const waveformBars = 55;

  final RecordingPlayback _decoding;
  final SyncEngine _engine;
  final RecordingPlayer _player;

  /// Downloads a recording this device does not have yet; null where there
  /// is no shared storage.
  final Future<void> Function(KeyedRecording take)? _ensureLocal;

  bool canPlay(KeyedRecording take) => _decoding.canPlay(take.metadata.format);

  Future<OpenedRecording> open(KeyedRecording take) async {
    await _ensureLocal?.call(take);
    final audio = await _decoding.open(
      take.metadata,
      contentKey: _engine.contentKeyFor(take.epoch),
    );
    return OpenedRecording(
      waveform: Waveform.of(audio, buckets: waveformBars),
      sound: await _player.load(audio),
    );
  }
}
