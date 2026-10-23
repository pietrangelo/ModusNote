/// Where the vault syncs: our Worker (`server/`), which also serves the
/// web client. A native build names it with
/// `--dart-define=MODUSNOTE_SERVER=https://modus.serv.run`; the web client
/// without it talks to the origin that served it. A build with neither has
/// no sync and keeps every edit queued on the device.
///
/// Nothing secret is configured here: each device signs its own requests.
final class SyncConfig {
  const SyncConfig._(this.origin);

  /// The server's origin, without a path.
  final Uri origin;

  /// The server the build names, else [page] (the web client's origin).
  static SyncConfig? fromEnvironment({Uri? page}) {
    const named = String.fromEnvironment('MODUSNOTE_SERVER');
    if (named.isNotEmpty) return parse(named);
    return page == null ? null : parse(page.origin);
  }

  /// Null when [url] is empty. Requests travel only over HTTPS; plain HTTP
  /// is allowed for a server on this machine (`wrangler dev`).
  static SyncConfig? parse(String url) {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final local =
        uri != null &&
        uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
    if (uri == null ||
        !(uri.scheme == 'https' || local) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(url, 'url', 'not a server origin');
    }
    return SyncConfig._(uri.replace(path: ''));
  }
}
