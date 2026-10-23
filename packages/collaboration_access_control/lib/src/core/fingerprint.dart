/// The start of [bytes] as people compare it between two screens: the
/// first eight bytes in upper-case hex, in four groups of four.
String fingerprintOf(List<int> bytes) {
  final hex = bytes
      .take(8)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
      .join(' ');
}
