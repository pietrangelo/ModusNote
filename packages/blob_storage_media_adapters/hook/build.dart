import 'dart:io';
import 'dart:typed_data';

import 'package:blob_storage_media_adapters/src/opus/opus_build.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds libopus from the official release, pinned by SHA-256, into the
/// code asset behind `lib/src/opus/opus_bindings.dart`.
///
/// Same trust model as libsodium: no prebuilt binary and no third-party
/// wrapper; the archive is rejected unless its hash matches the one below,
/// which CI also checks against xiph.org's published SHA256SUMS.
const opusVersion = '1.5.2';
const opusSha256 =
    '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1';
final opusArchiveUrl = Uri.parse(
  'https://github.com/xiph/opus/releases/download/v$opusVersion/'
  'opus-$opusVersion.tar.gz',
);

/// Points at a local copy of the archive for offline builds; the hash is
/// checked all the same.
const archiveOverride = 'MODUSNOTE_OPUS_ARCHIVE';

void main(List<String> args) async => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;

  final logger = Logger('libopus')
    ..onRecord.listen((record) => stderr.writeln(record.message));
  final shared = Directory.fromUri(input.outputDirectoryShared);
  final source = await _extractedSources(shared);

  List<String> listed(String makefile, String variable) => sourcesFrom(
    File('${source.path}/$makefile'),
    variable,
  ).map((relative) => '${source.path}/$relative').toList();

  await CBuilder.library(
    name: 'modusnote_opus',
    assetName: 'src/opus/opus_bindings.dart',
    sources: [
      ...listed('opus_sources.mk', 'OPUS_SOURCES'),
      ...listed('opus_sources.mk', 'OPUS_SOURCES_FLOAT'),
      ...listed('celt_sources.mk', 'CELT_SOURCES'),
      ...listed('silk_sources.mk', 'SILK_SOURCES'),
      ...listed('silk_sources.mk', 'SILK_SOURCES_FLOAT'),
      'native/modusnote_opus.c',
    ],
    includes: [
      '${source.path}/include',
      '${source.path}/celt',
      '${source.path}/silk',
      '${source.path}/silk/float',
    ],
    // Portable C only: no runtime CPU dispatch to keep one code path on
    // every target; voice at 48 kHz mono is cheap without SIMD.
    libraries: systemLibrariesFor(input.config.code.targetOS),
    defines: {
      'OPUS_BUILD': null,
      'VAR_ARRAYS': null,
      'HAVE_LRINT': null,
      'HAVE_LRINTF': null,
    },
  ).run(input: input, output: output, logger: logger);
});

Future<Directory> _extractedSources(Directory shared) async {
  final root = Directory('${shared.path}/opus-$opusVersion');
  final marker = File('${root.path}/.modusnote-verified');
  if (marker.existsSync()) return root;

  verifyAndExtract(
    await _archiveBytes(),
    into: shared,
    expectedSha256: opusSha256,
  );
  marker.writeAsStringSync(opusSha256);
  return root;
}

Future<List<int>> _archiveBytes() async {
  final local = Platform.environment[archiveOverride];
  if (local != null && local.isNotEmpty) return File(local).readAsBytes();

  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final response = await (await client.getUrl(opusArchiveUrl)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: opusArchiveUrl);
    }
    final bytes = BytesBuilder(copy: false);
    await response.forEach(bytes.add);
    return bytes.takeBytes();
  } finally {
    client.close();
  }
}
