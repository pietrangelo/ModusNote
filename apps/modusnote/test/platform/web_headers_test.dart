import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The CSP is the web client's main defence: the page holds decrypted notes
/// and keys, so only our own code may run in it. These checks keep a
/// well-meant edit of `web/_headers` from opening it up.
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

  group('adversary', () {
    test('no inline code, no eval, no wildcard, no other host', () {
      final values = csp.values.expand((sources) => sources);
      expect(values, isNot(contains("'unsafe-inline'")));
      expect(values, isNot(contains("'unsafe-eval'")));
      expect(values, isNot(contains('*')));
      for (final source in values) {
        expect(
          source,
          isNot(matches(RegExp(r'^(https?:|wss?:|data:$)'))),
          reason: source,
        );
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
