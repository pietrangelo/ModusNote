import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Build-time helpers for `hook/build.dart`, kept here so they are tested.

/// Extracts a `.tar.gz` into [into] only if its SHA-256 is
/// [expectedSha256]; nothing is written for an archive that does not match,
/// and no entry may land outside [into].
void verifyAndExtract(
  List<int> bytes, {
  required Directory into,
  required String expectedSha256,
}) {
  final actual = sha256.convert(bytes).toString();
  if (actual != expectedSha256) {
    throw StateError(
      'archive hash mismatch: expected $expectedSha256, got $actual',
    );
  }
  final root = p.normalize(into.absolute.path);
  final archive = TarDecoder().decodeBytes(
    const GZipDecoder().decodeBytes(bytes),
  );
  for (final entry in archive) {
    final target = p.normalize(p.join(root, entry.name));
    if (!p.isWithin(root, target)) {
      throw StateError('archive entry escapes the build directory');
    }
  }
  for (final entry in archive) {
    if (!entry.isFile) continue;
    File(p.join(root, entry.name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(entry.content);
  }
}

/// Reads `VARIABLE = a.c \ b.c` from libopus's own source lists, so the
/// build follows upstream instead of a copy that could drift.
List<String> sourcesFrom(File makefile, String variable) {
  final lines = makefile.readAsLinesSync();
  final start = lines.indexWhere((line) => line.trim() == '$variable = \\');
  if (start < 0) throw StateError('$variable not found in ${makefile.path}');
  final sources = <String>[];
  for (final line in lines.skip(start + 1)) {
    final entry = line.replaceAll('\\', '').trim();
    if (entry.isNotEmpty) sources.add(entry);
    if (!line.trimRight().endsWith('\\')) break;
  }
  return sources;
}

/// System libraries libopus links against on [os]. Its float code calls
/// `exp`, `log` and friends, which bionic (Android) and glibc keep in
/// `libm`; Apple's libSystem and the MSVC runtime already include them.
List<String> systemLibrariesFor(OS os) => switch (os) {
  OS.android || OS.linux => const ['m'],
  _ => const [],
};
