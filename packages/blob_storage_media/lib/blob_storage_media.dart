/// Blob Storage & Media: lifecycle delle registrazioni audio e cifratura a blocchi.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/application/audio_capture.dart';
export 'src/application/audio_recording_session.dart';
export 'src/application/ciphertext_blob_store.dart';
export 'src/application/encrypted_blob_storage.dart';
export 'src/application/recording_playback.dart';
export 'src/core/audio_attachment.dart';
export 'src/core/audio_format.dart';
export 'src/core/blob_exception.dart';
export 'src/core/blob_metadata.dart';
export 'src/core/chunk_layout.dart';
export 'src/core/decoded_audio.dart';
export 'src/core/portable_int64.dart';
export 'src/core/recorded_note.dart';
export 'src/core/recording_state.dart';
