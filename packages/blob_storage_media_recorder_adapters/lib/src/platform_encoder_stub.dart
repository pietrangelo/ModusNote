import 'package:blob_storage_media_adapters/audio_encoding.dart';

AudioStreamEncoder platformEncoder() =>
    throw UnsupportedError('no audio encoder for this platform');
