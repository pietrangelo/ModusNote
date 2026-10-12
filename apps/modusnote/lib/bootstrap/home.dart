import 'package:flutter/widgets.dart';

import 'home_stub.dart'
    if (dart.library.io) 'home_native.dart'
    if (dart.library.js_interop) 'home_web.dart'
    as platform;

/// The first screen, wired for the platform: the encrypted vault, on a
/// SQLite file on mobile and in IndexedDB on the web.
Future<Widget> buildHome() => platform.buildHome();
