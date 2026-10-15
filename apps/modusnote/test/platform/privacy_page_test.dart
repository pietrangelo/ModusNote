import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `web/privacy.html` is the privacy policy Google Play links to, served
/// under the same CSP as the app: it must stay static and same-origin, and
/// keep the account-deletion anchor the store listing points at.
void main() {
  final html = File('web/privacy.html').readAsStringSync();

  test('has no scripts, inline styles or other origins', () {
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<style')));
    expect(html, isNot(contains(' style=')));
    // Links may point elsewhere (the Garante); nothing is loaded from there.
    expect(RegExp(r'''src="(https?:)?//''').hasMatch(html), isFalse);
    expect(RegExp(r'''<link[^>]*href="(https?:)?//''').hasMatch(html), isFalse);
  });

  test('names the controller and what article 13 GDPR asks for', () {
    expect(html, isNot(contains('[TITOLARE]')));
    for (final heading in [
      'Titolare del trattamento',
      'Conservazione',
      'trasferimenti fuori dall',
      'I tuoi diritti',
    ]) {
      expect(html, contains(heading));
    }
    expect(html, contains('art. 6, par. 1, lett. b'));
    expect(html, contains('Garante per la protezione dei dati personali'));
  });

  test('explains account deletion where the store listing links', () {
    expect(html, contains('id="elimina-account"'));
    expect(html, contains('id="delete-account"'));
    expect(html, contains('mailto:'));
  });
}
