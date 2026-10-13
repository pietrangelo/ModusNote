// The WebCodecs audio interfaces we use, bound by hand: `package:web` 1.1
// has only the video half. Names and shapes follow the W3C WebCodecs spec.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Whether this browser has WebCodecs audio at all (Safari before 26,
/// Firefox before 130, insecure origins do not).
bool get hasWebCodecsAudio =>
    globalContext.has('AudioEncoder') &&
    globalContext.has('AudioDecoder') &&
    globalContext.has('AudioData') &&
    globalContext.has('EncodedAudioChunk');

@JS('AudioEncoder')
extension type JSAudioEncoder._(JSObject _) implements JSObject {
  external JSAudioEncoder(JSAudioEncoderInit init);

  external static JSPromise<JSAudioSupport> isConfigSupported(
    JSAudioEncoderConfig config,
  );

  external String get state;
  external int get encodeQueueSize;
  external void configure(JSAudioEncoderConfig config);
  external void encode(JSAudioData data);
  external JSPromise<JSAny?> flush();
  external void close();
}

extension type JSAudioEncoderInit._(JSObject _) implements JSObject {
  external factory JSAudioEncoderInit({JSFunction output, JSFunction error});
}

extension type JSAudioEncoderConfig._(JSObject _) implements JSObject {
  external factory JSAudioEncoderConfig({
    String codec,
    int sampleRate,
    int numberOfChannels,
    int bitrate,
    JSOpusEncoderConfig opus,
  });
}

extension type JSOpusEncoderConfig._(JSObject _) implements JSObject {
  external factory JSOpusEncoderConfig({
    int frameDuration,
    String application,
    String signal,
  });
}

extension type JSAudioSupport._(JSObject _) implements JSObject {
  external bool get supported;
}

/// The second argument of the encoder's output callback.
extension type JSEncodedAudioChunkMetadata._(JSObject _) implements JSObject {
  external JSAudioDecoderConfig? get decoderConfig;
}

@JS('AudioDecoder')
extension type JSAudioDecoder._(JSObject _) implements JSObject {
  external JSAudioDecoder(JSAudioDecoderInit init);

  external static JSPromise<JSAudioSupport> isConfigSupported(
    JSAudioDecoderConfig config,
  );

  external String get state;
  external int get decodeQueueSize;
  external set ondequeue(JSFunction? handler);
  external void configure(JSAudioDecoderConfig config);
  external void decode(JSEncodedAudioChunk chunk);
  external JSPromise<JSAny?> flush();
  external void close();
}

extension type JSAudioDecoderInit._(JSObject _) implements JSObject {
  external factory JSAudioDecoderInit({JSFunction output, JSFunction error});
}

extension type JSAudioDecoderConfig._(JSObject _) implements JSObject {
  external factory JSAudioDecoderConfig({
    String codec,
    int sampleRate,
    int numberOfChannels,
  });

  /// An `ArrayBuffer` or a view on one; for Opus, the OpusHead.
  external JSObject? get description;
}

@JS('AudioData')
extension type JSAudioData._(JSObject _) implements JSObject {
  external JSAudioData(JSAudioDataInit init);

  external int get numberOfFrames;
  external int get numberOfChannels;
  external int allocationSize(JSAudioDataCopyToOptions options);
  external void copyTo(JSObject destination, JSAudioDataCopyToOptions options);
  external void close();
}

extension type JSAudioDataInit._(JSObject _) implements JSObject {
  external factory JSAudioDataInit({
    String format,
    int sampleRate,
    int numberOfFrames,
    int numberOfChannels,
    int timestamp,
    JSObject data,
  });
}

extension type JSAudioDataCopyToOptions._(JSObject _) implements JSObject {
  external factory JSAudioDataCopyToOptions({int planeIndex, String format});
}

@JS('EncodedAudioChunk')
extension type JSEncodedAudioChunk._(JSObject _) implements JSObject {
  external JSEncodedAudioChunk(JSEncodedAudioChunkInit init);

  external int get byteLength;

  /// Microseconds, or null when the encoder does not say.
  external int? get duration;
  external void copyTo(JSObject destination);
}

extension type JSEncodedAudioChunkInit._(JSObject _) implements JSObject {
  external factory JSEncodedAudioChunkInit({
    String type,
    int timestamp,
    JSObject data,
  });
}

/// `new Uint8Array(source)`: a copy of an `ArrayBuffer`, or of a
/// `Uint8Array` view, as bytes.
@JS('Uint8Array')
extension type JSBytesOf._(JSUint8Array _) implements JSUint8Array {
  external JSBytesOf(JSObject source);
}
