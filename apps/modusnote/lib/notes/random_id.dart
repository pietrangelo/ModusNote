import 'dart:math';

/// Opaque and random: ids reach the server in clear, so they must not
/// reveal order, time or device. 128 bits as 32 hex digits, the shape of
/// the record id the vault stores the thing under.
String randomRecordId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
