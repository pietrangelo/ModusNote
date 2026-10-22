import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/sync_config.dart';

void main() {
  test('a native build without a server has no sync', () {
    expect(SyncConfig.parse(''), isNull);
    expect(SyncConfig.fromEnvironment(), isNull);
  });

  test('the web client without one talks to its own origin', () {
    final config = SyncConfig.fromEnvironment(
      page: Uri.parse('https://modus.serv.run/index.html?x=1#notes'),
    )!;

    expect(config.origin, Uri.parse('https://modus.serv.run'));
  });

  test('a server URL becomes the origin the adapters resolve against', () {
    expect(
      SyncConfig.parse('https://modus.serv.run/')!.origin,
      Uri.parse('https://modus.serv.run'),
    );
  });

  test('a server on this machine may use plain HTTP', () {
    expect(SyncConfig.parse('http://localhost:8787'), isNotNull);
    expect(SyncConfig.parse('http://127.0.0.1:8787'), isNotNull);
  });

  group('adversary', () {
    for (final url in [
      'http://modus.serv.run',
      'ftp://modus.serv.run',
      'https://user:pass@modus.serv.run',
      'https://modus.serv.run/api',
      'https://modus.serv.run/?next=evil',
      'https://modus.serv.run/#x',
      'not a url',
    ]) {
      test('requests never travel to $url', () {
        expect(() => SyncConfig.parse(url), throwsArgumentError);
      });
    }
  });
}
