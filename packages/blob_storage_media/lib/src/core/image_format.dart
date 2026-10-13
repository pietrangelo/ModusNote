import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'blob_exception.dart';
import 'blob_metadata.dart';

/// The picture formats a page can hold: those every platform's image
/// decoder reads. Anything else is refused before it is sealed.
enum ImageFormat {
  png('png', 'image/png'),
  jpeg('jpeg', 'image/jpeg'),
  gif('gif', 'image/gif'),
  webp('webp', 'image/webp');

  const ImageFormat(this.wireName, this.mimeType);

  /// Stable name for persisted metadata; independent of enum order.
  final String wireName;
  final String mimeType;

  static ImageFormat fromWireName(String wireName) {
    for (final format in values) {
      if (format.wireName == wireName) return format;
    }
    throw const InvalidBlobMetadataException('unknown image format');
  }
}

/// A picture's format and size in pixels, as its own header states them.
@immutable
final class ImageInfo {
  ImageInfo(this.format, this.width, this.height) {
    if (width < 1 ||
        height < 1 ||
        width > ImageProbe.maxSide ||
        height > ImageProbe.maxSide ||
        width * height > ImageProbe.maxPixels) {
      throw const ImageTooLargeException();
    }
  }

  final ImageFormat format;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is ImageInfo &&
      other.format == format &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(format, width, height);

  @override
  String toString() => 'ImageInfo(${format.wireName}, $width×$height)';
}

/// Reads a picture's header, and only its header: which format it is and
/// how many pixels it would decode to.
///
/// Pictures come from other members of the workspace, so the size is
/// checked before any decoder sees the bytes: a small file that claims
/// 60 000 × 60 000 pixels would otherwise ask the device for gigabytes.
abstract final class ImageProbe {
  /// Largest picture kept, in bytes: a phone photo fits several times.
  static const maxBytes = 32 * 1024 * 1024;

  /// Longest side, in pixels: room for a panorama.
  static const maxSide = 20000;

  /// Most pixels, about 200 MB once decoded; what is shown is decoded at
  /// screen size anyway.
  static const maxPixels = 50000000;

  /// Throws [UnsupportedImageException] for anything that is not a PNG,
  /// JPEG, GIF or WebP it can read the size of, and
  /// [ImageTooLargeException] for one past the limits.
  static ImageInfo probe(List<int> bytes) {
    if (bytes.length > maxBytes) throw const ImageTooLargeException();
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    try {
      if (_starts(data, const [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ])) {
        // The IHDR chunk comes first, always 13 bytes long.
        if (view.getUint32(8) != 13 || !_ascii(data, 12, 'IHDR')) {
          throw const UnsupportedImageException();
        }
        return ImageInfo(
          ImageFormat.png,
          view.getUint32(16),
          view.getUint32(20),
        );
      }
      if (_ascii(data, 0, 'GIF87a') || _ascii(data, 0, 'GIF89a')) {
        return ImageInfo(
          ImageFormat.gif,
          view.getUint16(6, Endian.little),
          view.getUint16(8, Endian.little),
        );
      }
      if (_ascii(data, 0, 'RIFF') && _ascii(data, 8, 'WEBP')) {
        return _webp(data, view);
      }
      if (_starts(data, const [0xFF, 0xD8])) return _jpeg(data, view);
    } on RangeError {
      // A header cut short.
    }
    throw const UnsupportedImageException();
  }

  static ImageInfo _webp(Uint8List data, ByteData view) {
    if (_ascii(data, 12, 'VP8 ')) {
      // Frame tag (3 bytes), then the start code and 14-bit sizes.
      if (!_starts(data, const [0x9D, 0x01, 0x2A], at: 23)) {
        throw const UnsupportedImageException();
      }
      return ImageInfo(
        ImageFormat.webp,
        view.getUint16(26, Endian.little) & 0x3FFF,
        view.getUint16(28, Endian.little) & 0x3FFF,
      );
    }
    if (_ascii(data, 12, 'VP8L')) {
      if (data[20] != 0x2F) throw const UnsupportedImageException();
      final bits = view.getUint32(21, Endian.little);
      return ImageInfo(
        ImageFormat.webp,
        (bits & 0x3FFF) + 1,
        ((bits >> 14) & 0x3FFF) + 1,
      );
    }
    if (_ascii(data, 12, 'VP8X')) {
      int u24(int at) => data[at] | data[at + 1] << 8 | data[at + 2] << 16;
      return ImageInfo(ImageFormat.webp, u24(24) + 1, u24(27) + 1);
    }
    throw const UnsupportedImageException();
  }

  /// Walks the segments up to the first frame header; a scan before any
  /// frame header is not a picture this reads.
  static ImageInfo _jpeg(Uint8List data, ByteData view) {
    var at = 2;
    while (true) {
      if (data[at] != 0xFF) throw const UnsupportedImageException();
      while (data[at] == 0xFF) {
        at++;
      }
      final marker = data[at++];
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
      if (marker == 0xD9 || marker == 0xDA) {
        throw const UnsupportedImageException();
      }
      final length = view.getUint16(at);
      if (length < 2) throw const UnsupportedImageException();
      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        return ImageInfo(
          ImageFormat.jpeg,
          view.getUint16(at + 5),
          view.getUint16(at + 3),
        );
      }
      at += length;
    }
  }

  static bool _starts(Uint8List data, List<int> prefix, {int at = 0}) {
    if (data.length < at + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[at + i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _ascii(Uint8List data, int at, String text) =>
      _starts(data, text.codeUnits, at: at);
}

/// Describes one encrypted picture. Like [BlobMetadata], it travels only
/// inside the sealed note: the server sees the `.enc` object and its size,
/// never the format, the size in pixels or when it was added.
@immutable
final class ImageMetadata {
  ImageMetadata({
    required this.blob,
    required this.info,
    required this.addedAt,
  }) {
    if (blob.plaintextLength > ImageProbe.maxBytes) {
      throw const InvalidBlobMetadataException('image too large');
    }
    if (!addedAt.isUtc) {
      throw const InvalidBlobMetadataException('addedAt must be UTC');
    }
  }

  final SealedBlob blob;
  final ImageInfo info;
  final DateTime addedAt;

  BlobId get id => blob.id;

  ImageFormat get format => info.format;

  @override
  bool operator ==(Object other) =>
      other is ImageMetadata &&
      other.blob == blob &&
      other.info == info &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(blob, info, addedAt);
}
