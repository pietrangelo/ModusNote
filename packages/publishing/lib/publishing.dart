/// Publishing: siti pubblici su serv.pub, istantanee di note scelte, temi e
/// layout in φ.
///
/// Publishing a note deliberately ends zero knowledge for that note: its
/// snapshot is readable by anyone. This context decides what may leave the
/// vault, how it is named and how it looks. Public API of the bounded
/// context; other packages import only this library.
library;

export 'src/core/color.dart';
export 'src/core/golden.dart';
export 'src/core/layout.dart';
export 'src/core/names.dart';
export 'src/core/publication_policy.dart';
export 'src/core/publishing_exception.dart';
export 'src/core/site_palette.dart';
export 'src/core/typography.dart';
