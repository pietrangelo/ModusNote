import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:web/web.dart' as web;

import '../sodium_secrets.dart';

/// [PasskeyPrf] on WebAuthn with the `prf` extension, for the browser.
///
/// The passkey belongs to our origin (the relying party is the page's own
/// domain) and is always used with user verification, so every evaluation
/// asks for a fingerprint, a face or a PIN; CTAP2 `hmac-secret` also keeps
/// a separate secret for verified use, which is the one we get.
///
/// There is no server to verify the ceremony: the challenge is random and
/// unused, attestation is not requested, and the user handle is random, so
/// the passkey manager learns nothing about the vault. The PRF output is
/// moved into a libsodium key and the browser's buffer is zeroed at once.
final class WebAuthnPasskeyPrf implements PasskeyPrf {
  WebAuthnPasskeyPrf(
    this._sodium, {
    this.name = 'Modus Notes',
    this.timeout = const Duration(minutes: 2),
  });

  final SodiumSumo _sodium;

  /// Shown by the passkey manager as the relying party and the account.
  final String name;
  final Duration timeout;

  static const _prfLength = 32;

  /// Ed25519, P-256, RSA: what common authenticators offer, best first.
  static const _algorithms = [-8, -7, -257];

  /// Whether this browser has WebAuthn in a secure context and does not
  /// rule out PRF. Browsers that cannot report PRF support are given the
  /// benefit of the doubt: registering then fails with
  /// [PasskeyUnsupportedException].
  static Future<bool> isSupported() async {
    if (!web.window.isSecureContext ||
        !globalContext.has('PublicKeyCredential')) {
      return false;
    }
    final credentials = globalContext['PublicKeyCredential']! as JSObject;
    if (!credentials.has('getClientCapabilities')) return true;
    try {
      final capabilities = await credentials
          .callMethod<JSPromise<JSObject>>('getClientCapabilities'.toJS)
          .toDart;
      final prf = capabilities['extension:prf'];
      return prf == null || !prf.isA<JSBoolean>() || (prf as JSBoolean).toDart;
    } on Object {
      return true;
    }
  }

  @override
  Future<RegisteredPasskey> register({required PrfSalt salt}) async {
    final options = web.CredentialCreationOptions(
      publicKey: web.PublicKeyCredentialCreationOptions(
        rp: web.PublicKeyCredentialRpEntity(name: name),
        user: web.PublicKeyCredentialUserEntity(
          name: name,
          displayName: name,
          id: _random(16),
        ),
        challenge: _random(32),
        pubKeyCredParams: [
          for (final algorithm in _algorithms)
            web.PublicKeyCredentialParameters(
              type: 'public-key',
              alg: algorithm,
            ),
        ].toJS,
        timeout: timeout.inMilliseconds,
        authenticatorSelection: web.AuthenticatorSelectionCriteria(
          residentKey: 'preferred',
          userVerification: 'required',
        ),
        attestation: 'none',
        extensions: _prfInput(salt),
      ),
    );
    final created = await _ceremony(
      web.window.navigator.credentials.create(options),
    );
    final credential = PasskeyCredentialId.fromBytes(
      created.rawId.toDart.asUint8List(),
    );
    final prf = _prfOutput(created);
    if (prf.output case final output?) {
      return RegisteredPasskey(credential: credential, key: _keyFrom(output));
    }
    if (!prf.enabled) {
      await forget(credential);
      throw const PasskeyUnsupportedException();
    }
    // Most authenticators evaluate the PRF only on an assertion: ask once
    // more, for the passkey just made.
    try {
      return RegisteredPasskey(
        credential: credential,
        key: await evaluate(credential, salt: salt),
      );
    } on PasskeyUnsupportedException {
      await forget(credential);
      rethrow;
    }
  }

  @override
  Future<SymmetricKey> evaluate(
    PasskeyCredentialId credential, {
    required PrfSalt salt,
  }) async {
    final options = web.CredentialRequestOptions(
      publicKey: web.PublicKeyCredentialRequestOptions(
        challenge: _random(32),
        timeout: timeout.inMilliseconds,
        allowCredentials: [
          web.PublicKeyCredentialDescriptor(
            type: 'public-key',
            id: credential.bytes.toJS,
          ),
        ].toJS,
        userVerification: 'required',
        extensions: _prfInput(salt),
      ),
    );
    final asserted = await _ceremony(
      web.window.navigator.credentials.get(options),
    );
    final output = _prfOutput(asserted).output;
    // Only the passkey we named may answer; anything else is not ours.
    if (output == null ||
        PasskeyCredentialId.fromBytes(asserted.rawId.toDart.asUint8List()) !=
            credential) {
      if (output != null) _wipe(output);
      throw const PasskeyUnsupportedException();
    }
    return _keyFrom(output);
  }

