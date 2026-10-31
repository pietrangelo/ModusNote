part of 'modus_server.dart';

/// [SiteGateway] on the sync server's `/api/s/`: every request signed by
/// the site's own key, never the device's, and claiming a name paid with a
/// proof of work (purpose 3) instead of an account.
final class _Sites implements SiteGateway {
  _Sites(this._server);

  final ModusServer _server;

  static const _proofOfWorkPurpose = 3;

  Future<void> _call(
    SiteKey key,
    String method,
    String path, {
    Object? json,
    Uint8List? raw,
    Map<int, Exception> meaning = const {},
  }) async {
    final body =
        raw ??
        (json == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(json))));
    try {
      await _server._call(
        method,
        path,
        body: body,
        contentType: raw != null
            ? 'application/octet-stream'
            : json == null
            ? null
            : 'application/json',
        signedBody: raw == null ? null : Uint8List(0),
        authorize: key.authorize,
        adjustClock: key.adjustClock,
        meaning: {..._meaning, ...meaning},
      );
    } on ServerUnavailableException {
      throw const PublishingUnavailableException();
    } on MalformedSyncDataException {
      // The answer is not read beyond its status.
      return;
    } on NotAdmittedException {
      throw const PublishingRejectedException(PublishingRejection.notOwner);
    } on SyncServerRejectedException {
      throw const PublishingRejectedException(PublishingRejection.invalid);
    }
  }

  static const _meaning = <int, Exception>{
    400: PublishingRejectedException(PublishingRejection.invalid),
    401: PublishingRejectedException(PublishingRejection.notOwner),
    403: PublishingRejectedException(PublishingRejection.notOwner),
    404: PublishingRejectedException(PublishingRejection.notOwner),
    411: PublishingRejectedException(PublishingRejection.invalid),
    413: PublishingRejectedException(PublishingRejection.limit),
    422: PublishingRejectedException(PublishingRejection.invalid),
  };

  @override
  Future<void> claim(
    SiteKey key,
    SiteName name,
    Map<String, Object> settings,
  ) async {
    final Map<String, Object> pow;
    try {
      pow = await _server.proofOfWork(
        _proofOfWorkPurpose,
        ascii.encode(name.value),
      );
    } on ServerUnavailableException {
      throw const PublishingUnavailableException();
    } on MalformedSyncDataException {
      throw const PublishingUnavailableException();
    }
    await _call(
      key,
      'POST',
      's/${name.value}',
      json: {'settings': settings, 'pow': pow},
      meaning: const {409: SiteNameTakenException()},
    );
  }

  @override
  Future<void> putSettings(
    SiteKey key,
    SiteName name,
    Map<String, Object> settings,
  ) => _call(key, 'PUT', 's/${name.value}', json: settings);

  @override
  Future<void> deleteSite(SiteKey key, SiteName name) =>
      _call(key, 'DELETE', 's/${name.value}');

  @override
  Future<void> putPage(
    SiteKey key,
    SiteName name,
    PageSlug slug,
    Map<String, Object> page,
  ) => _call(key, 'PUT', 's/${name.value}/p/${slug.value}', json: page);

  @override
  Future<void> deletePage(SiteKey key, SiteName name, PageSlug slug) =>
      _call(key, 'DELETE', 's/${name.value}/p/${slug.value}');

  @override
  Future<void> putMedia(
    SiteKey key,
    SiteName name,
    MediaId id,
    MediaKind kind,
    Uint8List bytes,
  ) => _call(
    key,
    'PUT',
    's/${name.value}/m/${id.value}?type=${kind.name}',
    raw: bytes,
  );

  @override
  Future<void> deleteMedia(SiteKey key, SiteName name, MediaId id) =>
      _call(key, 'DELETE', 's/${name.value}/m/${id.value}');
}
