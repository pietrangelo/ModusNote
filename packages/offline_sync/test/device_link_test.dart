import 'dart:convert';
import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

final link = LinkId.parse('00112233445566778899aabbccddeeff');

EncryptedEnvelope envelope(int plaintextLength) => EncryptedEnvelope(
  nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
  ciphertext: List.filled(plaintextLength + EncryptedEnvelope.tagLength, 4),
);

LinkOffer offer() => LinkOffer(
  id: link,
  salt: Salt.fromBytes(List.filled(Salt.length, 1)),
  sealedInvitation: envelope(LinkOffer.invitationLength),
);

LinkAnswer answer() =>
    LinkAnswer(id: link, sealedIdentity: envelope(PublicIdentity.length));

void main() {
  group('code', () {
    test('ten symbols, shown in two groups of five', () {
      final code = LinkCode.random(Random(1));

      expect(code.display, matches(RegExp(r'^[0-9A-Z]{5}-[0-9A-Z]{5}$')));
      expect(LinkCode.tryParse(code.display), code);
    });

    test('carries about fifty bits', () {
      final random = Random(2);
      final seen = {
        for (var i = 0; i < 2000; i++) LinkCode.random(random).display,
      };

      expect(seen, hasLength(2000));
      expect(LinkCode.bits, 50);
    });

    test('typing is forgiving: case, spaces, dashes, look-alikes', () {
      final code = LinkCode.tryParse('K7MQ4-XT9AB')!;

      expect(LinkCode.tryParse('k7mq4 xt9ab'), code);
      expect(LinkCode.tryParse(' k7mq4xt9ab '), code);
      expect(
        LinkCode.tryParse('10OIL-ABCDE'),
        LinkCode.tryParse('10011-ABCDE'),
      );
    });

    test('anything else is not a code', () {
      for (final input in [
        '',
        'K7MQ4',
        'K7MQ4-XT9ABC',
        'K7MQ4-XT9A!',
        'UUUUU-UUUUU',
      ]) {
        expect(LinkCode.tryParse(input), isNull, reason: input);
      }
    });

    test('its bytes are the symbols, ready for Argon2id', () {
      final code = LinkCode.tryParse('k7mq4-xt9ab')!;

      expect(utf8.decode(code.toBytes()), 'K7MQ4XT9AB');
      expect(
        code.toBytes().length,
        greaterThanOrEqualTo(PassphrasePolicy.minimumBytes),
      );
    });

    test('never prints itself', () {
      final code = LinkCode.tryParse('K7MQ4-XT9AB')!;

      expect('$code', isNot(contains('K7MQ4')));
    });
  });

  group('wire', () {
    test('an offer round-trips', () {
      expect(LinkOffer.parse(offer().toBytes()), offer());
    });

    test('an answer round-trips', () {
      expect(LinkAnswer.parse(answer().toBytes()), answer());
    });

    test('an offer and an answer seal under different associated data', () {
      expect(
        LinkOffer.associatedData(link),
        isNot(LinkAnswer.associatedData(link)),
      );
      expect(
        LinkOffer.associatedData(link),
        isNot(
          LinkOffer.associatedData(
            LinkId.parse('ffeeddccbbaa99887766554433221100'),
          ),
        ),
      );
    });
  });

  group('adversary', () {
    test('a sealed payload of the wrong size is refused', () {
      final long = LinkOffer(
        id: link,
        salt: Salt.fromBytes(List.filled(Salt.length, 1)),
        sealedInvitation: envelope(LinkOffer.invitationLength + 1),
      ).toBytes();
      final short = LinkAnswer(
        id: link,
        sealedIdentity: envelope(10),
      ).toBytes();

      expect(
        () => LinkOffer.parse(long),
        throwsA(isA<MalformedSyncDataException>()),
      );
      expect(
        () => LinkAnswer.parse(short),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an offer is not an answer, nor the other way round', () {
      expect(
        () => LinkAnswer.parse(offer().toBytes()),
        throwsA(isA<MalformedSyncDataException>()),
      );
      expect(
        () => LinkOffer.parse(answer().toBytes()),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('every truncation and trailing byte is refused', () {
      for (final wire in [offer().toBytes(), answer().toBytes()]) {
        for (var length = 0; length < wire.length; length += 7) {
          final cut = Uint8List.sublistView(wire, 0, length);
          expect(
            () => LinkOffer.parse(cut),
            throwsA(isA<MalformedSyncDataException>()),
          );
          expect(
            () => LinkAnswer.parse(cut),
            throwsA(isA<MalformedSyncDataException>()),
          );
        }
        expect(
          () => LinkOffer.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedSyncDataException>()),
        );
        expect(
          () => LinkAnswer.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });

    test('a link id that is not 32 hex digits is refused', () {
      for (final hex in ['', '00', 'G0112233445566778899aabbccddeeff']) {
        expect(
          () => LinkId.parse(hex),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the parsers', (bytes) {
          for (final parse in [LinkOffer.parse, LinkAnswer.parse]) {
            try {
              parse(Uint8List.fromList(bytes));
            } on MalformedSyncDataException {
              // The only acceptable failure.
            }
          }
        });
  });
}
