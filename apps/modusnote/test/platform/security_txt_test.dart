import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `web/.well-known/security.txt` (RFC 9116) tells whoever finds a
/// vulnerability whom to write to; past its Expires date readers must
/// ignore it, so CI fails a month before.
void main() {
  final lines = File('web/.well-known/security.txt').readAsLinesSync();

  String field(String name) => lines
      .singleWhere((line) => line.startsWith('$name: '))
      .substring(name.length + 2);

  test('names the contact the privacy policy names', () {
    final privacy = File('web/privacy.html').readAsStringSync();
    expect(field('Contact'), startsWith('mailto:'));
    expect(privacy, contains('href="${field('Contact')}'));
    expect(
      File('../../SECURITY.md').readAsStringSync(),
      contains(field('Contact').substring('mailto:'.length)),
    );
  });

  test('is canonical on the app origin', () {
    expect(
      field('Canonical'),
      'https://modus.serv.run/.well-known/security.txt',
    );
  });

  test('has not expired, nor will within a month', () {
    final expires = DateTime.parse(field('Expires'));
    expect(expires.isUtc, isTrue);
    expect(
      expires.isAfter(DateTime.now().add(const Duration(days: 30))),
      isTrue,
      reason: 'renew Expires in web/.well-known/security.txt',
    );
  });
}
