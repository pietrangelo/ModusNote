import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late EnvelopeEncryptor encryptor;
  late SubkeyDerivationService subkeys;
  late SymmetricKey parent;
  final blob = KeyContext('mn-blob1');
  final record = AssociatedData.forContext('blob', 'b1');

  setUpAll(initSodium);
  setUp(() {
    encryptor = SodiumEnvelopeEncryptor(sodium);
    subkeys = SodiumSubkeyDerivationService(sodium);
    parent = encryptor.generateKey();
  });
  tearDown(() => parent.dispose());

  /// Keys are opaque, so equality is observed through encryption: two
  /// handles hold the same key iff one opens what the other sealed.
  bool sameKey(SymmetricKey a, SymmetricKey b) {
    final envelope = encryptor.seal(
      utf8Bytes('probe'),
      key: a,
      associatedData: record,
    );
    try {
      encryptor.open(envelope, key: b, associatedData: record);
      return true;
    } on AuthenticationTagMismatchException {
      return false;
    }
  }

  test('ids are fresh random 8-byte values', () {
    final ids = {for (var i = 0; i < 1000; i++) subkeys.newSubkeyId()};

    expect(ids, hasLength(1000));
  });

  test('derivation is deterministic for the same parent, context and id', () {
    final id = subkeys.newSubkeyId();
    final first = subkeys.deriveSubkey(parent: parent, context: blob, id: id);
    final again = subkeys.deriveSubkey(parent: parent, context: blob, id: id);

    expect(sameKey(first, again), isTrue);
  });

  test('a different id gives an unrelated key', () {
    final a = subkeys.deriveSubkey(
      parent: parent,
      context: blob,
      id: subkeys.newSubkeyId(),
    );
    final b = subkeys.deriveSubkey(
      parent: parent,
      context: blob,
      id: subkeys.newSubkeyId(),
    );

    expect(sameKey(a, b), isFalse);
  });

  test('the derived key outlives the parent handle', () {
    final child = subkeys.deriveSubkey(
      parent: parent,
      context: blob,
      id: subkeys.newSubkeyId(),
    );
    final envelope = encryptor.seal(
      utf8Bytes('x'),
      key: child,
      associatedData: record,
    );
    parent.dispose();

    expect(
      encryptor.open(envelope, key: child, associatedData: record),
      utf8Bytes('x'),
    );
    child.dispose();
  });

  test('the derived key prints redacted', () {
    final child = subkeys.deriveSubkey(
      parent: parent,
      context: blob,
      id: subkeys.newSubkeyId(),
    );

    expect(child.toString(), 'SymmetricKey(redacted)');
  });

  group('adversary', () {
    test('a different context gives an unrelated key (domain separation)', () {
      final id = subkeys.newSubkeyId();
      final forBlobs = subkeys.deriveSubkey(
        parent: parent,
        context: blob,
        id: id,
      );
      final forOther = subkeys.deriveSubkey(
        parent: parent,
        context: KeyContext('mn-othr1'),
        id: id,
      );

      expect(sameKey(forBlobs, forOther), isFalse);
    });

    test('a subkey is not the parent: it cannot open parent envelopes', () {
      final child = subkeys.deriveSubkey(
        parent: parent,
        context: blob,
        id: subkeys.newSubkeyId(),
      );

      expect(sameKey(parent, child), isFalse);
    });

    test('another parent with the same context and id gives another key', () {
      final other = encryptor.generateKey();
      final id = subkeys.newSubkeyId();

      expect(
        sameKey(
          subkeys.deriveSubkey(parent: parent, context: blob, id: id),
          subkeys.deriveSubkey(parent: other, context: blob, id: id),
        ),
        isFalse,
      );
    });

    test('deriving from a disposed parent is refused', () {
      parent.dispose();

      expect(
        () => subkeys.deriveSubkey(
          parent: parent,
          context: blob,
          id: subkeys.newSubkeyId(),
        ),
        throwsA(isA<DisposedKeyException>()),
      );
    });
  });
}
