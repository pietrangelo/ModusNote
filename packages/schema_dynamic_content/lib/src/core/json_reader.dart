import 'dart:convert';

/// Strict JSON reading shared by the codecs of this context. Not exported:
/// each codec turns [JsonShapeException] into its own public format error.
final class JsonShapeException implements Exception {
  const JsonShapeException(this.message);

  final String message;

  @override
  String toString() => 'JsonShapeException: $message';
}

/// Parses [document] after bounding its nesting: jsonDecode recurses per
/// level, so an unbounded `[[[[...]]]]` could overflow the stack.
Object? parseBoundedJson(String document, {required int maxDepth}) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final unit in document.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5C) {
        escaped = true;
      } else if (unit == 0x22) {
        inString = false;
      }
    } else if (unit == 0x22) {
      inString = true;
    } else if (unit == 0x5B || unit == 0x7B) {
      if (++depth > maxDepth) {
        throw const JsonShapeException('nesting too deep');
      }
    } else if (unit == 0x5D || unit == 0x7D) {
      depth--;
    }
  }
  try {
    return jsonDecode(document);
  } on FormatException {
    throw const JsonShapeException('not valid JSON');
  }
}

/// A JSON object read strictly: wrong types and stray keys are format errors,
/// never `TypeError`s leaking out of the parser.
extension type JsonObject._(Map<String, Object?> _map) {
  factory JsonObject.of(Object? value, String what) => switch (value) {
    Map<String, Object?>() => JsonObject._(value),
    _ => throw JsonShapeException('$what must be an object'),
  };

  bool has(String key) => _map.containsKey(key);

  void allowOnly(Set<String> keys) {
    for (final key in _map.keys) {
      if (!keys.contains(key)) {
        throw JsonShapeException('unexpected property "$key"');
      }
    }
  }

  T _get<T>(String key, String expected) => switch (_map[key]) {
    final T value => value,
    _ => throw JsonShapeException('"$key" must be $expected'),
  };

  String string(String key) => _get<String>(key, 'a string');
  int integer(String key) => _get<int>(key, 'an integer');
  bool boolean(String key) => _get<bool>(key, 'a boolean');
  JsonObject object(String key) => JsonObject.of(_map[key], '"$key"');

  num number(String key) => _get<num>(key, 'a number');

  num? optionalNumber(String key) =>
      has(key) ? _get<num>(key, 'a number') : null;

  List<JsonObject> objects(String key) => [
    for (final item in _get<List<Object?>>(key, 'a list'))
      JsonObject.of(item, 'an item of "$key"'),
  ];

  List<String> strings(String key) => [
    for (final item in _get<List<Object?>>(key, 'a list'))
      switch (item) {
        final String s => s,
        _ => throw JsonShapeException('"$key" must hold strings'),
      },
  ];

  Map<String, Object?> get entries => _map;

  List<int> integers(String key) => [
    for (final item in _get<List<Object?>>(key, 'a list'))
      switch (item) {
        final int i => i,
        _ => throw JsonShapeException('"$key" must hold integers'),
      },
  ];

  R let<R>(R Function(JsonObject) f) => f(this);
}
