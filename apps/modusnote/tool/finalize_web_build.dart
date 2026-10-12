import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Run from `apps/modusnote` after `flutter build web`:
///
///     dart run tool/finalize_web_build.dart [build/web]
///
/// Pins every script of index.html with Subresource Integrity and writes
/// `SHA256SUMS`, the hash of every file in the bundle, which CI publishes so
/// that what a server delivers can be checked against what CI built.
void main(List<String> arguments) {
  final build = Directory(arguments.isEmpty ? 'build/web' : arguments.single);
  finalizeWebBuild(build);
  stdout.write(File('${build.path}/SHA256SUMS').readAsStringSync());
}

void finalizeWebBuild(Directory build) {
  final index = File('${build.path}/index.html');
  final html = index.readAsStringSync();
  if (RegExp(r'<script(?![^>]*\ssrc=)[^>]*>').hasMatch(html)) {
    throw StateError('index.html has an inline script');
  }
  final pinned = html.replaceAllMapped(
    RegExp(r'<script src="([^"]+)"([^>]*)></script>'),
    (match) {
      final source = match[1]!;
      final attributes = match[2]!;
      if (attributes.contains('integrity=')) {
        throw StateError('index.html is already finalized');
      }
      if (source.contains(':') || source.startsWith('//')) {
        throw StateError('$source is not served from our origin');
      }
      final bytes = File('${build.path}/$source').readAsBytesSync();
      final hash = base64.encode(sha384.convert(bytes).bytes);
      return '<script src="$source"$attributes '
          'integrity="sha384-$hash"></script>';
    },
  );
  index.writeAsStringSync(pinned);

  final root = build.absolute.path;
  final files =
      build
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.absolute.path.substring(root.length + 1))
          .where((path) => path != 'SHA256SUMS')
          .toList()
        ..sort();
  File('${build.path}/SHA256SUMS').writeAsStringSync(
    [
      for (final path in files)
        '${sha256.convert(File('$root/$path').readAsBytesSync())}  $path\n',
    ].join(),
  );
}
