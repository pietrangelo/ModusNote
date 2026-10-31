import 'golden.dart';

/// The body sizes a site can choose, in px.
enum BodySize {
  small(16),
  medium(18),
  large(20);

  const BodySize(this.px);

  final int px;
}

/// The body's typeface on a site: the fonts of the app's reader, which
/// serv.pub serves itself. Headings are always Plus Jakarta Sans.
enum SiteFont {
  inter('inter'),
  literata('literata'),

  /// Atkinson Hyperlegible Next, drawn for readers with low vision.
  atkinson('atkinson'),

  /// iA Writer Quattro.
  quattro('quattro');

  const SiteFont(this.wire);

  /// serv.pub's name for it.
  final String wire;
}

/// The type scale of a published page: headings climb by φ from the body,
/// the caption falls by φ, lines are φ apart, and a line of text is at most
/// 610 px (about 65 characters), a Fibonacci width.
final class Typography {
  const Typography(this.size);

  final BodySize size;

  int get body => size.px;
  int get caption => (body / Golden.phi).round();
  int get h3 => (body * Golden.phi).round();
  int get h2 => (body * Golden.phi * Golden.phi).round();
  int get h1 => (body * Golden.phi * Golden.phi * Golden.phi).round();
  double get lineHeight => Golden.phi;
  int get measure => 610;

  @override
  bool operator ==(Object other) => other is Typography && other.size == size;

  @override
  int get hashCode => size.hashCode;
}
