import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/finalize_web_build.dart';

/// `tool/finalize_web_build.dart` runs after `flutter build web`: it pins
/// the scripts of index.html with Subresource Integrity and lists the hash
/// of every file served, so a deployed bundle can be compared with the one
/// CI built.
void main() {
  late Directory build;

  setUp(() {
    build = Directory.systemTemp.createTempSync('web_build_test');
    File('${build.path}/index.html').writeAsStringSync(
      '<html><head>\n'
      '<script src="trusted_types.js"></script>\n'
      '</head><body>\n'
      '<script src="sodium.js" async></script>\n'
      '<script src="flutter_bootstrap.js" async></script>\n'
      '</body></html>\n',
    );
    for (final name in [
      'trusted_types.js',
      'sodium.js',
      'flutter_bootstrap.js',
    ]) {
      File('${build.path}/$name').writeAsStringSync('// $name');
    }
    Directory('${build.path}/assets').createSync();
    File('${build.path}/assets/data.bin').writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => build.deleteSync(recursive: true));

  String sri(String name) =>
      'sha384-${base64.encode(sha384.convert(File('${build.path}/$name').readAsBytesSync()).bytes)}';

  test('every script of index.html carries its integrity hash', () {
    finalizeWebBuild(build);
    final index = File('${build.path}/index.html').readAsStringSync();
    expect(
      index,
      contains(
        '<script src="trusted_types.js" '
        'integrity="${sri('trusted_types.js')}"></script>',
      ),
    );
    expect(
      index,
      contains(
        '<script src="sodium.js" async '
        'integrity="${sri('sodium.js')}"></script>',
      ),
    );
    expect(
      index,
      contains(
        '<script src="flutter_bootstrap.js" async '
        'integrity="${sri('flutter_bootstrap.js')}"></script>',
      ),
    );
  });

  test('SHA256SUMS lists every served file, index.html as finalized', () {
    finalizeWebBuild(build);
    final sums = File('${build.path}/SHA256SUMS').readAsLinesSync();
    final listed = {
      for (final line in sums) line.substring(66): line.substring(0, 64),
    };
    expect(listed.keys, [
      'assets/data.bin',
      'flutter_bootstrap.js',
      'index.html',
      'sodium.js',
      'trusted_types.js',
    ]);
    listed.forEach((path, hash) {
      final bytes = File('${build.path}/$path').readAsBytesSync();
      expect(hash, sha256.convert(bytes).toString(), reason: path);
    });
  });

  group('adversary', () {
    test('a script from another origin fails the build', () {
      File(
        '${build.path}/index.html',
      ).writeAsStringSync('<script src="https://cdn.example/x.js"></script>');
      expect(() => finalizeWebBuild(build), throwsStateError);
    });

    test('a script missing from the bundle fails the build', () {
      File('${build.path}/sodium.js').deleteSync();
      expect(
        () => finalizeWebBuild(build),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a second run is refused instead of hashing twice', () {
      finalizeWebBuild(build);
      expect(() => finalizeWebBuild(build), throwsStateError);
    });

    test('an inline script fails the build', () {
      File('${build.path}/index.html')
          .writeAsStringSync('<script>alert(1)</script>');
      expect(() => finalizeWebBuild(build), throwsStateError);
    });
  });
}
