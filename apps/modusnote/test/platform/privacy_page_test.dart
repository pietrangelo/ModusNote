import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `web/privacy.html` is the privacy policy Google Play links to, served
/// under the same CSP as the app: it must stay static and same-origin, and
/// keep the account-deletion anchor the store listing points at.
void main() {
  final html = File('web/privacy.html').readAsStringSync();
  final terms = File('web/terms.html').readAsStringSync();

  test('has no scripts, inline styles or other origins', () {
    for (final page in [html, terms]) {
      expect(page, isNot(contains('<script')));
      expect(page, isNot(contains('<style')));
      expect(page, isNot(contains(' style=')));
      // Links may point elsewhere (the Garante); nothing is loaded from there.
      expect(RegExp(r'''src="(https?:)?//''').hasMatch(page), isFalse);
      expect(
        RegExp(r'''<link[^>]*href="(https?:)?//''').hasMatch(page),
        isFalse,
      );
    }
  });

  test('links terms of service that keep the limits of Italian law', () {
    expect(html, contains('href="terms.html"'));
    expect(terms, contains('href="privacy.html"'));
    expect(terms, contains('id="english"'));
    // A liability waiver cannot cover wilful misconduct, gross negligence or
    // consumer rights; the page must say so or the clause risks being void.
    expect(terms, contains('art. 1229 del Codice civile'));
    expect(terms, contains('Codice del consumo'));
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

  test('says what a syncing app reads and keeps open on the server', () {
    expect(html, contains('avvisi del gestore firmati'));
    expect(html, contains('connessione aperta'));
    expect(html, contains("operator's signed notices"));
    expect(html, contains('open connection'));
  });

  test('explains account deletion where the store listing links', () {
    expect(html, contains('id="elimina-account"'));
    expect(html, contains('id="delete-account"'));
    expect(html, contains('mailto:'));
  });
}
