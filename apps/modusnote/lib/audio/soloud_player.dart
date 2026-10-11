import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'note_playback.dart';

/// [RecordingPlayer] on flutter_soloud: the WAV built in memory goes to
/// the engine as a buffer, so no decrypted audio touches the disk.
final class SoloudRecordingPlayer implements RecordingPlayer {
  /// The audio engine starts on the first recording played, not at launch.
  SoloudRecordingPlayer() : _soloud = SoLoud.instance;

  final SoLoud _soloud;
  var _loaded = 0;

  @override
  Future<LoadedSound> load(DecodedAudio audio) async {
    if (!_soloud.isInitialized) await _soloud.init(channels: Channels.mono);
    // `disk` streams from the buffer as it plays instead of expanding the
    // whole recording to 32-bit floats; seeking in WAV stays exact. The
    // name only keys the engine's cache and says nothing about the note.
    final source = await _soloud.loadMem(
      'recording-${_loaded++}.wav',
      audio.toWav(),
      mode: LoadMode.disk,
    );
    return _SoloudSound(_soloud, source, audio.duration);
  }
}

final class _SoloudSound implements LoadedSound {
  _SoloudSound(this._soloud, this._source, this.length);

  final SoLoud _soloud;
  final AudioSource _source;
  SoundHandle? _handle;
  Duration _resumeAt = Duration.zero;

  @override
  final Duration length;

  /// A voice that played to the end is gone: its handle is no longer valid.
  SoundHandle? get _voice => switch (_handle) {
    final handle? when _soloud.getIsValidVoiceHandle(handle) => handle,
    _ => null,
  };

  @override
  Duration get position => switch (_voice) {
    final voice? => _soloud.getPosition(voice),
    null => _resumeAt,
  };

  @override
  bool get playing => switch (_voice) {
    final voice? => !_soloud.getPause(voice),
    null => false,
  };

  @override
  Future<void> play() async {
    if (_voice case final voice?) {
      _soloud.setPause(voice, false);
      return;
    }
    final voice = _handle = _soloud.play(_source, paused: true);
    if (_resumeAt > Duration.zero) _soloud.seek(voice, _resumeAt);
    _resumeAt = Duration.zero;
    _soloud.setPause(voice, false);
  }

  @override
  void pause() {
    if (_voice case final voice?) _soloud.setPause(voice, true);
  }

  @override
  void seek(Duration position) {
    if (_voice case final voice?) {
      _soloud.seek(voice, position);
    } else {
      _resumeAt = position;
    }
  }

  @override
  Future<void> dispose() => _soloud.disposeSource(_source);
}
