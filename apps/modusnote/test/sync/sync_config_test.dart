import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/sync_config.dart';

void main() {
  test('a build without a project has no sync', () {
    expect(SyncConfig.parse(url: '', anonKey: ''), isNull);
    expect(SyncConfig.parse(url: 'https://a.supabase.co', anonKey: ''), isNull);
    expect(SyncConfig.parse(url: '', anonKey: 'sb_publishable_x'), isNull);
    expect(SyncConfig.fromEnvironment(), isNull);
  });

  test('a project URL becomes the root the adapters resolve against', () {
    final config = SyncConfig.parse(
      url: 'https://abc.supabase.co',
      anonKey: 'sb_publishable_x',
    )!;

    expect(config.projectUrl, Uri.parse('https://abc.supabase.co/'));
    expect(config.anonKey, 'sb_publishable_x');
  });

  test('a local Supabase may use plain HTTP', () {
    expect(
      SyncConfig.parse(url: 'http://localhost:54321', anonKey: 'k'),
      isNotNull,
    );
  });

  group('adversary', () {
    for (final url in [
      'http://abc.supabase.co',
      'ftp://abc.supabase.co',
      'https://user:pw@abc.supabase.co',
      'https://abc.supabase.co/rest/v1',
      'https://abc.supabase.co/?next=evil',
      'https://abc.supabase.co/#x',
      'not a url',
    ]) {
      test('tokens never travel to $url', () {
        expect(
          () => SyncConfig.parse(url: url, anonKey: 'k'),
          throwsArgumentError,
        );
      });
    }
  });
}
