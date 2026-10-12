import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:web/web.dart' as web;

import 'note_playback.dart';

/// [RecordingPlayer] on the Web Audio API, for the browser.
///
/// The decoded samples stay in Dart memory as 16-bit PCM; only the few
/// seconds about to play are expanded into an `AudioBuffer`, one segment
/// at a time, so a long recording never sits in the browser as 32-bit
/// floats. Nothing goes through a URL, a media element or a file.
final class WebAudioRecordingPlayer implements RecordingPlayer {
  /// The audio context starts on the first recording played, not at load:
  /// browsers only let it run after a tap anyway.
  web.AudioContext? _context;

  @override
  Future<LoadedSound> load(DecodedAudio audio) async =>
      _WebAudioSound(_context ??= web.AudioContext(), audio);
}

final class _WebAudioSound implements LoadedSound {
  _WebAudioSound(this._context, DecodedAudio audio)
    : _audio = audio,
      length = audio.duration;

  /// Seconds per scheduled segment; one is always queued behind the one
  /// playing, so playback never waits on Dart.
  static const _segmentSeconds = 5;

  /// Lead time before the first segment, so its start is never already in
  /// the past when the browser gets it.
  static const _lead = 0.02;

  final web.AudioContext _context;
  DecodedAudio? _audio;
  final _sources = <web.AudioBufferSourceNode>[];

  /// Bumped on every pause, seek and dispose: callbacks from older
  /// segments then know they are stale.
  var _generation = 0;
  var _playing = false;
  var _resumeAt = Duration.zero;

  /// Context time at which [_firstSample] plays.
  var _startedAt = 0.0;
  var _firstSample = 0;
  var _nextSample = 0;

  @override
  final Duration length;

  @override
  bool get playing => _playing;

  @override
  Duration get position {
    final audio = _audio;
    if (!_playing || audio == null) return _resumeAt;
    final elapsed = max(0.0, _context.currentTime - _startedAt);
    final played = Duration(
      microseconds:
          _firstSample * Duration.microsecondsPerSecond ~/ audio.sampleRate +
          (elapsed * Duration.microsecondsPerSecond).round(),
    );
    return played < length ? played : length;
  }

  @override
  Future<void> play() async {
    final audio = _audio;
    if (_playing || audio == null) return;
    _playing = true;
    final generation = ++_generation;
    // Called from the tap that asked for it, as browsers require.
    await _context.resume().toDart;
    if (generation != _generation) return;
    final from = _resumeAt < length ? _resumeAt : Duration.zero;
    _firstSample = min(
      from.inMicroseconds * audio.sampleRate ~/ Duration.microsecondsPerSecond,
      audio.samples.length,
    );
    _nextSample = _firstSample;
    _startedAt = _context.currentTime + _lead;
    _schedule(generation);
    _schedule(generation);
  }

  @override
  void pause() {
    if (!_playing) return;
    _resumeAt = position;
    _halt();
  }

  @override
  void seek(Duration position) {
    final target = position < Duration.zero
        ? Duration.zero
        : (position > length ? length : position);
    if (_playing) {
      _halt();
      _resumeAt = target;
      play();
    } else {
      _resumeAt = target;
    }
  }

  @override
  Future<void> dispose() async {
    _halt();
    _audio = null;
  }

  void _schedule(int generation) {
    final audio = _audio;
    if (generation != _generation || audio == null) return;
    final samples = audio.samples;
    if (_nextSample >= samples.length) {
      if (_sources.isEmpty) _ended();
      return;
    }
    final start = _nextSample;
    final end = min(start + _segmentSeconds * audio.sampleRate, samples.length);
    final floats = Float32List(end - start);
    for (var i = 0; i < floats.length; i++) {
      floats[i] = samples[start + i] / 32768;
    }
    final buffer = _context.createBuffer(1, floats.length, audio.sampleRate);
    buffer.copyToChannel(floats.toJS, 0);
    final source = _context.createBufferSource()
      ..buffer = buffer
      ..connect(_context.destination);
    final isLast = end == samples.length;
    source.onended = ((web.Event _) {
      _sources.remove(source);
      if (generation != _generation) return;
      if (isLast) {
        _ended();
      } else {
        _schedule(generation);
      }
    }).toJS;
    source.start(_startedAt + (start - _firstSample) / audio.sampleRate);
    _sources.add(source);
    _nextSample = end;
  }

  /// Played to the end: back to the start, as the player view expects.
  void _ended() {
    _halt();
    _resumeAt = Duration.zero;
  }

  void _halt() {
    _generation++;
    _playing = false;
    for (final source in _sources) {
      source
        ..onended = null
        ..stop();
    }
    _sources.clear();
  }
}
