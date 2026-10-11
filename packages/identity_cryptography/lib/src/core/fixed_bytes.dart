import 'dart:typed_data';

import 'cryptography_exception.dart';

/// Copies [source] after checking it is exactly [length] bytes long, so value
/// objects never alias a buffer the caller can still mutate.
Uint8List copyExactly(String valueObject, List<int> source, int length) {
  if (source.length != length) {
    throw InvalidLengthException(valueObject, length, source.length);
  }
  return Uint8List.fromList(source);
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int bytesHash(List<int> bytes) => Object.hashAll(bytes);
