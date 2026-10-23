import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:test/test.dart';

/// Pure wire formats, no libsodium: in CI these also run compiled to
/// JavaScript (`dart test -p chrome`), where 64-bit integers differ.
void main() {
  final issued = DateTime.utc(2026, 10, 23, 9);
  final expires = issued.add(const Duration(days: 7));

  /// A body as the operator's tool writes it, field by field, so each test
  /// can break exactly one.
  Uint8List body({
    int version = 1,
    int serial = 7,
    int issuedMs = 1792746000000,
    int? expiresMs,
    int level = 0,
    int? count,
    List<(String, List<int>)>? texts,
  }) {
    final entries =
        texts ??
        [
          ('it', utf8.encode('Aggiorna l’app entro venerdì.')),
          ('en', utf8.encode('Please update the app by Friday.')),
        ];
    final data = BytesBuilder()
      ..addByte(version)
      ..add(_uint32(serial))
      ..add(_int64(issuedMs))
      ..add(_int64(expiresMs ?? issuedMs + 7 * 86400000))
      ..addByte(level)
      ..addByte(count ?? entries.length);
    for (final (language, text) in entries) {
      data
        ..add(ascii.encode(language))
        ..add([text.length >> 8, text.length & 0xff])
        ..add(text);
    }
    return data.takeBytes();
  }

  ServiceNotice notice({
    int serial = 7,
    Map<String, String> texts = const {'it': 'Ciao', 'en': 'Hello'},
    Duration lasts = const Duration(days: 7),
    ServiceNoticeLevel level = ServiceNoticeLevel.info,
  }) => ServiceNotice(
    serial: serial,
    issued: issued,
    expires: issued.add(lasts),
    level: level,
    texts: texts,
  );

  Matcher malformed() => throwsA(isA<MalformedSyncDataException>());

  group('a service notice', () {
    test('reads what the operator wrote', () {
      final parsed = ServiceNotice.parse(body());

      expect(parsed.serial, 7);
      expect(parsed.issued, issued);
      expect(parsed.expires, expires);
      expect(parsed.issued.isUtc, isTrue);
      expect(parsed.level, ServiceNoticeLevel.info);
      expect(parsed.texts, {
        'it': 'Aggiorna l’app entro venerdì.',
        'en': 'Please update the app by Friday.',
      });
      expect(parsed.texts.keys, ['it', 'en']);
    });

    test('writes the same bytes it reads', () {
      expect(ServiceNotice.parse(body()).toBytes(), body());
      expect(
        ServiceNotice.parse(body(level: 1)).level,
        ServiceNoticeLevel.warning,
      );
      final written = notice(serial: 0xffffffff).toBytes();
      expect(ServiceNotice.parse(written), notice(serial: 0xffffffff));
    });

    test('is signed under its own label, over the body', () {
      final value = notice();

      expect(value.signable, [
        ...ascii.encode('modusnote.service-notice.v1'),
        ...value.toBytes(),
      ]);
    });

    test('speaks the app\'s language, then English, then its first', () {
      final value = notice(texts: {'it': 'Ciao', 'en': 'Hello', 'de': 'Hallo'});

      expect(value.textFor('it'), 'Ciao');
      expect(value.textFor('de'), 'Hallo');
      expect(value.textFor('fr'), 'Hello');
      expect(
        notice(texts: {'de': 'Hallo', 'it': 'Ciao'}).textFor('fr'),
        'Hallo',
      );
    });

    test('takes up to eight lines of up to 600 characters', () {
      final long = 'a' * 600;
      final lines = List.filled(8, 'riga').join('\n');

      expect(notice(texts: {'it': long}).texts['it'], long);
      expect(notice(texts: {'it': lines}).texts['it'], lines);
      expect(() => notice(texts: {'it': 'a' * 601}), malformed());
      expect(() => notice(texts: {'it': '$lines\nnona'}), malformed());
      // 600 UTF-16 units, not 600 characters: an emoji counts twice.
      expect(() => notice(texts: {'it': '😀' * 301}), malformed());
      expect(
        () =>
            ServiceNotice.parse(body(texts: [('it', utf8.encode('a' * 601))])),
        malformed(),
      );
    });

    test('refuses text that could render as something else', () {
      for (final text in [
        '',
        ' Ciao',
        'Ciao ',
        '\nCiao',
        'Ciao\n',
        'Ci\tao',
        'Ci\rao',
        'Ci\u0000ao',
        'Ci\u007fao',
        'Ci\u0085ao',
        'Ci\u202eao',
        'Ci\u2066ao',
        'Ci\u200fao',
        'Ci\u061cao',
        'Ci\u2028ao',
        'Ci\u2029ao',
        'Ci\ud800ao',
      ]) {
        expect(
          () => notice(texts: {'it': text}),
          malformed(),
          reason: jsonEncode(text),
        );
      }
    });

    test('refuses text that is not UTF-8', () {
      expect(
        () => ServiceNotice.parse(
          body(
            texts: [
              ('it', [0x43, 0xff, 0x61]),
            ],
          ),
        ),
        malformed(),
      );
      // A surrogate encoded on its own (CESU-8) is not UTF-8 either.
      expect(
        () => ServiceNotice.parse(
          body(
            texts: [
              ('it', [0xed, 0xa0, 0x80]),
            ],
          ),
        ),
        malformed(),
      );
    });

    test('takes one to four texts in distinct two-letter languages', () {
      final four = {'it': 'a', 'en': 'b', 'de': 'c', 'fr': 'd'};

      expect(notice(texts: four).texts, four);
      expect(() => notice(texts: {}), malformed());
      expect(() => notice(texts: {...four, 'es': 'e'}), malformed());
      for (final language in ['IT', 'i', 'ita', 'i1', 'é']) {
        expect(
          () => notice(texts: {language: 'a'}),
          malformed(),
          reason: language,
        );
      }
      expect(
        () => ServiceNotice.parse(
          body(texts: [('it', utf8.encode('a')), ('it', utf8.encode('b'))]),
        ),
        malformed(),
      );
      expect(() => ServiceNotice.parse(body(count: 0, texts: [])), malformed());
      expect(
        () => ServiceNotice.parse(
          body(
            texts: [
              for (final l in ['aa', 'bb', 'cc', 'dd', 'ee'])
                (l, utf8.encode('x')),
            ],
          ),
        ),
        malformed(),
      );
      expect(
        () => ServiceNotice.parse(body(texts: [('I1', utf8.encode('a'))])),
        malformed(),
      );
    });

    test('lasts more than nothing and at most ninety days', () {
      expect(
        notice(lasts: const Duration(days: 90)).expires,
        issued.add(const Duration(days: 90)),
      );
      expect(() => notice(lasts: Duration.zero), malformed());
      expect(() => notice(lasts: const Duration(days: -1)), malformed());
      expect(
        () => notice(lasts: const Duration(days: 90, milliseconds: 1)),
        malformed(),
      );
      expect(
        () => ServiceNotice.parse(body(expiresMs: 1792746000000)),
        malformed(),
      );
    });

    test('refuses times a browser or a date cannot hold', () {
      for (final ms in [-1, 8640000000000001, 9007199254740991]) {
        expect(
          () => ServiceNotice.parse(body(issuedMs: ms, expiresMs: ms + 1)),
          malformed(),
          reason: '$ms',
        );
      }
      // Beyond 2^53 − 1: unreadable in a browser, refused everywhere.
      final huge = body()..setRange(5, 13, [0x00, 0x40, 0, 0, 0, 0, 0, 0]);
      expect(() => ServiceNotice.parse(huge), malformed());
    });

    test('refuses another version, level or shape', () {
      expect(() => ServiceNotice.parse(body(version: 2)), malformed());
      expect(() => ServiceNotice.parse(body(level: 2)), malformed());
      expect(() => ServiceNotice.parse([...body(), 0]), malformed());
      final whole = body();
      for (var length = 0; length < whole.length; length++) {
        expect(
          () => ServiceNotice.parse(whole.sublist(0, length)),
          malformed(),
          reason: '$length bytes',
        );
      }
    });

    test('is a value', () {
      expect(notice(), notice());
      expect(notice().hashCode, notice().hashCode);
      expect(notice(serial: 8), isNot(notice()));
      expect(notice(texts: {'en': 'Hello', 'it': 'Ciao'}), isNot(notice()));
    });
  });

  group('a signed service notice', () {
    final signature = Signature.fromBytes(List.filled(Signature.length, 9));

    test('is the body followed by its signature', () {
      final signed = SignedServiceNotice(
        notice: notice(),
        signature: signature,
      );
      final bytes = signed.toBytes();

      expect(bytes, [...notice().toBytes(), ...signature.bytes]);
      final parsed = SignedServiceNotice.parse(bytes);
      expect(parsed.notice, notice());
      expect(parsed.signature, signature);
      expect(parsed.signedMessage, notice().signable);
    });

    test('refuses an envelope too short to hold a signature', () {
      expect(
        () => SignedServiceNotice.parse(Uint8List(Signature.length)),
        malformed(),
      );
      expect(() => SignedServiceNotice.parse(notice().toBytes()), malformed());
    });
  });

  group('the notices mark', () {
    test('keeps how many membership records the person has seen', () {
      final bytes = NoticeMark(42).toBytes();

      expect(bytes, [1, 0, 0, 0, 42]);
      expect(NoticeMark.parse(bytes).seen, 42);
      expect(
        NoticeMark.parse(NoticeMark(0xffffffff).toBytes()).seen,
        0xffffffff,
      );
      expect(NoticeMark(3), NoticeMark(3));
    });

    test('refuses anything else', () {
      expect(() => NoticeMark(-1), malformed());
      expect(() => NoticeMark(0x100000000), malformed());
      for (final bytes in [
        <int>[],
        [1, 0, 0, 0],
        [2, 0, 0, 0, 1],
        [1, 0, 0, 0, 1, 0],
      ]) {
        expect(() => NoticeMark.parse(bytes), malformed(), reason: '$bytes');
      }
    });
  });

  group('dismissed service notices', () {
    test('are kept by serial', () {
      final bytes = DismissedNotices.encode({3, 1, 0xffffffff});

      expect(bytes, [1, 0, 3, 0, 0, 0, 1, 0, 0, 0, 3, 255, 255, 255, 255]);
      expect(DismissedNotices.parse(bytes), {1, 3, 0xffffffff});
      expect(DismissedNotices.parse(DismissedNotices.encode({})), isEmpty);
    });

    test('keep the highest serials when there are too many', () {
      final serials = {for (var i = 1; i <= 100; i++) i};
      final kept = DismissedNotices.parse(DismissedNotices.encode(serials));

      expect(kept, hasLength(DismissedNotices.maxSerials));
      expect(kept, {for (var i = 12; i <= 100; i++) i});
    });

    test('refuse anything else', () {
      expect(() => DismissedNotices.encode({-1}), malformed());
      expect(() => DismissedNotices.encode({0x100000000}), malformed());
      for (final bytes in [
        <int>[],
        [2, 0, 0],
        [1, 0, 1],
        [1, 0, 1, 0, 0, 0, 1, 0],
        [1, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1],
        [1, 0, 90, ...List.filled(90 * 4, 0)],
      ]) {
        expect(
          () => DismissedNotices.parse(bytes),
          malformed(),
          reason: '$bytes',
        );
      }
    });
  });
}

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

/// Big-endian two's complement through two 32-bit halves, as the web build
/// writes it.
List<int> _int64(int value) {
  var high = value ~/ 4294967296;
  if (value < 0 && high * 4294967296 != value) high -= 1;
  final low = value - high * 4294967296;
  return [..._uint32(high & 0xffffffff), ..._uint32(low)];
}
