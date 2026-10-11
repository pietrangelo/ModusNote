import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:blob_storage_media_adapters/opus.dart';

AudioStreamEncoder platformEncoder() => OpusStreamEncoder();
