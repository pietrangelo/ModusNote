import 'dart:async';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import 'attachment_dialogs.dart';

/// Opens an address outside the app; false when nothing could.
typedef LinkOpener = Future<bool> Function(Uri address);

/// What the attachments of a page need from the screen around them.
final class AttachmentHooks {
  const AttachmentHooks({
    required this.openImage,
    required this.openLink,
    this.addImage,
    this.imageSize,
  });

  /// Picks and seals a picture; null when the person cancels. Null where
  /// pictures cannot be kept, which turns the button off.
  final Future<BlobId?> Function()? addImage;

  /// A picture's bytes, checked against what the note says it is.
  final Future<Uint8List> Function(BlobId blob) openImage;

  /// Opens a link once the person has confirmed it.
  final LinkOpener openLink;

  /// A picture's size, from the note's metadata; null when the picture is
  /// not known, which pictures in the text then say.
  final ImageHeader? Function(BlobId blob)? imageSize;
}

/// The pictures and links of a page: thumbnails decrypted in memory, links
/// shown as their title and site. Nothing here reaches the network on its
/// own; a link leaves the app only when tapped and confirmed, with its
/// whole address shown first.
class AttachmentsInput extends StatefulWidget {
  const AttachmentsInput({
    required this.label,
    required this.error,
    required this.value,
    required this.hooks,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? error;
  final AttachmentsValue? value;
  final AttachmentHooks hooks;
  final ValueChanged<AttachmentsValue?> onChanged;

  @override
  State<AttachmentsInput> createState() => _AttachmentsInputState();
}

class _AttachmentsInputState extends State<AttachmentsInput> {
  /// Each picture is decrypted once while the page is open; the bytes go
  /// with this state.
  final _opened = <BlobId, Future<Uint8List>>{};

  List<Attachment> get _items => widget.value?.items ?? const [];

  Future<Uint8List> _bytesOf(BlobId blob) =>
      _opened[blob] ??= widget.hooks.openImage(blob);

  void _replace(List<Attachment> items) =>
      widget.onChanged(items.isEmpty ? null : AttachmentsValue(items));

  void _change(Attachment old, Attachment? next) => _replace([
    for (final item in _items)
      if (!identical(item, old)) item else ?next,
  ]);

  Future<void> _addImage(Future<BlobId?> Function() add) async {
    final blob = await add();
    if (blob == null || !mounted) return;
    _replace([..._items, ImageAttachment(blob)]);
  }

  Future<void> _addLink() async {
    final link = await showLinkDialog(context);
    if (link == null || !mounted) return;
    _replace([..._items, link]);
  }

  Future<void> _open(WebLink link) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmOpenLink(context, link)) return;
    if (!await widget.hooks.openLink(Uri.parse(link.url))) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.openLinkFailed)));
    }
  }

  void _view(ImageAttachment image) => ImageViewer.show(
    context,
    bytes: _bytesOf(image.blob),
    caption: image.caption,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final images = [
      for (final item in _items)
        if (item is ImageAttachment) item,
    ];
    final links = [
      for (final item in _items)
        if (item is WebLink) item,
    ];
    final addImage = widget.hooks.addImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
          child: Text(widget.label, style: theme.textTheme.labelMedium),
        ),
        if (widget.error case final error?)
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        if (images.isNotEmpty)
          Wrap(
            spacing: Spacing.s,
            runSpacing: Spacing.s,
            children: [
              for (final image in images)
                _Thumbnail(
                  key: ValueKey('image-${image.blob.value}'),
                  image: image,
                  bytes: _bytesOf(image.blob),
                  onView: () => _view(image),
                  onCaption: () async {
                    final caption = await showCaptionDialog(
                      context,
                      initial: image.caption,
                    );
                    if (caption != null && mounted) {
                      _change(image, image.captioned(caption));
                    }
                  },
                  onRemove: () => _change(image, null),
                ),
            ],
          ),
        for (final link in links)
          ListTile(
            key: ValueKey('weblink-${link.url}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link),
            title: Text(
              link.title.isEmpty ? link.host : link.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // The site is always in sight: a title cannot hide where the
            // link goes.
            subtitle: Text(
              link.title.isEmpty ? link.url : link.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _open(link),
            trailing: PopupMenuButton<_LinkAction>(
              tooltip: l10n.attachmentOptions,
              onSelected: (action) async {
                switch (action) {
                  case _LinkAction.edit:
                    final next = await showLinkDialog(context, existing: link);
                    if (next != null && mounted) _change(link, next);
                  case _LinkAction.copy:
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: link.url));
                    messenger.showSnackBar(
                      SnackBar(content: Text(l10n.linkCopied)),
                    );
                  case _LinkAction.remove:
                    _change(link, null);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _LinkAction.edit,
                  child: Text(l10n.editAttachment),
                ),
                PopupMenuItem(
                  value: _LinkAction.copy,
                  child: Text(l10n.copyLink),
                ),
                PopupMenuItem(
                  value: _LinkAction.remove,
                  child: Text(l10n.removeAttachment),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: Spacing.s,
          children: [
            TextButton.icon(
              icon: const Icon(
                Icons.add_photo_alternate_outlined,
                size: IconSizes.inline,
              ),
              label: Text(l10n.addImage),
              onPressed: addImage == null ? null : () => _addImage(addImage),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add_link, size: IconSizes.inline),
              label: Text(l10n.addLink),
              onPressed: _addLink,
            ),
          ],
        ),
      ],
    );
  }
}

