import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// What `notices.json` held, as the app fetched it.
final class _Source implements ServiceNoticeSource {
  _Source(this.envelopes);

  final List<Uint8List> envelopes;
  var fetches = 0;

  @override
  Future<List<Uint8List>> fetch() async {
    fetches++;
    return envelopes;
  }
}

void main() {
  late IdentityService identities;
  late IdentityKeyPair operator;
  late IdentityKeyPair spare;
  late IdentityKeyPair stranger;
  final now = DateTime.utc(2026, 10, 23, 12);
  final clock = FakeClock(now);

  setUpAll(() async {
    identities = SodiumIdentityService(await SodiumSumoInit.init());
    operator = identities.generateIdentity();
    spare = identities.generateIdentity();
    stranger = identities.generateIdentity();
  });

  tearDownAll(() {
    for (final key in [operator, spare, stranger]) {
      key.dispose();
    }
  });

  setUp(() => clock.current = now);

  ServiceNotice notice(
    int serial, {
    Duration issuedAgo = const Duration(days: 1),
    Duration lasts = const Duration(days: 7),
    String text = 'Manutenzione domenica.',
  }) => ServiceNotice(
    serial: serial,
    issued: now.subtract(issuedAgo),
    expires: now.subtract(issuedAgo).add(lasts),
    level: ServiceNoticeLevel.info,
    texts: {'it': text},
  );

  Uint8List signed(ServiceNotice notice, [IdentityKeyPair? by]) =>
      SignedServiceNotice(
        notice: notice,
        signature: identities.sign(notice.signable, signer: by ?? operator),
      ).toBytes();

  OperatorKey pinned(
    IdentityKeyPair key, {
    Duration validFor = const Duration(days: 365),
  }) => OperatorKey(key.publicIdentity.signingKey, notAfter: now.add(validFor));

  ServiceNoticeBoard board(
    List<Uint8List> envelopes, {
    List<OperatorKey>? keys,
    _Source? source,
  }) => ServiceNoticeBoard(
    source: source ?? _Source(envelopes),
    identities: identities,
    keys: keys ?? [pinned(operator)],
    clock: clock,
  );

  test('shows notices signed by a pinned key, newest serial first', () async {
    final notices = await board(
      [signed(notice(3)), signed(notice(9), spare), signed(notice(5))],
      keys: [pinned(operator), pinned(spare)],
    ).current();

    expect(notices.map((n) => n.serial), [9, 5, 3]);
    expect(notices.first, notice(9));
  });

  test('a notice signed by any other key is not shown', () async {
    final altered = signed(notice(4))..[2] ^= 1;

    final notices = await board([
      signed(notice(3), stranger),
      altered,
      signed(notice(5)),
    ]).current();

    expect(notices.map((n) => n.serial), [5]);
  });

  test('envelopes that do not parse are skipped', () async {
    final notices = await board([
      Uint8List(3),
      Uint8List.fromList([...signed(notice(2)), 0]),
      signed(notice(5)),
    ]).current();

    expect(notices.map((n) => n.serial), [5]);
  });

  test('a notice is shown until it expires', () async {
    final source = [
      signed(notice(1, lasts: const Duration(days: 1))),
      signed(notice(2, lasts: const Duration(days: 1, seconds: 1))),
    ];

    expect((await board(source).current()).map((n) => n.serial), [2]);
    clock.advance(const Duration(seconds: 1));
    expect(await board(source).current(), isEmpty);
  });

  test('a key stops counting at its notAfter, even for notices issued '
      'before', () async {
    final keys = [pinned(operator, validFor: const Duration(hours: 1))];
    final source = [signed(notice(1))];

    expect(await board(source, keys: keys).current(), hasLength(1));
    clock.advance(const Duration(hours: 1));
    expect(await board(source, keys: keys).current(), isEmpty);
  });

  test('a notice issued after its key\'s notAfter is not shown', () async {
    // A stolen key that has run out cannot date a notice after its end.
    final keys = [pinned(operator, validFor: const Duration(days: 2))];

    final notices = await board([
      signed(notice(1, issuedAgo: const Duration(days: -2))),
      signed(notice(2, issuedAgo: const Duration(days: -3))),
    ], keys: keys).current();

    expect(notices.map((n) => n.serial), [1]);
  });

  test('a closed notice stays closed', () async {
    final notices = await board([signed(notice(1)), signed(notice(2))])
        .current(dismissed: {1, 7});

    expect(notices.map((n) => n.serial), [2]);
  });

  test('for a serial seen twice, the first valid notice wins', () async {
    final notices = await board([
      signed(notice(4, text: 'Firmato da altri.'), stranger),
      signed(notice(4, text: 'Il primo valido.')),
      signed(notice(4, text: 'Il secondo.')),
    ]).current();

    expect(notices.single.texts['it'], 'Il primo valido.');
  });

  test('reads no more envelopes than may be published', () async {
    final notices = await board([
      for (var serial = 1; serial <= 17; serial++) signed(notice(serial)),
    ]).current();

    expect(notices, hasLength(ServiceNoticeBoard.maxPublished));
    expect(notices.first.serial, 16);
  });

  test('with no pinned key, nothing is fetched at all', () async {
    final source = _Source([signed(notice(1))]);

    expect(await board([], keys: [], source: source).current(), isEmpty);
    expect(source.fetches, 0);
  });
}
