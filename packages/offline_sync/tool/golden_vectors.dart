// Writes server/vectors/requests.json: signed requests, good and bad, each
// with the bytes that were signed and the verdict it is built to have. The
// Dart domain (test/request_vectors_test.dart) and the Rust server check
// the same file.
//
//   dart run tool/golden_vectors.dart ../../server/vectors/requests.json
//
// Keys and nonces are random, so every run writes a new file with the same
// cases; the file is committed and only rewritten when a case is added.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/golden_vectors.dart <out.json>');
    exit(64);
  }
  final sodium = await SodiumSumoInit.init();
  final identities = SodiumIdentityService(sodium);
  final hasher = SodiumContentHasher(sodium);
  final random = Random.secure();
  final device = identities.generateIdentity();
  final stranger = identities.generateIdentity();

  Future<ContentDigest> digest(List<int> body) async {
    final sink = hasher.start()..add(Uint8List.fromList(body));
    return sink.close();
  }

  final cases = <Map<String, Object>>[];
  Future<void> add(
    String name, {
    required String method,
    required String path,
    required List<int> body,
    int millis = 1792700000000,
    String? signedMethod,
    String? signedPath,
    List<int>? signedBody,
    int? signedMillis,
    IdentityKeyPair? signer,
    Uint8List Function(Uint8List signature)? alter,
    required bool valid,
  }) async {
    final nonce = List.generate(16, (_) => random.nextInt(256));
    SignedRequest request(String m, String p, int t, ContentDigest d) =>
        SignedRequest(method: m, path: p, millis: t, nonce: nonce, body: d);
    final sent = request(method, path, millis, await digest(body));
    final signed = request(
      signedMethod ?? method,
      signedPath ?? path,
      signedMillis ?? millis,
      await digest(signedBody ?? body),
    );
    final signature = Uint8List.fromList(
      identities.sign(signed.signable, signer: signer ?? device).bytes,
    );
    final header = RequestCredential(
      key: device.publicIdentity.signingKey,
      millis: millis,
      nonce: nonce,
      signature: Signature.fromBytes(alter?.call(signature) ?? signature),
    ).header;
    cases.add({
      'name': name,
      'method': method,
      'path': path,
      'body': _hex(body),
      'authorization': header,
      'signable': _hex(sent.signable),
      'valid': valid,
    });
  }

  const rows = '/api/w/6d6f6475736e6f746573766563746f72/rows';
  final body = utf8.encode('{"rows":[]}');
  await add(
    'a GET',
    method: 'GET',
    path: '$rows?after=12',
    body: const [],
    valid: true,
  );
  await add(
    'a POST with a body',
    method: 'POST',
    path: rows,
    body: body,
    valid: true,
  );
  await add(
    'signed for another path',
    method: 'GET',
    path: '$rows?after=0',
    signedPath: '$rows?after=12',
    body: const [],
    valid: false,
  );
  await add(
    'signed for another method',
    method: 'DELETE',
    path: rows,
    signedMethod: 'GET',
    body: const [],
    valid: false,
  );
  await add(
    'signed for another body',
    method: 'POST',
    path: rows,
    body: body,
    signedBody: utf8.encode('{"rows":[1]}'),
    valid: false,
  );
  await add(
    'signed at another time',
    method: 'POST',
    path: rows,
    body: body,
    signedMillis: 1792700000001,
    valid: false,
  );
  await add(
    'signed by another key',
    method: 'POST',
    path: rows,
    body: body,
    signer: stranger,
    valid: false,
  );
  await add(
    'a flipped bit in the signature',
    method: 'POST',
    path: rows,
    body: body,
    alter: (s) => s..[10] ^= 1,
    valid: false,
  );
  await add(
    'a signature with a non-canonical S',
    method: 'POST',
    path: rows,
    body: body,
    alter: _withNonCanonicalS,
    valid: false,
  );

  final json = const JsonEncoder.withIndent(' ').convert({
    'about':
        'Signed requests. signable: the bytes the server rebuilds from '
        'method, path, the time and nonce of the header and the BLAKE2b-256 '
        'of the body; valid: whether the header\'s signature verifies '
        'over them with the header\'s key.',
    'cases': cases,
  });
  File(args.single).writeAsStringSync('$json\n');
  device.dispose();
  stranger.dispose();
  stdout.writeln('${cases.length} cases written to ${args.single}');
}

final _order = BigInt.parse(
  '7237005577332262213973186563042994240857116359379907606001950938285454250989',
);

Uint8List _withNonCanonicalS(Uint8List signature) {
  var value = BigInt.zero;
  for (var i = 63; i >= 32; i--) {
    value = (value << 8) | BigInt.from(signature[i]);
  }
  value += _order;
  for (var i = 0; i < 32; i++) {
    signature[32 + i] = (value >> (8 * i) & BigInt.from(0xff)).toInt();
  }
  return signature;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
