@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import '../tool/service_notice.dart';

void main() {
  late SodiumSumo sodium;
  late Directory dir;
  final now = DateTime.utc(2026, 10, 23, 9, 30);

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('service_notice_');
    addTearDown(() => dir.delete(recursive: true));
  });

  String path(String name) => '${dir.path}/$name';

  /// The tool as the operator runs it, typing [typed] at each prompt.
  NoticeTool tool(List<String> typed, {DateTime? at}) {
    final answers = [...typed];
    return NoticeTool(
      sodium: sodium,
      kdf: KdfParameters.interactive,
      now: () => at ?? now,
      readPassphrase: (prompt) =>
          Uint8List.fromList(utf8.encode(answers.removeAt(0))),
    );
  }

  SignCommand signing({
    int? serial = 1,
    int days = 7,
    Map<String, String> texts = const {'it': 'Ciao', 'en': 'Hello'},
    ServiceNoticeLevel level = ServiceNoticeLevel.info,
  }) => SignCommand(
    keyPath: path('operator.key'),
    serial: serial,
    days: days,
    level: level,
    texts: texts,
    file: path('notices.json'),
  );

  group('arguments', () {
    const defaultFile = 'web/notices.json';

    NoticeCommand parse(List<String> args) =>
        parseCommand(args, defaultFile: defaultFile);

    test('keygen takes the file of the new key', () {
      expect(
        parse(['keygen', 'op.key']),
        isA<KeygenCommand>().having((c) => c.keyPath, 'keyPath', 'op.key'),
      );
    });

    test('sign takes the key, serial, days, level and texts in order', () {
      final command = parse([
        'sign',
        '--key',
        'op.key',
        '--serial',
        '12',
        '--days',
        '30',
        '--level',
        'warning',
        '--text',
        'it=Manutenzione domenica: il servizio = fermo.',
        '--text',
        'en=Maintenance on Sunday.',
      ]);

      expect(command, isA<SignCommand>());
      command as SignCommand;
      expect(command.keyPath, 'op.key');
      expect(command.serial, 12);
      expect(command.days, 30);
      expect(command.level, ServiceNoticeLevel.warning);
      expect(command.texts, {
        'it': 'Manutenzione domenica: il servizio = fermo.',
        'en': 'Maintenance on Sunday.',
      });
      expect(command.texts.keys, ['it', 'en']);
      expect(command.file, defaultFile);
    });

    test('a line break in a text is written as \\n', () {
      final command = parse([
        'sign',
        ...['--key', 'k', '--serial', '1', '--days', '1'],
        ...['--text', r'it=Prima riga\nseconda riga'],
        ...['--file', 'other.json'],
      ]) as SignCommand;

      expect(command.texts['it'], 'Prima riga\nseconda riga');
      expect(command.level, ServiceNoticeLevel.info);
      expect(command.file, 'other.json');
    });

    test('sign without a serial takes the next one', () {
      final command = parse([
        'sign',
        ...['--key', 'k', '--days', '1', '--text', 'it=a'],
      ]) as SignCommand;

      expect(command.serial, isNull);
    });

    test('prune takes the file, or the app\'s', () {
      expect(
        parse(['prune']),
        isA<PruneCommand>().having((c) => c.file, 'file', defaultFile),
      );
      expect(
        parse(['prune', '--file', 'x.json']),
        isA<PruneCommand>().having((c) => c.file, 'file', 'x.json'),
      );
    });

    test('anything else is a usage error', () {
      for (final args in [
        <String>[],
        ['keygen'],
        ['keygen', 'a', 'b'],
        ['publish'],
        ['sign', '--key', 'k', '--serial', '1', '--text', 'it=a'],
        ['sign', '--serial', '1', '--days', '1', '--text', 'it=a'],
        ['sign', '--key', 'k', '--serial', '1', '--days', '1'],
        [
          'sign',
          '--key',
          'k',
          '--serial',
          'x',
          '--days',
          '1',
          '--text',
          'it=a',
        ],
        [
          'sign',
          '--key',
          'k',
          '--serial',
          '1',
          '--days',
          '0',
          '--text',
          'it=a',
        ],
        [
          'sign',
          '--key',
          'k',
          '--serial',
          '1',
          '--days',
          '91',
          '--text',
          'it=a',
        ],
        [
          'sign',
          '--key',
          'k',
          '--serial',
          '-1',
          '--days',
          '1',
          '--text',
          'it=a',
        ],
        ['sign', '--key', 'k', '--serial', '1', '--days', '1', '--text', 'ita'],
        [
          'sign',
          ...['--key', 'k', '--serial', '1', '--days', '1'],
          ...['--text', 'it=a', '--text', 'it=b'],
        ],
        [
          'sign',
          ...['--key', 'k', '--serial', '1', '--days', '1', '--text', 'it=a'],
          ...['--level', 'panic'],
        ],
        ['sign', '--key'],
        ['prune', '--file'],
        ['prune', '--loud'],
      ]) {
        expect(
          () => parse(args),
          throwsA(isA<UsageException>()),
          reason: args.join(' '),
        );
      }
    });
  });

  group('notices.json', () {
    test('a missing file holds no notices', () {
      expect(readNotices(File(path('notices.json'))).envelopes, isEmpty);
    });

    test('holds the envelopes in standard base64, one per line', () {
      final file = File(path('notices.json'));
      final envelopes = [
        Uint8List.fromList([1, 2, 3, 250]),
        Uint8List.fromList([4, 5, 6]),
      ];

      writeNotices(file, envelopes, lastSerial: 7);

      expect(readNotices(file).envelopes, envelopes);
      expect(readNotices(file).lastSerial, 7);
      expect(
        file.readAsStringSync(),
        '{\n  "lastSerial": 7,\n  "notices": [\n    "AQID+g==",\n'
        '    "BAUG"\n  ]\n}\n',
      );
      writeNotices(file, []);
      expect(file.readAsStringSync(), '{\n  "notices": []\n}\n');
      expect(readNotices(file).lastSerial, isNull);
    });

    test('a file of another shape is refused', () {
      final file = File(path('notices.json'))
        ..writeAsStringSync('{"notices": [1]}');

      expect(() => readNotices(file), throwsA(isA<UsageException>()));
      file.writeAsStringSync('[]');
      expect(() => readNotices(file), throwsA(isA<UsageException>()));
      for (final other in [
        '{"lastSerial": "7", "notices": []}',
        '{"lastSerial": -1, "notices": []}',
        '{"lastSerial": 4294967296, "notices": []}',
        '{"lastSerial": 1.5, "notices": []}',
        '{"lastSerial": null, "notices": []}',
        '{"next": 7, "notices": []}',
      ]) {
        file.writeAsStringSync(other);
        expect(
          () => readNotices(file),
          throwsA(isA<UsageException>()),
          reason: other,
        );
      }
    });
  });

  group('keys and signing', () {
    test('keygen seals a new key under the passphrase and signs with it; '
        'the app\'s board accepts the notice', () async {
      final public = await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));

      final key = File(path('operator.key'));
      expect(key.existsSync(), isTrue);
      expect(
        (await key.stat()).modeString(),
        'rw-------',
        reason: 'only the operator reads the key file',
      );
      final signed = await tool(['frase del gestore'])
          .sign(signing(serial: 3, days: 30));

      expect(signed.notice.serial, 3);
      expect(signed.notice.issued, now);
      expect(signed.notice.expires, now.add(const Duration(days: 30)));
      expect(signed.notice.texts, {'it': 'Ciao', 'en': 'Hello'});
      final published = readNotices(File(path('notices.json'))).envelopes;
      expect(published, [signed.toBytes()]);

      final board = ServiceNoticeBoard(
        source: _Published(published),
        identities: SodiumIdentityService(sodium),
        keys: [
          OperatorKey(public, notAfter: now.add(const Duration(days: 365))),
        ],
        clock: _Clock(now),
      );
      expect(await board.current(), [signed.notice]);
    });

    test(
      'the sealed key holds no private key in clear and binds its costs',
      () async {
        await tool(['frase del gestore', 'frase del gestore'])
            .keygen(path('operator.key'));
        final bytes = File(path('operator.key')).readAsBytesSync();

        expect(ascii.decode(bytes.sublist(0, 4)), 'MNOK');
        // Other costs written over the file's (ops limit 2 becomes 3): the
        // key no longer opens.
        final altered = Uint8List.fromList(bytes)..[24] ^= 1;
        File(path('operator.key')).writeAsBytesSync(altered);
        await expectLater(
          tool(['frase del gestore']).sign(signing()),
          throwsA(isA<UsageException>()),
        );
      },
    );

    test('a wrong passphrase signs nothing', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));

      await expectLater(
        tool(['frase sbagliata!']).sign(signing()),
        throwsA(isA<UsageException>()),
      );
      expect(File(path('notices.json')).existsSync(), isFalse);
    });

    test('keygen refuses two different passphrases or a short one', () async {
      await expectLater(
        tool(['frase del gestore', 'frase diversa!!']).keygen(path('a.key')),
        throwsA(isA<UsageException>()),
      );
      await expectLater(
        tool(['corta', 'corta']).keygen(path('b.key')),
        throwsA(isA<UsageException>()),
      );
      expect(File(path('a.key')).existsSync(), isFalse);
      expect(File(path('b.key')).existsSync(), isFalse);
    });

    test('keygen never overwrites a key', () async {
      final existing = File(path('operator.key'))..writeAsStringSync('keep');

      await expectLater(
        tool(['frase del gestore', 'frase del gestore']).keygen(existing.path),
        throwsA(isA<UsageException>()),
      );
      expect(existing.readAsStringSync(), 'keep');
    });

    test(
      'sign adds to what is published and refuses a serial in use',
      () async {
        await tool(['frase del gestore', 'frase del gestore'])
            .keygen(path('operator.key'));
        final first = await tool(['frase del gestore'])
            .sign(signing(serial: 1));
        final second = await tool(['frase del gestore'])
            .sign(signing(serial: 2));

        expect(readNotices(File(path('notices.json'))).envelopes, [
          first.toBytes(),
          second.toBytes(),
        ]);
        await expectLater(
          tool(['frase del gestore']).sign(signing(serial: 2)),
          throwsA(isA<UsageException>()),
        );
      },
    );

    test('sign measures notices.json as it writes it, indented', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));
      const limit = ServiceNoticeBoard.maxPublishedBytes;
      int compact(List<Uint8List> envelopes) => utf8
          .encode(
            jsonEncode({
              'notices': [for (final e in envelopes) base64.encode(e)],
            }),
          )
          .length;
      // As large as the new notice will be: only the signature differs.
      final next = SignedServiceNotice(
        notice: ServiceNotice(
          serial: 8,
          issued: now,
          expires: now.add(const Duration(days: 7)),
          level: ServiceNoticeLevel.info,
          texts: const {'it': 'Ciao', 'en': 'Hello'},
        ),
        signature: Signature.fromBytes(Uint8List(Signature.length)),
      ).toBytes();
      final published = [for (var s = 1; s <= 6; s++) _filler(s, 7200, now)];
      var size = 7200;
      while (compact([...published, _filler(7, size, now), next]) > limit) {
        size--;
      }
      published.add(_filler(7, size, now));
      final file = File(path('notices.json'));
      writeNotices(file, published);
      final before = file.readAsStringSync();
      expect(
        compact([...published, next]),
        lessThanOrEqualTo(limit),
        reason: 'only the indentation takes it over the limit',
      );

      await expectLater(
        tool(['frase del gestore']).sign(signing(serial: 8)),
        throwsA(isA<UsageException>()),
      );
      expect(file.readAsStringSync(), before);
    });

    test('serials only go up, even after prune: devices remember the '
        'serials people closed', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));
      await tool(['frase del gestore']).sign(signing(serial: 5, days: 1));
      final later = now.add(const Duration(days: 2));
      expect(tool([], at: later).prune(path('notices.json')), 1);
      expect(readNotices(File(path('notices.json'))).envelopes, isEmpty);

      for (final serial in [5, 4, 0]) {
        await expectLater(
          tool(['frase del gestore'], at: later).sign(signing(serial: serial)),
          throwsA(isA<UsageException>()),
          reason: 'serial $serial',
        );
      }
      final next = await tool([
        'frase del gestore',
      ], at: later).sign(signing(serial: null));
      expect(next.notice.serial, 6);
      expect(readNotices(File(path('notices.json'))).lastSerial, 6);
      final skipped = await tool([
        'frase del gestore',
      ], at: later).sign(signing(serial: 9));
      expect(skipped.notice.serial, 9);
      expect(readNotices(File(path('notices.json'))).lastSerial, 9);
    });

    test('the first serial is 1, and a file written before lastSerial '
        'counts its own notices', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));
      final first = await tool(['frase del gestore'])
          .sign(signing(serial: null, days: 1));
      expect(first.notice.serial, 1);

      final file = File(path('notices.json'));
      writeNotices(file, [
        _filler(30, 200, now),
        _filler(12, 200, now.add(const Duration(days: 40))),
      ]);
      final later = now.add(const Duration(days: 35));
      expect(tool([], at: later).prune(file.path), 1);
      expect(readNotices(file).lastSerial, 30);
      final next = await tool([
        'frase del gestore',
      ], at: later).sign(signing(serial: null));
      expect(next.notice.serial, 31);
    });

    test('no serial is left above the highest', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));
      await tool(['frase del gestore']).sign(signing(serial: 0xffffffff));

      await expectLater(
        tool(['frase del gestore']).sign(signing(serial: null)),
        throwsA(isA<UsageException>()),
      );
    });

    test('sign refuses a text no device would show', () async {
      await tool(['frase del gestore', 'frase del gestore'])
          .keygen(path('operator.key'));

      await expectLater(
        tool(['frase del gestore']).sign(signing(texts: {'it': ' Ciao'})),
        throwsA(isA<UsageException>()),
      );
      expect(File(path('notices.json')).existsSync(), isFalse);
    });
  });

  test('prune drops the notices that expired', () async {
    await tool(['frase del gestore', 'frase del gestore'])
        .keygen(path('operator.key'));
    await tool(['frase del gestore']).sign(signing(serial: 1, days: 1));
    final lasting = await tool(['frase del gestore'])
        .sign(signing(serial: 2, days: 10));

    final removed = tool(
      [],
      at: now.add(const Duration(days: 1)),
    ).prune(path('notices.json'));

    expect(removed, 1);
    expect(readNotices(File(path('notices.json'))).envelopes, [
      lasting.toBytes(),
    ]);
  });
}

