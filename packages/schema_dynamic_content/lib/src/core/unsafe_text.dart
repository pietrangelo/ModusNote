// Control characters and bidirectional formatting characters let a string
// render differently from what it contains (e.g. U+202E turns "fdp.exe" into
// "exe.pdf"). Text other people supply for labels and tags must not hold them.
final _unsafe = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

bool containsUnsafeCharacters(String text) => _unsafe.hasMatch(text);
