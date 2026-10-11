/// Platform-independent audio pieces (no `dart:io`, no `dart:ffi`), safe
/// to import from web builds: streaming capture, Ogg Opus (de)muxing, WAV.
library;

export 'src/ogg_opus_demuxer.dart';
export 'src/ogg_opus_muxer.dart';
export 'src/streaming_audio_capture.dart';
export 'src/wav_audio_decoder.dart';
