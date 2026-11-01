import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../backup/file_exchange.dart';
import '../backup/markdown_export.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import '../vault/auto_lock.dart';
import 'book_picture.dart';
import 'cookbook.dart';
import 'cookbook_epub.dart';
import 'cookbook_pdf.dart';
import 'cookbook_words.dart';

/// What exporting a cookbook needs from the open vault.
final class CookbookTools {
  const CookbookTools({
    required this.files,
    required this.collect,
    required this.picture,
    this.fonts = loadBookFonts,
  });

  final FileExchange files;

  /// The book of a category, in the person's language.
  final Future<Cookbook> Function(CategoryId root, AppLocalizations l10n)
  collect;

  /// A picture of the vault as the book prints it, at most [side] pixels
  /// on its longest side; null for a blob that is not a picture.
  final Future<Uint8List?> Function(BlobId blob, int side) picture;
  final Future<CookbookFonts> Function() fonts;
}

/// The book's typefaces, from the app's own files.
Future<CookbookFonts> loadBookFonts() async {
  Future<Uint8List> read(String name) async {
    final data = await rootBundle.load('assets/fonts/book/$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  return CookbookFonts(
    regular: await read('Inter-Regular.ttf'),
    semiBold: await read('Inter-SemiBold.ttf'),
    display: await read('PlusJakartaSans-Bold.ttf'),
  );
}

enum CookbookFormat { pdf, epub }

/// The sheet that makes a book of the recipes in [root] and its
/// categories: PDF (in three page sizes) or EPUB, with or without the
/// photos, after saying that the file will not be encrypted.
Future<void> showCookbookSheet(
  BuildContext context, {
  required CategoryId root,
  required String name,
  required CookbookTools tools,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _CookbookSheet(root: root, name: name, tools: tools),
);

class _CookbookSheet extends StatefulWidget {
  const _CookbookSheet({
    required this.root,
    required this.name,
    required this.tools,
  });

  final CategoryId root;
  final String name;
  final CookbookTools tools;

  @override
  State<_CookbookSheet> createState() => _CookbookSheetState();
}

class _CookbookSheetState extends State<_CookbookSheet> {
  var _format = CookbookFormat.pdf;
  var _page = CookbookPage.golden;
  var _pictures = true;
  var _working = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: Spacing.l,
          right: Spacing.l,
          bottom: Spacing.l,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.cookbookExportTitle(widget.name),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.m),
            Container(
              padding: const EdgeInsets.all(Spacing.m),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_open, color: palette.muted),
                  const SizedBox(width: Spacing.m),
                  Expanded(child: Text(l10n.cookbookWarning)),
                ],
              ),
            ),
            const SizedBox(height: Spacing.l),
            SegmentedButton<CookbookFormat>(
              key: const ValueKey('cookbook-format'),
              segments: [
                ButtonSegment(
                  value: CookbookFormat.pdf,
                  icon: const Icon(Icons.print_outlined),
                  label: Text(l10n.cookbookPdf),
                ),
                ButtonSegment(
                  value: CookbookFormat.epub,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(l10n.cookbookEpub),
                ),
              ],
              selected: {_format},
              onSelectionChanged: _working
                  ? null
                  : (chosen) => setState(() => _format = chosen.single),
            ),
            if (_format == CookbookFormat.pdf) ...[
              const SizedBox(height: Spacing.l),
              Text(l10n.cookbookPageSize, style: theme.textTheme.labelLarge),
              const SizedBox(height: Spacing.s),
              SegmentedButton<CookbookPage>(
                key: const ValueKey('cookbook-page'),
                segments: [
                  for (final page in CookbookPage.values)
                    ButtonSegment(
                      value: page,
                      label: Text(switch (page) {
                        CookbookPage.golden => l10n.cookbookGolden,
                        CookbookPage.a5 => 'A5',
                        CookbookPage.a4 => 'A4',
                      }),
                    ),
                ],
                selected: {_page},
                onSelectionChanged: _working
                    ? null
                    : (chosen) => setState(() => _page = chosen.single),
              ),
            ],
            const SizedBox(height: Spacing.m),
            SwitchListTile(
              key: const ValueKey('cookbook-pictures'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.cookbookPictures),
              value: _pictures,
              onChanged: _working
                  ? null
                  : (value) => setState(() => _pictures = value),
            ),
            const SizedBox(height: Spacing.m),
            FilledButton.icon(
              key: const ValueKey('cookbook-export'),
              onPressed: _working ? null : _export,
              icon: _working
                  ? const SizedBox.square(
                      dimension: Spacing.l,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(
                _working ? l10n.cookbookWorking : l10n.cookbookAction,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final release = AutoLockScope.maybeOf(context)?.hold();
    setState(() => _working = true);
    try {
      final book = await widget.tools.collect(widget.root, l10n);
      if (book.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.cookbookEmpty)));
        return;
      }
      final pictures = _pictures
          ? await _picturesOf(book)
          : const <MediaId, Uint8List>{};
      final words = CookbookWords.of(l10n);
      final stem = MarkdownExport.safeName(widget.name, fallback: 'ricette');
      final Uint8List bytes;
      final String file;
      final String type;
      switch (_format) {
        case CookbookFormat.pdf:
          final fonts = await widget.tools.fonts();
          bytes = await compute(
            _renderPdf,
            CookbookPdf(
              book: book,
              words: words,
              fonts: fonts,
              pictures: pictures,
              page: _page,
              lang: lang,
            ),
          );
          file = '$stem.pdf';
          type = 'application/pdf';
        case CookbookFormat.epub:
          bytes = CookbookEpub(
            book: book,
            words: words,
            pictures: pictures,
            lang: lang,
          ).render(at: DateTime.now());
          file = '$stem.epub';
          type = 'application/epub+zip';
      }
      await widget.tools.files.save(file, type, bytes);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.cookbookSaved)));
    } on CookbookTooLargeException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.cookbookTooLarge)));
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      messenger.showSnackBar(SnackBar(content: Text(l10n.cookbookFailed)));
    } finally {
      release?.call();
      if (mounted) setState(() => _working = false);
    }
  }

  /// Every picture the book shows, opened and made again one at a time:
  /// the opening photos larger than the others.
  Future<Map<MediaId, Uint8List>> _picturesOf(Cookbook book) async {
    final out = <MediaId, Uint8List>{};
    for (final recipe in book.recipes) {
      final opening = {for (final p in recipe.recipe.cover) p.media};
      for (final MapEntry(key: id, value: blob) in recipe.media.entries) {
        final side = opening.contains(id) ? bookPhotoSide : bookPictureSide;
        if (await widget.tools.picture(blob, side) case final bytes?) {
          out[id] = bytes;
        }
      }
    }
    return out;
  }
}

Future<Uint8List> _renderPdf(CookbookPdf pdf) => pdf.render();
