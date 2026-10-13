@TestOn('browser')
library;

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/web_passkeys.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

/// No libsodium is loaded in this page; nothing here reaches a key.
final class _NoSodium implements SodiumSumo {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// The ceremony itself needs an authenticator, and headless Chrome without
// one never answers; the app's end-to-end test runs it against Chrome's
// virtual authenticator.
void main() {
  final sodium = _NoSodium();

  test('a secure page in Chrome may offer passkeys', () async {
    expect(await WebAuthnPasskeyPrf.isSupported(), isTrue);
  });

  test('forgetting a passkey never throws', () async {
    await WebAuthnPasskeyPrf(sodium)
        .forget(PasskeyCredentialId.fromBytes(List.filled(16, 2)));
  });
}
