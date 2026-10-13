import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:offline_sync/offline_sync.dart';

/// Supabase Auth refused the request: a wrong or expired code, a refresh
/// token that was revoked, too many attempts (429). [status] is the HTTP
/// status; the response body, which may echo tokens, is never kept.
final class SupabaseAuthRejectedException implements Exception {
  const SupabaseAuthRejectedException(this.status);

  final int status;

  @override
  String toString() => 'SupabaseAuthRejectedException: HTTP $status';
}

/// A signed-in Supabase account. The account only opens rows on the server,
/// which hold nothing but ciphertext; the vault's keys are separate and
/// never involved. Its tokens are still credentials: [toString] hides them
/// and the app keeps the session sealed inside the vault.
@immutable
final class SupabaseSession {
  const SupabaseSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// The account's id, as Row Level Security sees it (`auth.uid()`).
  final String userId;
  final String email;

  Uint8List toBytes() => utf8.encode(
    jsonEncode({
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt.toUtc().millisecondsSinceEpoch,
      'user_id': userId,
      'email': email,
    }),
  );

  /// The session stored by [toBytes], or null for anything else: a damaged
  /// value means signing in again, never a crash.
  static SupabaseSession? fromBytes(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json case {
        'access_token': final String access,
        'refresh_token': final String refresh,
        'expires_at': final int expiresAt,
        'user_id': final String userId,
        'email': final String email,
      }) {
        return SupabaseSession(
          accessToken: access,
          refreshToken: refresh,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            expiresAt,
            isUtc: true,
          ),
          userId: userId,
          email: email,
        );
      }
    } on FormatException {
      // Not ours.
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SupabaseSession &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt.isAtSameMomentAs(expiresAt) &&
      other.userId == userId &&
      other.email == email;

  @override
  int get hashCode => Object.hash(
    accessToken,
    refreshToken,
    expiresAt.millisecondsSinceEpoch,
    userId,
    email,
  );

  @override
  String toString() => 'SupabaseSession(redacted)';
}

/// The few Supabase Auth (GoTrue) calls the app needs, over `package:http`
/// like [SupabaseSyncServer]: a six-digit code sent by email, so signing in
/// needs no link to open and works the same on phones and in the browser.
///
/// The email carries the code when the project's "Magic Link" and "Confirm
/// signup" templates include `{{ .Token }}`; with the default templates it
/// carries only a link, which [verifyCode] also accepts.
final class SupabaseAuth {
  SupabaseAuth({
    required Uri projectUrl,
    required this._anonKey,
    http.Client? client,
    DateTime Function()? clock,
    this._timeout = const Duration(seconds: 30),
  }) : _auth = projectUrl.resolve('/auth/v1/'),
       _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final Uri _auth;
  final String _anonKey;
  final http.Client _client;
  final DateTime Function() _clock;
  final Duration _timeout;

  /// Emails a one-time code, creating the account on first use.
  Future<void> sendCode(String email) async {
    await _post('otp', {'email': email, 'create_user': true});
  }

  /// Signs in with what the email carried: the six-digit code, or the
  /// sign-in link pasted whole, for projects whose email template cannot
  /// show the code (Supabase's free plan keeps the default, link-only one).
  /// A link is never opened: only its token hash is sent back to this
  /// project, and a link to any other host, path or purpose is refused
  /// before any request.
  Future<SupabaseSession> verifyCode(String email, String code) async {
    final link = Uri.tryParse(code.trim());
    if (link == null || !link.hasScheme) {
      return _session(
        await _post('verify', {'type': 'email', 'email': email, 'token': code}),
      );
    }
    final token = link.queryParameters['token'] ?? '';
    final type = link.queryParameters['type'];
    if (link.scheme != 'https' ||
        link.host != _auth.host ||
        link.hasPort && link.port != _auth.port ||
        link.userInfo.isNotEmpty ||
        link.path != _auth.resolve('verify').path ||
        !_tokenHash.hasMatch(token) ||
        !_linkTypes.contains(type)) {
      throw const SupabaseAuthRejectedException(400);
    }
    return _session(await _post('verify', {'type': type, 'token_hash': token}));
  }

  /// Sign-in links only: a new account's confirmation or a returning
  /// account's magic link. Recovery, invites and email changes stay out.
  static const _linkTypes = {'magiclink', 'signup'};

  /// GoTrue's token hash: SHA-224 of the email and the code, in hex.
  static final _tokenHash = RegExp(r'^[0-9a-f]{56}$');

