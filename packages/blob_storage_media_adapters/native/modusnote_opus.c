/*
 * Non-variadic wrappers around opus_encoder_ctl, so Dart never calls a
 * variadic C function through FFI (variadic argument passing differs on
 * Apple arm64 and is easy to get silently wrong).
 */
#include <opus.h>

int modusnote_opus_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate) {
  return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int modusnote_opus_set_signal_voice(OpusEncoder *encoder) {
  return opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int modusnote_opus_get_lookahead(OpusEncoder *encoder, opus_int32 *samples) {
  return opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(samples));
}
