import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/media.dart';
import '../core/names.dart';
import '../core/site_book.dart';

/// A site's signing key, open in memory until [release]: whoever holds it
/// may change the site. It is the site's own key, never the device's, so
/// serv.pub cannot tell which vault or workspace a site belongs to.
abstract interface class SiteKey {
  /// The `Authorization` header for [method] on [path] (with its query,
  /// exactly as sent) carrying [body].
  Future<String> authorize(String method, String path, Uint8List body);

  /// Takes the server's time, after it refused a request as too far from
  /// its own.
  void adjustClock(DateTime server);

  void release();
}

/// Port: where the keys of this device's sites are kept, sealed in the
/// vault and never synced.
abstract interface class SiteKeys {
  /// Null when this device has no key for [name].
  Future<SiteKey?> open(SiteName name);

  /// A new key for [name], kept before it is returned, replacing any
  /// earlier one.
  Future<SiteKey> create(SiteName name);

  Future<void> forget(SiteName name);
}

/// Port: what this device knows of its site, sealed in the vault.
abstract interface class SiteBookStore {
  Future<SiteBook?> load();

  /// Saves [book], or forgets the site when null.
  Future<void> save(SiteBook? book);
}

/// A clean copy of a picture or recording, ready to upload.
@immutable
final class PreparedMedia {
  const PreparedMedia(this.kind, this.bytes);

  final MediaKind kind;
  final Uint8List bytes;
}

/// Port: turns a blob of the vault into what may be published. Pictures
/// are decoded and encoded again, so no metadata of the original (place,
/// time, device) survives; recordings are passed as they are only in a
/// container serv.pub takes. Null when the blob cannot be published.
abstract interface class PublicationMedia {
  Future<PreparedMedia?> prepare(BlobId blob);
}

/// Port: serv.pub's signed API (`/api/s/` on the sync server). Every call
/// throws [PublishingUnavailableException] when the server cannot be
/// reached, [PublishingRejectedException] when it refuses for good.
abstract interface class SiteGateway {
  /// Takes [name] for [key]; the same key again is fine. Throws
  /// [SiteNameTakenException] when another key holds it.
  Future<void> claim(SiteKey key, SiteName name, Map<String, Object> settings);

  Future<void> putSettings(
    SiteKey key,
    SiteName name,
    Map<String, Object> settings,
  );

  /// Withdraws the whole site, its pages and files; the name is free again.
  Future<void> deleteSite(SiteKey key, SiteName name);

  Future<void> putPage(
    SiteKey key,
    SiteName name,
    PageSlug slug,
    Map<String, Object> page,
  );

  Future<void> deletePage(SiteKey key, SiteName name, PageSlug slug);

  Future<void> putMedia(
    SiteKey key,
    SiteName name,
    MediaId id,
    MediaKind kind,
    Uint8List bytes,
  );

  Future<void> deleteMedia(SiteKey key, SiteName name, MediaId id);
}
