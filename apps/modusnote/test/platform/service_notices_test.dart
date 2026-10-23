import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/notices/operator_keys.dart';
import 'package:offline_sync/offline_sync.dart';

import '../fonts_coverage_test.dart' show codePointsOf;
import '../vault/support.dart';

/// `web/notices.json` holds the operator's signed service notices, served
/// as a static file on the app's origin; `lib/notices/operator_keys.dart`
/// the keys the app pins to check them. What CI deploys must be what every
/// device accepts and can draw, and a pinned key must be replaced well
/// before it stops counting on devices that never update.
void main() {
  setUpAll(loadSodium);

  final now = DateTime.now().toUtc();
  final file = File('web/notices.json');
  final keys = operatorKeys();

  Map<String, Object?> read() {
    final json = jsonDecode(file.readAsStringSync());
    expect(json, isA<Map<String, Object?>>());
    json as Map<String, Object?>;
    expect(json.keys, contains('notices'));
    expect(json.keys, everyElement(isIn(['lastSerial', 'notices'])));
    return json;
  }

  List<String> published() => [
    for (final envelope in read()['notices']! as List) envelope as String,
  ];

  // A device never shows again a serial its person closed, so the tool
  // keeps the highest serial it signed and signs only above it.
  test('remembers a serial no lower than any it publishes', () {
    final lastSerial = read()['lastSerial'];
    for (final envelope in published()) {
      final notice = SignedServiceNotice.parse(base64.decode(envelope)).notice;
      expect(
        lastSerial is int && notice.serial <= lastSerial,
        isTrue,
        reason:
            'notice ${notice.serial} is above lastSerial $lastSerial: sign '
            'with tool/service_notice.dart in packages/offline_sync',
      );
    }
  });

  test('is a list of envelopes no device would cut short', () {
    final envelopes = published();
    expect(
      envelopes.length,
      lessThanOrEqualTo(ServiceNoticeBoard.maxPublished),
    );
    expect(
      file.lengthSync(),
      lessThanOrEqualTo(ServiceNoticeBoard.maxPublishedBytes),
    );
  });

  test('every notice is signed by a pinned key that still counts', () {
    final identities = SodiumIdentityService(sodium);
    for (final envelope in published()) {
      final signed = SignedServiceNotice.parse(base64.decode(envelope));
      final pinned = keys.where((key) {
        if (!now.isBefore(key.notAfter) ||
            signed.notice.issued.isAfter(key.notAfter)) {
          return false;
        }
        try {
          identities.verify(
            signed.signedMessage,
            signature: signed.signature,
            signer: key.key,
          );
          return true;
        } on InvalidSignatureException {
          return false;
        }
      });
      expect(
        pinned,
        isNotEmpty,
        reason:
            'notice ${signed.notice.serial} is not signed by a key '
            'pinned in lib/notices/operator_keys.dart that still counts',
      );
    }
  });

  test('no notice expired more than a month ago', () {
    for (final envelope in published()) {
      final notice = SignedServiceNotice.parse(base64.decode(envelope)).notice;
      expect(
        notice.expires.isAfter(now.subtract(const Duration(days: 30))),
        isTrue,
        reason:
            'notice ${notice.serial} expired: run '
            '`dart run tool/service_notice.dart prune` in packages/offline_sync',
      );
    }
  });

  // A character none of our fonts has makes Flutter on the web fetch one
  // from Google: the CSP blocks it, and the glyph would show as a box.
  test('the bundled fonts draw every character of every notice', () {
    final covered = {
      ...codePointsOf('assets/fonts/Inter-Variable.ttf'),
      ...codePointsOf('assets/fonts/NotoSansSymbols-Music.ttf'),
    };
    final missing = <String>{};
    for (final envelope in published()) {
      final notice = SignedServiceNotice.parse(base64.decode(envelope)).notice;
      for (final text in notice.texts.values) {
        for (final rune in text.runes) {
          if (rune != 0x0A && !covered.contains(rune)) {
            missing.add(
              'U+${rune.toRadixString(16).toUpperCase()} '
              'in notice ${notice.serial}',
            );
          }
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('every pinned key counts for six months more, and not over two '
      'years', () {
    for (final (:key, :notAfter) in pinnedOperatorKeys) {
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      final until = DateTime.parse(notAfter);
      expect(until.isUtc, isTrue, reason: '$notAfter must be in UTC');
      expect(
        until.isAfter(now.add(const Duration(days: 183))),
        isTrue,
        reason:
            'the operator key $key stops counting on $notAfter: pin a '
            'new one (tool/service_notice.dart keygen) and ship it',
      );
      expect(
        until.isBefore(now.add(const Duration(days: 2 * 366))),
        isTrue,
        reason: 'a pinned key counts for two years at most',
      );
    }
  });

  test('the keys the app pins are the ones listed', () {
    expect(keys, hasLength(pinnedOperatorKeys.length));
    for (final (index, (:key, notAfter: _)) in pinnedOperatorKeys.indexed) {
      expect(keys[index].key, PublicSigningKey.fromBytes(_hex(key)));
    }
  });
}

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];
