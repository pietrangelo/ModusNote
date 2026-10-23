import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import '../core/service_notice.dart';
import '../core/sync_exception.dart';
import 'ports.dart';

/// An operator key the app pins, with the instant it stops counting: a
/// stolen key runs out on its own, even on devices that never update.
@immutable
final class OperatorKey {
  const OperatorKey(this.key, {required this.notAfter});

  final PublicSigningKey key;

  /// No notice signed by [key] is shown from this instant on, nor one it
  /// dates after it.
  final DateTime notAfter;
}

/// Use case: the service notices to show now, from what the server hands
/// out, checked against the operator keys the app pins: the server has no
/// such key, so it can withhold a notice but never write or alter one.
final class ServiceNoticeBoard {
  ServiceNoticeBoard({
    required this._source,
    required this._identities,
    required List<OperatorKey> keys,
    required this._clock,
  }) : _keys = List.unmodifiable(keys);

  /// How many envelopes `notices.json` may publish, and what it may
  /// weigh: a device reads no more, and the operator's tool writes no
  /// more.
  static const maxPublished = 16;
  static const maxPublishedBytes = 64 * 1024;

  final ServiceNoticeSource _source;
  final IdentityService _identities;
  final List<OperatorKey> _keys;
  final Clock _clock;

  /// The notices signed by a pinned key, issued before its `notAfter`,
  /// neither expired nor in [dismissed] (closed by the person), newest
  /// serial first. Of two notices with one serial, the first valid one
  /// counts. With no key pinned, service notices are off and nothing is
  /// fetched.
  Future<List<ServiceNotice>> current({Set<int> dismissed = const {}}) async {
    if (_keys.isEmpty) return const [];
    final envelopes = await _source.fetch();
    final now = _clock.now();
    final shown = <int, ServiceNotice>{};
    for (final envelope in envelopes.take(maxPublished)) {
      final SignedServiceNotice signed;
      try {
        signed = SignedServiceNotice.parse(envelope);
      } on MalformedSyncDataException {
        continue;
      }
      final notice = signed.notice;
      if (shown.containsKey(notice.serial) ||
          !_pinned(signed, now) ||
          !now.isBefore(notice.expires) ||
          dismissed.contains(notice.serial)) {
        continue;
      }
      shown[notice.serial] = notice;
    }
    return shown.values.toList()..sort((a, b) => b.serial - a.serial);
  }

  /// Whether a key that still counts at [now] signed [signed] before its
  /// `notAfter`.
  bool _pinned(SignedServiceNotice signed, DateTime now) {
    for (final OperatorKey(:key, :notAfter) in _keys) {
      if (!now.isBefore(notAfter) || signed.notice.issued.isAfter(notAfter)) {
        continue;
      }
      try {
        _identities.verify(
          signed.signedMessage,
          signature: signed.signature,
          signer: key,
        );
        return true;
      } on InvalidSignatureException {
        continue;
      }
    }
    return false;
  }
}
