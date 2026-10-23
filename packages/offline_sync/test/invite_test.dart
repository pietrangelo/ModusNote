import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

const lookup = 'K7MQ4X';

EncryptedEnvelope envelope(int plaintextLength) => EncryptedEnvelope(
  nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
  ciphertext: List.filled(plaintextLength + EncryptedEnvelope.tagLength, 4),
);

InviteOffer offer() => InviteOffer(
  lookup: lookup,
  salt: Salt.fromBytes(List.filled(Salt.length, 1)),
  sealedInvitation: envelope(Invitation.length),
);

InviteAnswer answer() => InviteAnswer(
  lookup: lookup,
  sealedJoiner: envelope(InviteAnswer.joinerLength),
);

void main() {
  group('code', () {
    test('sixteen symbols, shown in three groups', () {
      final code = InviteCode.random(Random(1));

      expect(
        code.display,
        matches(RegExp(r'^[0-9A-Z]{6}-[0-9A-Z]{5}-[0-9A-Z]{5}$')),
      );
      expect(InviteCode.tryParse(code.display), code);
    });

    test('the server sees six symbols, ten stay secret', () {
      final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;

      expect(code.lookup, 'K7MQ4X');
      expect(InviteCode.length - InviteCode.lookupLength, 10);
    });

    test('codes do not repeat', () {
      final random = Random(2);
      final seen = {
        for (var i = 0; i < 2000; i++) InviteCode.random(random).display,
      };

      expect(seen, hasLength(2000));
    });

    test('typing is forgiving: case, spaces, dashes, look-alikes', () {
      final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;

      expect(InviteCode.tryParse('k7mq4x t9abc d2efg'), code);
      expect(InviteCode.tryParse(' k7mq4xt9abcd2efg '), code);
      expect(
        InviteCode.tryParse('10OIL0-ABCDE-FGHJK'),
        InviteCode.tryParse('100110-ABCDE-FGHJK'),
      );
    });

    test('anything else is not a code', () {
      for (final input in [
        '',
        'K7MQ4-XT9AB',
        'K7MQ4X-T9ABC-D2EF',
        'K7MQ4X-T9ABC-D2EFGH',
        'K7MQ4X-T9ABC-D2EF!',
        'UUUUUU-UUUUU-UUUUU',
      ]) {
        expect(InviteCode.tryParse(input), isNull, reason: input);
      }
    });

    test('its bytes are the symbols, ready for Argon2id', () {
      final code = InviteCode.tryParse('k7mq4x-t9abc-d2efg')!;

      expect(utf8.decode(code.toBytes()), 'K7MQ4XT9ABCD2EFG');
      expect(
        code.toBytes().length,
        greaterThanOrEqualTo(PassphrasePolicy.minimumBytes),
      );
    });

    test('never prints itself', () {
      final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;

      expect('$code', isNot(contains('K7MQ4X')));
    });
  });

  group('wire', () {
    test('an offer round-trips', () {
      expect(InviteOffer.parse(offer().toBytes()), offer());
    });

    test('an answer round-trips', () {
      expect(InviteAnswer.parse(answer().toBytes()), answer());
    });

    test('an answer carries a public identity and nothing else', () {
      final identity = PublicIdentity.parse(
        Uint8List.fromList(List.filled(PublicIdentity.length, 7)),
      );

      expect(InviteAnswer.readJoiner(InviteAnswer.joiner(identity)), identity);
      expect(
        () => InviteAnswer.readJoiner(
          Uint8List.fromList([...InviteAnswer.joiner(identity), 0]),
        ),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an offer and an answer seal under different associated data', () {
      expect(
        InviteOffer.associatedData(lookup),
        isNot(InviteAnswer.associatedData(lookup)),
      );
      expect(
        InviteOffer.associatedData(lookup),
        isNot(InviteOffer.associatedData('M3PQ8Z')),
      );
    });
  });

  group('adversary', () {
    test('a sealed payload of the wrong size is refused', () {
      final long = InviteOffer(
        lookup: lookup,
        salt: Salt.fromBytes(List.filled(Salt.length, 1)),
        sealedInvitation: envelope(Invitation.length + 1),
      ).toBytes();
      final short = InviteAnswer(
        lookup: lookup,
        sealedJoiner: envelope(10),
      ).toBytes();

      expect(
        () => InviteOffer.parse(long),
        throwsA(isA<MalformedSyncDataException>()),
      );
      expect(
        () => InviteAnswer.parse(short),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an offer is not an answer, nor the other way round', () {
      expect(
        () => InviteAnswer.parse(offer().toBytes()),
        throwsA(isA<MalformedSyncDataException>()),
      );
      expect(
        () => InviteOffer.parse(answer().toBytes()),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a lookup that is not six symbols of the alphabet is refused', () {
      final wire = offer().toBytes()..[1] = '!'.codeUnitAt(0);

      expect(
        () => InviteOffer.parse(wire),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('every truncation and trailing byte is refused', () {
      for (final wire in [offer().toBytes(), answer().toBytes()]) {
        for (var length = 0; length < wire.length; length += 7) {
          final cut = Uint8List.sublistView(wire, 0, length);
          expect(
            () => InviteOffer.parse(cut),
            throwsA(isA<MalformedSyncDataException>()),
          );
          expect(
            () => InviteAnswer.parse(cut),
            throwsA(isA<MalformedSyncDataException>()),
          );
        }
        expect(
          () => InviteOffer.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedSyncDataException>()),
        );
        expect(
          () => InviteAnswer.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the parsers', (bytes) {
          for (final parse in [InviteOffer.parse, InviteAnswer.parse]) {
            try {
              parse(Uint8List.fromList(bytes));
            } on MalformedSyncDataException {
              // The only acceptable failure.
            }
          }
        });
  });
}
