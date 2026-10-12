import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web client loads libsodium and SQLite as committed files from `web/`
/// (no CDN). They must be the exact builds the Dart packages expect, so a
/// package upgrade without `tool/fetch_web_assets.sh` fails here.
void main() {
  String locked(String package) {
    final lock = File('../../pubspec.lock').readAsStringSync();
    final entry = RegExp(
      '\n  $package:\n(?:      .*\n|    .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock);
    return entry![1]!;
  }

  test('sodium.js is the sumo build sodium 4.1.1+2 verifies', () {
    expect(locked('sodium'), '4.1.1+2');
    final digest = sha512.convert(File('web/sodium.js').readAsBytesSync());
    // HookConstants.jsSumoDist.hash in package:sodium 4.1.1+2.
    expect(
      digest.toString(),
      'd95956f041be5bcf8a9644027e3f4866138903a38f8fe84fdb0410a0076b0121'
      'e201379b8966281b2105c67b7c85e79df6e8a68eab0eea9a8dea48bfdaf0cd2a',
    );
  });

  test('sqlite3.wasm matches the sqlite3 package and the pinned hash', () {
    final script = File('tool/fetch_web_assets.sh').readAsStringSync();
    final version = RegExp(r'SQLITE3_VERSION=(\S+)').firstMatch(script)![1];
    final pinned = RegExp(r'SQLITE3_WASM_SHA256=(\S+)').firstMatch(script)![1];
    expect(locked('sqlite3'), version);
    final digest = sha256.convert(File('web/sqlite3.wasm').readAsBytesSync());
    expect(digest.toString(), pinned);
  });

  test('index.html loads sodium.js, from our origin, before Flutter', () {
    final index = File('web/index.html').readAsStringSync();
    final sodium = index.indexOf('<script src="sodium.js"');
    final flutter = index.indexOf('<script src="flutter_bootstrap.js"');
    expect(sodium, isNonNegative);
    expect(sodium, lessThan(flutter));
  });

  test('adversary: no script or stylesheet comes from another origin', () {
    final index = File('web/index.html').readAsStringSync();
    expect(index, isNot(matches(RegExp(r'''src=["']?(https?:)?//'''))));
    expect(index, isNot(matches(RegExp(r'''href=["']?(https?:)?//'''))));
  });
}
