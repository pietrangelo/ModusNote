import 'package:flutter/widgets.dart';

import 'home_stub.dart'
    if (dart.library.io) 'home_native.dart'
    if (dart.library.js_interop) 'home_web.dart'
    as platform;

import '../appearance/theme_memory.dart';

/// The first screen and where the device remembers its theme.
typedef AppHome = ({Widget home, ThemeMemory themes});

/// The first screen, wired for the platform: the encrypted vault, on a
/// SQLite file on mobile and in IndexedDB on the web.
Future<AppHome> buildHome() => platform.buildHome();
