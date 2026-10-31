import 'golden.dart';

/// The body sizes a site can choose, in px.
enum BodySize {
  small(16),
  medium(18),
  large(20);

  const BodySize(this.px);

  final int px;
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