enum _LinkAction { edit, copy, remove }

enum _ImageAction { caption, remove }

/// A picture in the page, φ : 1, with its caption below.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.image,
    required this.bytes,
    required this.onView,
    required this.onCaption,
    required this.onRemove,
    super.key,
  });

  final ImageAttachment image;
  final Future<Uint8List> bytes;
  final VoidCallback onView;
  final VoidCallback onCaption;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      width: Extents.m,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.small),
            child: SizedBox(
              height: Extents.s,
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Semantics(
                  button: true,
                  label: image.caption.isEmpty ? l10n.imageOpen : image.caption,
                  child: InkWell(
                    onTap: onView,
                    child: SealedImage(bytes: bytes, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  image.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
              PopupMenuButton<_ImageAction>(
                tooltip: l10n.attachmentOptions,
                onSelected: (action) => switch (action) {
                  _ImageAction.caption => onCaption(),
                  _ImageAction.remove => onRemove(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _ImageAction.caption,
                    child: Text(l10n.editCaptionTitle),
                  ),
                  PopupMenuItem(
                    value: _ImageAction.remove,
                    child: Text(l10n.removeAttachment),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A decrypted picture, decoded at the size it is drawn: a large photo
/// never expands to full resolution for a thumbnail.
class SealedImage extends StatelessWidget {
  const SealedImage({
    required this.bytes,
    required this.fit,
    this.drawnWidth,
    super.key,
  });

  final Future<Uint8List> bytes;
  final BoxFit fit;

  /// The width it is drawn at, when known beforehand: inside text, where
  /// a layout builder cannot measure.
  final double? drawnWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return _Problem(
            error is RemoteBlobUnavailableException ||
                    error is BlobNotFoundException
                ? l10n.imageUnavailable
                : l10n.imageDamaged,
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        Widget image(int? width) => Image.memory(
          data,
          fit: fit,
          cacheWidth: width,
          gaplessPlayback: true,
          // A decoder that refuses the bytes is a damaged picture, not a
          // crash.
          errorBuilder: (context, _, _) => _Problem(l10n.imageDamaged),
        );
        if (drawnWidth case final drawn?) return image((drawn * ratio).ceil());
        return LayoutBuilder(
          builder: (context, constraints) => image(
            constraints.maxWidth.isFinite
                ? (constraints.maxWidth * ratio).ceil()
                : null,
          ),
        );
      },
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Spacing.xs),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

/// One picture on the whole screen, to zoom into.
class ImageViewer extends StatelessWidget {
  const ImageViewer({required this.bytes, required this.caption, super.key});

  final Future<Uint8List> bytes;
  final String caption;

  static void show(
    BuildContext context, {
    required Future<Uint8List> bytes,
    required String caption,
  }) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageViewer(bytes: bytes, caption: caption),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: SealedImage(bytes: bytes, fit: BoxFit.contain),
      ),
    ),
  );
}
