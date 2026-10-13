/// Where the vault syncs, fixed at build time:
/// `--dart-define=MODUSNOTE_SUPABASE_URL=https://<project>.supabase.co` and
/// `--dart-define=MODUSNOTE_SUPABASE_ANON_KEY=<public anon key>`. A build
/// without them has no account and keeps every edit queued on the device.
///
/// The anon key is public (Row Level Security does the guarding), so it
/// may live in the bundle; nothing secret is ever configured here.
final class SyncConfig {
  const SyncConfig._(this.projectUrl, this.anonKey);

  final Uri projectUrl;
  final String anonKey;

  static SyncConfig? fromEnvironment() => parse(
    url: const String.fromEnvironment('MODUSNOTE_SUPABASE_URL'),
    anonKey: const String.fromEnvironment('MODUSNOTE_SUPABASE_ANON_KEY'),
  );

  /// Null when either value is missing. Tokens travel only over HTTPS;
  /// plain HTTP is allowed for a local Supabase on this machine.
  static SyncConfig? parse({required String url, required String anonKey}) {
    if (url.isEmpty || anonKey.isEmpty) return null;
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
      throw ArgumentError.value(url, 'url', 'not a Supabase project URL');
    }
    return SyncConfig._(uri.replace(path: '/'), anonKey);
  }
}
