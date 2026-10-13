import 'dart:convert';
import 'dart:typed_data';

import 'package:modusnote/attachments/note_images.dart';

/// A real 1×1 PNG, so the decoder in the test has something to draw.
final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// Hands over whatever the test sets, as the system picker would.
final class FakeChooser implements ImageChooser {
  Uint8List? Function() next = () => Uint8List.fromList(pixel);
  final handedOut = <Uint8List>[];

  @override
  Future<Uint8List?> choose() async {
    final bytes = next();
    if (bytes != null) handedOut.add(bytes);
    return bytes;
  }
}
