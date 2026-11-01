/// A decrypted video handed to the platform's player, and taken back.
///
/// The players of Android and iOS read only files or the network: on a
/// phone the clip is written to a file of its own in the app's private
/// cache, overwritten and deleted when the player closes, and the folder
/// is emptied when the vault opens, in case the app was stopped while one
/// played. In a browser it stays in memory, behind an object URL revoked
/// on close.
library;

export 'playable_video_io.dart'
    if (dart.library.js_interop) 'playable_video_web.dart';
