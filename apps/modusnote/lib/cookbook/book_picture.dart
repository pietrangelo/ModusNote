import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// The longest side of a recipe's opening photo in the book, and of the
/// other pictures: enough for a page printed at home, small enough that a
/// book of a thousand recipes fits in a phone's memory.
const bookPhotoSide = 987;
const bookPictureSide = 610;

/// [picture] made again for a book: decoded by the platform, scaled down
/// to [side] at most, and written as a new JPEG from its pixels alone, so
/// nothing of the original file (place, camera, dates) survives. Null for
/// bytes that are not a picture.
Future<Uint8List?> bookPicture(Uint8List picture, {required int side}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(picture);
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) => switch (width >= height) {
        _ when width <= side && height <= side => const ui.TargetImageSize(),
        true => ui.TargetImageSize(width: side),
        false => ui.TargetImageSize(height: side),
      },
    );
    image = (await codec.getNextFrame()).image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    return await compute(_jpeg, (
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      image.width,
      image.height,
    ));
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

Uint8List _jpeg((Uint8List, int, int) pixels) {
  final (rgba, width, height) = pixels;
  final decoded = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  // A photo with see-through parts goes on the page's white.
  final flat = img.Image(width: width, height: height);
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, decoded);
  return img.encodeJpg(flat, quality: 82);
}
