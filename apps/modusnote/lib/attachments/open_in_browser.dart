import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [address] in the browser, outside the app; on the web a new tab
/// that cannot reach back into this one (`noopener`) and is told nothing
/// about where it came from (`noreferrer`). False when nothing could.
Future<bool> openInBrowser(Uri address) async {
  try {
    return await launchUrl(address, mode: LaunchMode.externalApplication);
  } on PlatformException {
    return false;
  }
}
