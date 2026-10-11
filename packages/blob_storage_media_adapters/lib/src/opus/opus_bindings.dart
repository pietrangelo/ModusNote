/// Minimal FFI surface of libopus (built by `hook/build.dart`).
@DefaultAsset('package:blob_storage_media_adapters/src/opus/opus_bindings.dart')
library;

import 'dart:ffi';

final class OpusEncoderHandle extends Opaque {}

final class OpusDecoderHandle extends Opaque {}

const opusOk = 0;
const opusApplicationVoip = 2048;

@Native<Pointer<OpusEncoderHandle> Function(Int32, Int, Int, Pointer<Int>)>(
  symbol: 'opus_encoder_create',
)
external Pointer<OpusEncoderHandle> opusEncoderCreate(
  int sampleRate,
  int channels,
  int application,
  Pointer<Int> error,
);

@Native<
  Int32 Function(
    Pointer<OpusEncoderHandle>,
    Pointer<Int16>,
    Int,
    Pointer<Uint8>,
    Int32,
  )
>(symbol: 'opus_encode')
external int opusEncode(
  Pointer<OpusEncoderHandle> encoder,
  Pointer<Int16> pcm,
  int frameSize,
  Pointer<Uint8> data,
  int maxDataBytes,
);

@Native<Void Function(Pointer<OpusEncoderHandle>)>(
  symbol: 'opus_encoder_destroy',
)
external void opusEncoderDestroy(Pointer<OpusEncoderHandle> encoder);

@Native<Int Function(Pointer<OpusEncoderHandle>, Int32)>(
  symbol: 'modusnote_opus_set_bitrate',
)
external int modusnoteOpusSetBitrate(
  Pointer<OpusEncoderHandle> encoder,
  int bitrate,
);

@Native<Int Function(Pointer<OpusEncoderHandle>)>(
  symbol: 'modusnote_opus_set_signal_voice',
)
external int modusnoteOpusSetSignalVoice(Pointer<OpusEncoderHandle> encoder);

@Native<Int Function(Pointer<OpusEncoderHandle>, Pointer<Int32>)>(
  symbol: 'modusnote_opus_get_lookahead',
)
external int modusnoteOpusGetLookahead(
  Pointer<OpusEncoderHandle> encoder,
  Pointer<Int32> samples,
);

@Native<Pointer<OpusDecoderHandle> Function(Int32, Int, Pointer<Int>)>(
  symbol: 'opus_decoder_create',
)
external Pointer<OpusDecoderHandle> opusDecoderCreate(
  int sampleRate,
  int channels,
  Pointer<Int> error,
);

@Native<
  Int Function(
    Pointer<OpusDecoderHandle>,
    Pointer<Uint8>,
    Int32,
    Pointer<Int16>,
    Int,
    Int,
  )
>(symbol: 'opus_decode')
external int opusDecode(
  Pointer<OpusDecoderHandle> decoder,
  Pointer<Uint8> data,
  int length,
  Pointer<Int16> pcm,
  int frameSize,
  int decodeFec,
);

@Native<Void Function(Pointer<OpusDecoderHandle>)>(
  symbol: 'opus_decoder_destroy',
)
external void opusDecoderDestroy(Pointer<OpusDecoderHandle> decoder);