/// An envelope of exactly [bytes] bytes, in four languages, signed by
/// nobody: the tool only reads what is already published.
Uint8List _filler(int serial, int bytes, DateTime issued) {
  // The body's fixed fields, four text headers and the signature.
  final text = bytes - 23 - 4 * 4 - Signature.length;
  final texts = <String, String>{};
  for (final (index, language) in ['it', 'en', 'de', 'fr'].indexed) {
    final length = text ~/ 4 + (index < text % 4 ? 1 : 0);
    texts[language] = '€' * (length ~/ 3) + 'a' * (length % 3);
  }
  final envelope = SignedServiceNotice(
    notice: ServiceNotice(
      serial: serial,
      issued: issued,
      expires: issued.add(const Duration(days: 30)),
      level: ServiceNoticeLevel.info,
      texts: texts,
    ),
    signature: Signature.fromBytes(Uint8List(Signature.length)),
  ).toBytes();
  expect(envelope, hasLength(bytes));
  return envelope;
}

final class _Published implements ServiceNoticeSource {
  _Published(this.envelopes);

  final List<Uint8List> envelopes;

  @override
  Future<List<Uint8List>> fetch() async => envelopes;
}

final class _Clock implements Clock {
  _Clock(this.current);

  final DateTime current;

  @override
  DateTime now() => current;
}