  Future<SupabaseSession> refresh(SupabaseSession session) async => _session(
    await _post(
      'token',
      {'refresh_token': session.refreshToken},
      query: {'grant_type': 'refresh_token'},
    ),
  );

  /// Revokes the session's refresh token on the server.
  Future<void> signOut(SupabaseSession session) async {
    await _post('logout', const {}, bearer: session.accessToken);
  }

  SupabaseSession _session(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const MalformedSyncDataException('auth response is not JSON');
    }
    if (json
        case {
          'access_token': final String access,
          'refresh_token': final String refresh,
          'expires_in': final int expiresIn,
          'user': {'id': final String userId, 'email': final String email},
        }
        when expiresIn > 0 && access.isNotEmpty && refresh.isNotEmpty) {
      return SupabaseSession(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: _clock().toUtc().add(Duration(seconds: expiresIn)),
        userId: userId,
        email: email,
      );
    }
    throw const MalformedSyncDataException('malformed auth session');
  }

  Future<String> _post(
    String path,
    Map<String, Object?> body, {
    Map<String, String>? query,
    String? bearer,
  }) async {
    final request =
        http.Request(
            'POST',
            _auth.resolve(path).replace(queryParameters: query),
          )
          ..headers['apikey'] = _anonKey
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
    if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on http.ClientException {
      throw const ServerUnavailableException();
    } on TimeoutException {
      throw const ServerUnavailableException();
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) return response.body;
    if (status >= 500 || status == 408) {
      throw const ServerUnavailableException();
    }
    throw SupabaseAuthRejectedException(status);
  }
}

/// The sync account of an open vault: the session restored from the vault
/// on unlock, renewed before it expires, stored back sealed, and dropped
/// from memory on lock.
///
/// [accessToken] is the token callback of [SupabaseSyncServer]: without a
/// usable session it throws [ServerUnavailableException], so the sync engine
/// simply stays offline and keeps its queue, as with no network.
final class SyncAccount {
  SyncAccount(this._auth, {DateTime Function()? clock, this.onChanged})
    : _clock = clock ?? DateTime.now;

  final SupabaseAuth _auth;
  final DateTime Function() _clock;

  /// Called whenever the account signs in or out.
  void Function()? onChanged;

  /// Renew this long before expiry, so a token never lapses mid-request.
  static const _margin = Duration(minutes: 1);

  SupabaseSession? _session;
  Future<void> Function(SupabaseSession?)? _persist;
  Future<String>? _refreshing;

  bool get signedIn => _session != null;

  String? get email => _session?.email;

  /// Binds the account to an open vault: [restored] is the session the
  /// vault held, [persist] seals a new one (or null) back into it.
  void attach(
    SupabaseSession? restored, {
    required Future<void> Function(SupabaseSession?) persist,
  }) {
    _session = restored;
    _persist = persist;
    _refreshing = null;
    onChanged?.call();
  }

  /// The vault locked: nothing of the session stays in this object.
  void detach() {
    _session = null;
    _persist = null;
    _refreshing = null;
    onChanged?.call();
  }

  Future<void> sendCode(String email) => _auth.sendCode(email);

  Future<void> signIn(String email, String code) async {
    final session = await _auth.verifyCode(email, code);
    await _store(session);
  }

  Future<void> signOut() async {
    final session = _session;
    await _store(null);
    if (session == null) return;
    try {
      await _auth.signOut(session);
    } on Object {
      // Forgotten here either way; the server lets the token expire.
    }
  }

  Future<String> accessToken() {
    final session = _session;
    if (session == null) {
      return Future.error(const ServerUnavailableException());
    }
    if (_clock().toUtc().add(_margin).isBefore(session.expiresAt)) {
      return Future.value(session.accessToken);
    }
    return _refreshing ??= _refresh(session)
        .whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh(SupabaseSession session) async {
    final SupabaseSession renewed;
    try {
      renewed = await _auth.refresh(session);
    } on SupabaseAuthRejectedException {
      // Revoked or expired for good: the user signs in again.
      if (identical(_session, session)) await _store(null);
      throw const ServerUnavailableException();
    }
    if (!identical(_session, session)) {
      throw const ServerUnavailableException();
    }
    await _store(renewed);
    return renewed.accessToken;
  }

  Future<void> _store(SupabaseSession? session) async {
    final changed = (_session == null) != (session == null);
    _session = session;
    await _persist?.call(session);
    if (changed) onChanged?.call();
  }
}
