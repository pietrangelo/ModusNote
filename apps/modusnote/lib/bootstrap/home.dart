import 'package:flutter/widgets.dart';

import 'home_stub.dart'
    if (dart.library.io) 'home_native.dart'
    if (dart.library.js_interop) 'home_web.dart'
    as platform;

/// The first screen, wired for the platform: the encrypted vault on mobile,
/// an in-memory preview on the web until its client lands (Fase 7).
Future<Widget> buildHome() => platform.buildHome();
