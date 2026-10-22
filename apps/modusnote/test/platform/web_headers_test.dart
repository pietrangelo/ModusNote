import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The CSP is the web client's main defence: the page holds decrypted notes
/// and keys, so only our own code may run in it. These checks keep a
/// well-meant edit of `web/_headers` from opening it up.
/// The sync project and the R2 endpoint of the account that stores the
/// encrypted recordings: full origins, never a wildcard over other tenants.

void main() {
  final headers = <String, String>{};
  for (final line in File('web/_headers').readAsLinesSync()) {
    if (line.startsWith('  ') && line.contains(':')) {
      final colon = line.indexOf(':');
      headers[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
  }
  final csp = {
    for (final directive in headers['Content-Security-Policy']!.split(';'))
      if (directive.trim().isNotEmpty)
        directive.trim().split(' ').first: directive
            .trim()
            .split(' ')
            .skip(1)
            .toList(),
  };

  test('everything is denied unless a directive allows it', () {
    expect(csp['default-src'], ["'none'"]);
    expect(csp['object-src'], ["'none'"]);
    expect(csp['frame-ancestors'], ["'none'"]);
    expect(csp['form-action'], ["'none'"]);
    expect(csp['base-uri'], ["'self'"]);
  });

  test('scripts come only from our origin, compiled WebAssembly included', () {
    expect(csp['script-src'], ["'self'", "'wasm-unsafe-eval'"]);
    expect(csp['worker-src'], ["'self'", 'blob:']);
  });

  test('the page connects only to its own origin', () {
    expect(csp['connect-src'], ["'self'"]);
  });

  test('DOM sinks need Trusted Types: Flutter\'s policy and our default', () {
    expect(csp['require-trusted-types-for'], ["'script'"]);
    expect(csp['trusted-types'], ['flutter-js', 'default']);
  });

  test('cross-origin isolation and the other hardening headers', () {
    expect(headers['Cross-Origin-Opener-Policy'], 'same-origin');
    expect(headers['Cross-Origin-Embedder-Policy'], 'require-corp');
    expect(headers['Cross-Origin-Resource-Policy'], 'same-origin');
    expect(headers['X-Content-Type-Options'], 'nosniff');
    expect(headers['Referrer-Policy'], 'no-referrer');
    expect(headers['X-Frame-Options'], 'DENY');
    expect(headers['Permissions-Policy'], contains('microphone=(self)'));
    expect(headers['Strict-Transport-Security'], startsWith('max-age='));
  });

  test('the engine\'s stylesheets are allowed in every browser and build', () {
    // Flutter's engine writes two <style> elements whose text depends on the
    // browser (StyleManager.attachGlobalStyles) and on the compiler: dart2js
    // prints the 14.0 px default font size as "14px", dart2wasm as "14.0px".
    // The Chrome end-to-end run sees only Chrome's; a missing hash for
    // another browser goes unnoticed until someone opens it there.
    final allowed = csp['style-src']!.toSet();
    for (final browser in _Browser.values) {
      for (final fontSize in ['14px', '14.0px']) {
        for (final prefix in ['flutter-view', '']) {
          final hash = base64.encode(
            sha256
                .convert(utf8.encode(_engineCss(prefix, fontSize, browser)))
                .bytes,
          );
          expect(
            allowed,
            contains("'sha256-$hash'"),
            reason: '${browser.name}, $fontSize, "$prefix"',
          );
        }
      }
    }
  });

  group('adversary', () {
    test('no inline code, no eval, no wildcard, no other host', () {
      final values = csp.values.expand((sources) => sources);
      expect(values, isNot(contains("'unsafe-inline'")));
      expect(values, isNot(contains("'unsafe-eval'")));
      expect(values, isNot(contains('*')));
      for (final MapEntry(key: directive, value: sources) in csp.entries) {
        for (final source in sources) {
          expect(
            source,
            isNot(matches(RegExp(r'^(https?:|wss?:|data:$)'))),
            reason: '$directive $source',
          );
        }
      }
    });

    test('inline styles are allowed only by hash', () {
      expect(csp['style-src']!.first, "'self'");
      for (final source in csp['style-src']!.skip(1)) {
        expect(source, matches(RegExp(r"^'sha256-[A-Za-z0-9+/]{43}='$")));
      }
    });

    test('the Trusted Types policy loads first and blocks the page', () {
      final index = File('web/index.html').readAsStringSync();
      final scripts = RegExp(r'<script [^>]*>').allMatches(index).toList();
      expect(scripts.first[0], '<script src="trusted_types.js">');
    });
  });
}

enum _Browser { chrome, edge, firefox, safari }

/// The text of `applyGlobalCssRulesToSheet` in Flutter's web engine
/// (`lib/_engine/engine/view_embedder/style_manager.dart`), for one browser.
String _engineCss(String p, String fontSize, _Browser browser) {
  final css = StringBuffer(
    '$p flt-scene-host {  font: normal normal $fontSize sans-serif;}'
    '$p flt-semantics input[type=range] {  appearance: none;'
    '  -webkit-appearance: none;  width: 100%;  position: absolute;'
    '  border: none;  top: 0;  right: 0;  bottom: 0;  left: 0;}'
    '$p input::selection {  background-color: transparent;}'
    '$p textarea::selection {  background-color: transparent;}'
    '$p flt-semantics input,$p flt-semantics textarea,'
    '$p flt-semantics [contentEditable="true"] {  caret-color: transparent;}'
    '$p .flt-text-editing::placeholder {  opacity: 0;}'
    '$p:focus { outline: rgb(0, 0, 0) none 0px;}',
  );
  if (browser == _Browser.safari) {
    css.write(
      '$p * {  -webkit-tap-highlight-color: transparent;}'
      '$p flt-semantics input[type=range]::-webkit-slider-thumb {'
      '  -webkit-appearance: none;}',
    );
  }
  if (browser == _Browser.firefox) {
    css.write('$p flt-paragraph,$p flt-span {  line-height: 100%;}');
  }
  if (browser != _Browser.firefox) {
    css.write(
      '$p .transparentTextEditing:-webkit-autofill,'
      '$p .transparentTextEditing:-webkit-autofill:hover,'
      '$p .transparentTextEditing:-webkit-autofill:focus,'
      '$p .transparentTextEditing:-webkit-autofill:active {'
      '  opacity: 0 !important;}',
    );
  }
  if (browser == _Browser.edge) {
    css.write('$p input::-ms-reveal {  display: none;}');
  }
  return css.toString();
}
