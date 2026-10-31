import 'dart:typed_data';
import 'dart:ui' as ui;

/// The longest side of a published picture: a Fibonacci number, enough for
/// a wide screen at twice its density and far below serv.pub's 21 MiB.
const maxPublishedSide = 1597;

/// [picture] decoded and encoded again as PNG, at most [maxPublishedSide]
/// on its longest side: only the pixels survive, never the original's
/// metadata (EXIF place, time and device, XMP, ICC comments), whatever the
/// format. The decoder applies the EXIF orientation first, so the picture
/// stands as it was taken. Null when it cannot be decoded.
Future<Uint8List?> reencodePicture(Uint8List picture) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    // The codec disposes the buffer once it has read it.
    final buffer = await ui.ImmutableBuffer.fromUint8List(picture);
    // Only the longest side is given, so the picture keeps its proportions.
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) => switch (width >= height) {
        _ when width <= maxPublishedSide && height <= maxPublishedSide =>
          const ui.TargetImageSize(),
        true => const ui.TargetImageSize(width: maxPublishedSide),
        false => const ui.TargetImageSize(height: maxPublishedSide),
      },
    );
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
