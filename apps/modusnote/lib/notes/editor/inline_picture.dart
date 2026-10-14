import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../attachments/attachments_input.dart';

/// A picture in the flow of a note's text, drawn where its Markdown sits:
/// as wide as the text at most, never wider than the picture itself nor
/// taller than [Extents.xxl], decoded at the size it is drawn. Its size
/// comes from the note's metadata, so the text does not jump while the
/// bytes are decrypted. A tap opens it on the whole screen.
///
/// A reference with no metadata (typed, or pasted from outside the vault)
/// shows a line saying the picture is not available.
class InlinePicture extends StatelessWidget {
  const InlinePicture({
    required this.picture,
    required this.size,
    required this.maxWidth,
    required this.bytes,
    super.key,
  });

  final InlineImage picture;

  /// The picture's size in pixels, from its metadata; null when unknown.
  final ImageHeader? size;

  /// The width of the text.
  final double maxWidth;

  /// Its bytes, decrypted once and shared by every redraw.
  final Future<Uint8List> Function() bytes;

  /// The size it is drawn at: [maxWidth] wide at most, no larger than the
  /// picture, and no taller than [Extents.xxl].
  static Size fit(ImageHeader size, double maxWidth) {
    final ratio = size.width / size.height;
    var width = min(maxWidth, size.width.toDouble());
    var height = width / ratio;
    if (height > Extents.xxl) {
      height = Extents.xxl;
      width = height * ratio;
    }
    return Size(width, height);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final caption = picture.caption;
    final size = this.size;
    final Widget body;
    if (size == null) {
      body = SizedBox(
        width: maxWidth,
        height: Spacing.xxl,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.small),
          child: Center(
            child: Text(l10n.imageMissing, style: theme.textTheme.labelSmall),
          ),
        ),
      );
    } else {
      final drawn = fit(size, maxWidth);
      body = SizedBox(
        width: drawn.width,
        height: drawn.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.small),
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Semantics(
              button: true,
              label: caption.isEmpty ? l10n.imageOpen : caption,
              child: InkWell(
                onTap: () =>
                    ImageViewer.show(context, bytes: bytes(), caption: caption),
                child: SealedImage(
                  bytes: bytes(),
                  fit: BoxFit.contain,
                  drawnWidth: drawn.width,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          if (caption.isNotEmpty)
            SizedBox(
              width: maxWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: Spacing.xxs),
                child: Text(
                  caption,
                  style: theme.textTheme.labelSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
