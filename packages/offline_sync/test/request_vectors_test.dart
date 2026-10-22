import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

/// The signed requests the Rust server checks too (server/vectors/
/// requests.json, written by tool/golden_vectors.dart): the device must
/// sign exactly the bytes the server rebuilds, and agree on which
/// signatures verify.
void main() {
  late SodiumIdentityService identities;
  late SodiumContentHasher hasher;

  setUpAll(() async {
    final sodium = await SodiumSumoInit.init();
    identities = SodiumIdentityService(sodium);
    hasher = SodiumContentHasher(sodium);
  });

  final file = File('../../server/vectors/requests.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final cases = (vectors['cases']! as List).cast<Map<String, Object?>>();

  test('there are vectors', () => expect(cases, hasLength(greaterThan(5))));

  for (final vector in cases) {
    test(vector['name'], () async {
      final credential = RequestCredential.parse(
        vector['authorization']! as String,
      )!;
      final sink = hasher.start()..add(_bytes(vector['body']! as String));
      final request = SignedRequest(
        method: vector['method']! as String,
        path: vector['path']! as String,
        millis: credential.millis,
        nonce: credential.nonce,
        body: await sink.close(),
      );

      expect(request.signable, _bytes(vector['signable']! as String));
      bool verifies() {
        try {
          identities.verify(
            request.signable,
            signature: credential.signature,
            signer: credential.key,
          );
          return true;
        } on InvalidSignatureException {
          return false;
        }
      }

      expect(verifies(), vector['valid']);
    });
  }
}

Uint8List _bytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
