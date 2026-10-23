import 'dart:math';

import 'package:flutter/services.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';

/// What the system prompt says, in the person's language.
typedef BiometricWords = ({String title, String subtitle, String cancel});

/// The [PasskeyPrf] port on Android: the fingerprint (or face) instead of
/// a WebAuthn passkey. `BiometricKeys.kt` keeps an HMAC-SHA256 key per
/// enrollment in the Android Keystore that only a strong biometric,
/// confirmed in the system prompt each time, lets compute; the HMAC of the
/// slot's salt is the PRF output, and it enters libsodium memory at once.
///
/// The output crosses the platform channel as a byte array, which is
/// zeroed here but may have been copied by the channel's codec on the
/// way: as on the web, the guarantee is weaker than libsodium's own
/// memory.
final class AndroidBiometricPrf implements PasskeyPrf {
  AndroidBiometricPrf(
    this._sodium, {
    required this._words,
    Random? random,
    this._channel = defaultChannel,
  }) : _random = random ?? Random.secure();

  static const defaultChannel = MethodChannel('run.serv.modus/biometric');

  /// The Keystore names this class makes; `BiometricKeys.kt` refuses any
  /// other.
  static const aliasPrefix = 'modus-vault-';
  static const _outputLength = 32;

  final SodiumSumo _sodium;
  final BiometricWords Function() _words;
  final Random _random;
  final MethodChannel _channel;

  /// Whether the phone can do it at all: Android 11 or later, with a
  /// strong biometric sensor (a finger need not be enrolled yet).
  static Future<bool> isSupported({
    MethodChannel channel = defaultChannel,
  }) async {
    try {
      return await channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<RegisteredPasskey> register({required PrfSalt salt}) async {
    final credential = PasskeyCredentialId.fromBytes(
      List.generate(16, (_) => _random.nextInt(256)),
    );
    await _call('create', {'alias': _alias(credential)});
    try {
      // The key always comes from a use of the new key, as on the web.
      return RegisteredPasskey(
        credential: credential,
        key: await evaluate(credential, salt: salt),
      );
    } catch (_) {
      await forget(credential);
      rethrow;
    }
  }

  @override
  Future<SymmetricKey> evaluate(
    PasskeyCredentialId credential, {
    required PrfSalt salt,
  }) async {
    final words = _words();
    final output = await _call('evaluate', {
      'alias': _alias(credential),
      'salt': Uint8List.fromList(salt.bytes),
      'title': words.title,
      'subtitle': words.subtitle,
      'cancel': words.cancel,
    });
    if (output is! Uint8List) throw const PasskeyUnsupportedException();
    try {
      if (output.length != _outputLength) {
        throw const PasskeyUnsupportedException();
      }
      return SodiumSymmetricKey.wrap(_sodium.secureCopy(output));
    } finally {
      output.fillRange(0, output.length, 0);
    }
  }

  @override
  Future<void> forget(PasskeyCredentialId credential) async {
    try {
      await _channel.invokeMethod<void>('forget', {
        'alias': _alias(credential),
      });
    } on PlatformException {
      // Best effort, as the port says.
    } on MissingPluginException {
      // Nothing to forget where there is no Keystore.
    }
  }

  static String _alias(PasskeyCredentialId credential) =>
      aliasPrefix +
      credential.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The prompt's outcomes become the port's exceptions; the platform's
  /// message never escapes.
  Future<Object?> _call(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw switch (e.code) {
        'cancelled' => const PasskeyCancelledException(),
        // A finger added since, or the key deleted: it opens nothing.
        'invalidated' || 'missing' => const PasskeyRejectedException(),
        _ => const PasskeyUnsupportedException(),
      };
    } on MissingPluginException {
      throw const PasskeyUnsupportedException();
    }
  }
}
