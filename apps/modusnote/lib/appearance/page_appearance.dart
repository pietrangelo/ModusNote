import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../theme/golden_ratio.dart';

/// How wide the text of a note may grow, on a window wide enough for it
/// to matter ([PageAppearance.wideFrom]): the Fibonacci extents, then the
/// whole window.
enum PageWidth {
  narrow(Extents.xxl),
  medium(Extents.xxxl),
  wide(Extents.xxxxl),
  full(double.infinity);

  const PageWidth(this.maxWidth);

  final double maxWidth;

  /// Left and right of the text: a page as wide as the window keeps the
  /// largest spacing step as its margin.
  double get margin => this == full ? Spacing.xxl : Spacing.l;
}

/// The typefaces offered for the text of a note: all for long reading
/// and writing, all SIL OFL and bundled (the web client fetches nothing
/// from elsewhere). Except Inter, the app's own body font, each is loaded
/// only when chosen ([assets]).
enum PageFont {
  inter('Inter', []),
  literata('Literata', [
    'assets/fonts/reading/Literata-Variable.ttf',
    'assets/fonts/reading/Literata-Italic-Variable.ttf',
  ]),
  atkinson('AtkinsonHyperlegibleNext', [
    'assets/fonts/reading/AtkinsonHyperlegibleNext-Variable.ttf',
    'assets/fonts/reading/AtkinsonHyperlegibleNext-Italic-Variable.ttf',
  ]),
  quattro('iAWriterQuattro', [
    'assets/fonts/reading/iAWriterQuattro-Variable.ttf',
    'assets/fonts/reading/iAWriterQuattro-Italic-Variable.ttf',
  ]);

  const PageFont(this.family, this.assets);

  final String family;

  /// Roman and italic, variable on the weight axis.
  final List<String> assets;
}

/// How this device shows the page of a note: its width, the size of its
/// text and the typeface. A preference of the device, not of the notes: a phone and a
/// monitor want different pages, so it is never synced.
@immutable
final class PageAppearance {
  const PageAppearance({
    this.width = PageWidth.medium,
    this.textStep = 1,
    this.font = PageFont.inter,
    this.moods = true,
  });

  final PageWidth width;

  final PageFont font;

  /// Whether the page of a note takes the mood of its type (`NoteMood`)
  /// within the app's theme.
  final bool moods;

  /// Index into [textSizes].
  final int textStep;

  /// Half golden steps (ratio √φ) around the body size: every second one
  /// is on the type scale (16 and 26 sp).
  static const textSizes = <double>[13, 16, 20, 26, 33];

  /// Below this window width the page is the whole screen anyway, and the
  /// width is not offered.
  static const wideFrom = Extents.xxxl;

  double get textSize => textSizes[textStep];

  /// What the page's text sizes are multiplied by.
  double get textFactor => textSize / TypeScale.body;

  PageAppearance copyWith({
    PageWidth? width,
    int? textStep,
    PageFont? font,
    bool? moods,
  }) => PageAppearance(
    width: width ?? this.width,
    textStep: textStep ?? this.textStep,
    font: font ?? this.font,
    moods: moods ?? this.moods,
  );

  PageAppearance wider() =>
      copyWith(width: PageWidth.values[(width.index + 1).clamp(0, _lastWidth)]);

  PageAppearance narrower() =>
      copyWith(width: PageWidth.values[(width.index - 1).clamp(0, _lastWidth)]);

  PageAppearance larger() =>
      copyWith(textStep: (textStep + 1).clamp(0, _lastStep));

  PageAppearance smaller() =>
      copyWith(textStep: (textStep - 1).clamp(0, _lastStep));

  static final _lastWidth = PageWidth.values.length - 1;
  static final _lastStep = textSizes.length - 1;

  static const _version = 1;

  /// Version, width, text step, typeface, moods.
  Uint8List toBytes() => Uint8List.fromList([
    _version,
    width.index,
    textStep,
    font.index,
    if (moods) 1 else 0,
  ]);

  /// What [toBytes] wrote; anything else, damaged or from a newer app, is
  /// the default page.
  static PageAppearance fromBytes(Uint8List? bytes) {
    if (bytes == null ||
        bytes.length != 5 ||
        bytes[0] != _version ||
        bytes[1] > _lastWidth ||
        bytes[2] > _lastStep ||
        bytes[3] >= PageFont.values.length ||
        bytes[4] > 1) {
      return const PageAppearance();
    }
    return PageAppearance(
      width: PageWidth.values[bytes[1]],
      textStep: bytes[2],
      font: PageFont.values[bytes[3]],
      moods: bytes[4] == 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PageAppearance &&
      other.width == width &&
      other.textStep == textStep &&
      other.font == font &&
      other.moods == moods;

  @override
  int get hashCode => Object.hash(width, textStep, font, moods);

  @override
  String toString() => 'PageAppearance($width, $textSize, $font, $moods)';
}

/// The system's text scaling with the page's size on top: the page's
/// factor applies first, so the system's own (which may grow small text
/// more than large) still sees the size actually drawn.
@immutable
final class PageTextScaler extends TextScaler {
  const PageTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize * factor);

  @Deprecated('Use scale() instead.')
  @override
  double get textScaleFactor => scale(TypeScale.body) / TypeScale.body;

  @override
  bool operator ==(Object other) =>
      other is PageTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}