  @override
  Future<void> forget(PasskeyCredentialId credential) async {
    try {
      final credentials = globalContext['PublicKeyCredential']! as JSObject;
      if (!credentials.has('signalUnknownCredential')) return;
      final options = JSObject()
        ..['rpId'] = web.window.location.hostname.toJS
        ..['credentialId'] = base64Url
            .encode(credential.bytes)
            .replaceAll('=', '')
            .toJS;
      await credentials
          .callMethod<JSPromise<JSAny?>>(
            'signalUnknownCredential'.toJS,
            options,
          )
          .toDart;
    } on Object {
      // Best effort: the passkey manager keeps offering a passkey that no
      // longer opens anything, which is harmless.
    }
  }

  /// Public randomness (challenge, user handle) straight from the browser.
  static JSUint8Array _random(int length) =>
      web.window.crypto.getRandomValues(JSUint8Array.withLength(length))
          as JSUint8Array;

  static web.AuthenticationExtensionsClientInputs _prfInput(PrfSalt salt) =>
      web.AuthenticationExtensionsClientInputs(
        prf: web.AuthenticationExtensionsPRFInputs(
          eval: web.AuthenticationExtensionsPRFValues(first: salt.bytes.toJS),
        ),
      );

  /// Whether the passkey has a PRF at all, and its output if one came.
  static ({bool enabled, JSArrayBuffer? output}) _prfOutput(
    web.PublicKeyCredential credential,
  ) {
    final results = credential.getClientExtensionResults();
    if (!results.has('prf')) return (enabled: false, output: null);
    final prf = results['prf']! as JSObject;
    final enabled = prf['enabled'];
    JSArrayBuffer? output;
    final values = prf['results'];
    if (values != null && values.isA<JSObject>()) {
      final first = (values as JSObject)['first'];
      if (first != null && first.isA<JSArrayBuffer>()) {
        output = first as JSArrayBuffer;
      }
    }
    return (
      // Absent means "not reported", as on assertions; only false rules
      // the PRF out.
      enabled:
          output != null ||
          enabled == null ||
          !enabled.isA<JSBoolean>() ||
          (enabled as JSBoolean).toDart,
      output: output,
    );
  }

  /// Moves the PRF output into libsodium memory and zeroes it in the
  /// browser, where the extension results would otherwise keep it.
  SymmetricKey _keyFrom(JSArrayBuffer output) {
    final bytes = JSUint8Array(output).toDart;
    try {
      if (bytes.length != _prfLength) {
        throw const PasskeyUnsupportedException();
      }
      return SodiumSymmetricKey.wrap(_sodium.secureCopy(bytes));
    } finally {
      // Under WebAssembly `toDart` is a copy: wipe both.
      bytes.fillRange(0, bytes.length, 0);
      _wipe(output);
    }
  }

  static void _wipe(JSArrayBuffer buffer) =>
      JSUint8Array(buffer).callMethod<JSAny?>('fill'.toJS, 0.toJS);

  /// Runs a WebAuthn request; a dismissed or timed-out prompt becomes
  /// [PasskeyCancelledException], anything else that stops it
  /// [PasskeyUnsupportedException]. The browser's message never escapes.
  static Future<web.PublicKeyCredential> _ceremony(
    JSPromise<web.Credential?> request,
  ) {
    final settled = Completer<web.PublicKeyCredential>();
    request.then(
      ((web.Credential? credential) {
        if (credential == null) {
          settled.completeError(const PasskeyCancelledException());
        } else if (!credential.has('rawId')) {
          settled.completeError(const PasskeyUnsupportedException());
        } else {
          settled.complete(credential as web.PublicKeyCredential);
        }
      }).toJS,
      ((JSAny? error) {
        final name = error != null && error.isA<web.DOMException>()
            ? (error as web.DOMException).name
            : null;
        settled.completeError(
          name == 'NotAllowedError' || name == 'AbortError'
              ? const PasskeyCancelledException()
              : const PasskeyUnsupportedException(),
        );
      }).toJS,
    );
    return settled.future;
  }
}

extension on JSPromise<web.Credential?> {
  external void then(JSFunction onFulfilled, JSFunction onRejected);
}
