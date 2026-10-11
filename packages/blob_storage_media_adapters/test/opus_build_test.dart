import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:blob_storage_media_adapters/src/opus/opus_build.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

List<int> tarGz(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.addFile(ArchiveFile.bytes(name, utf8.encode(content)));
  });
  return const GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

void main() {
  late Directory out;

  setUp(() => out = Directory.systemTemp.createTempSync('opus_build_'));
  tearDown(() => out.deleteSync(recursive: true));

  test('a matching archive is extracted', () {
    final bytes = tarGz({'opus-1.0/src/opus.c': 'int x;'});

    verifyAndExtract(
      bytes,
      into: out,
      expectedSha256: sha256.convert(bytes).toString(),
    );

    expect(
      File('${out.path}/opus-1.0/src/opus.c').readAsStringSync(),
      'int x;',
    );
  });

  test('source lists are read from upstream makefiles', () {
    final makefile = File('${out.path}/sources.mk')
      ..writeAsStringSync(
        'OTHER = \\\nx.c\n\nOPUS_SOURCES = \\\nsrc/a.c \\\nsrc/b.c\n\nNEXT = y.c\n',
      );

    expect(sourcesFrom(makefile, 'OPUS_SOURCES'), ['src/a.c', 'src/b.c']);
    expect(() => sourcesFrom(makefile, 'MISSING'), throwsStateError);
  });

  group('adversary', () {
    test('an archive with another hash is refused before extraction', () {
      final bytes = tarGz({'opus-1.0/src/opus.c': 'int backdoor;'});

      expect(
        () => verifyAndExtract(bytes, into: out, expectedSha256: '0' * 64),
        throwsStateError,
      );
      expect(out.listSync(), isEmpty);
    });

    test('an entry escaping the build directory is refused', () {
      final bytes = tarGz({'../escaped.c': 'int x;'});

      expect(
        () => verifyAndExtract(
          bytes,
          into: out,
          expectedSha256: sha256.convert(bytes).toString(),
        ),
        throwsStateError,
      );
      expect(File('${out.parent.path}/escaped.c').existsSync(), isFalse);
    });
  });
}
