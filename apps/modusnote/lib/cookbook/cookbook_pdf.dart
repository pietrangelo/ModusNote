import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:publishing/publishing.dart';

import '../notes/markdown/markdown_document.dart';
import 'cookbook.dart';
import 'cookbook_words.dart';

/// The page a cookbook is printed on.
enum CookbookPage {
  /// 144 × 233 mm, two Fibonacci numbers: the golden rectangle.
  golden(144, 233),
  a5(148, 210),
  a4(210, 297);

  const CookbookPage(this.width, this.height);

  /// In millimetres.
  final double width;
  final double height;

  PdfPageFormat get format =>
      PdfPageFormat(width * PdfPageFormat.mm, height * PdfPageFormat.mm);
}

/// The typefaces of the book, as TrueType files: Inter for the text,
/// Plus Jakarta Sans for the titles, as in the app. Only the letters the
/// book uses are written into the file.
final class CookbookFonts {
  const CookbookFonts({
    required this.regular,
    required this.semiBold,
    required this.display,
    this.fallback = const [],
  });

  final Uint8List regular;
  final Uint8List semiBold;
  final Uint8List display;

  /// For symbols the others lack.
  final List<Uint8List> fallback;
}

/// Prints a [Cookbook] as a PDF laid out in φ like its page on serv.pub:
/// a cover, the contents, a chapter per category in its colour, each
/// recipe from a page of its own (opening photo in a golden rectangle,
/// ingredients in 38.2 % of the width and steps in the other 61.8 %), and
/// the index of ingredients at the end. The contents and the index link
/// to the recipes. A step's video cannot be printed: in its place a code
/// to its published page, or a line saying it is in the note.
final class CookbookPdf {
  CookbookPdf({
    required this.book,
    required this.words,
    required this.fonts,
    required this.pictures,
    this.page = CookbookPage.golden,
    this.lang = 'it',
  });

  final Cookbook book;
  final CookbookWords words;
  final CookbookFonts fonts;

  /// The pictures the book shows, as JPEG or PNG; a picture not here is
  /// left out.
  final Map<MediaId, Uint8List> pictures;
  final CookbookPage page;
  final String lang;

  static const _phi = 1.6180339887;

  /// The whole file. Laid out twice: the first time only to learn the
  /// page each recipe starts on, for the contents and the index.
  Future<Uint8List> render() async {
    final starts = <int, int>{};
    await _document(starts, null).save();
    return _document(<int, int>{}, starts).save();
  }

  late final _regular = pw.Font.ttf(ByteData.sublistView(fonts.regular));
  late final _semiBold = pw.Font.ttf(ByteData.sublistView(fonts.semiBold));
  late final _display = pw.Font.ttf(ByteData.sublistView(fonts.display));
  late final _fallback = [
    for (final f in fonts.fallback) pw.Font.ttf(ByteData.sublistView(f)),
  ];
  final _images = <MediaId, pw.ImageProvider?>{};

  // The type scale: the text, then one φ step (and half steps) either side.
  double get _base => page == CookbookPage.a4 ? 11 : 9.5;
  double get _small => _base / math.sqrt(_phi);
  double get _h3 => _base * math.sqrt(_phi);
  double get _h1 => _base * _phi * _phi;
  double get _display1 => _base * _phi * _phi * _phi;

  // Space in steps of φ from the text size.
  double get _s1 => _base / _phi / _phi;
  double get _s2 => _base / _phi;
  double get _s3 => _base;
  double get _s4 => _base * _phi;
  double get _s5 => _base * _phi * _phi;

  /// The margin: the page's width divided by φ⁵, and φ times more below.
  pw.EdgeInsets get _margin {
    final m = page.format.width / math.pow(_phi, 5);
    return pw.EdgeInsets.fromLTRB(m, m, m, m * _phi);
  }

  PdfColor _colour(Srgb c) =>
      PdfColor.fromInt(0xFF000000 | c.r << 16 | c.g << 8 | c.b);

  PdfColor get _text => _colour(book.palette.text);
  PdfColor get _secondary => _colour(book.palette.secondaryText);
  PdfColor get _background => _colour(book.palette.background);
  PdfColor get _accent => _colour(book.palette.accent);

  pw.Document _document(Map<int, int> found, Map<int, int>? starts) {
    final doc = pw.Document(
      theme:
          pw.ThemeData.withFont(
            base: _regular,
            bold: _semiBold,
            italic: _regular,
            boldItalic: _semiBold,
            fontFallback: _fallback,
          ).copyWith(
            defaultTextStyle: pw.TextStyle(
              font: _regular,
              fontNormal: _regular,
              fontBold: _semiBold,
              fontItalic: _regular,
              fontBoldItalic: _semiBold,
              fontFallback: _fallback,
              fontSize: _base,
              color: _text,
              lineSpacing: _base * (_phi - 1) * 0.5,
            ),
          ),
      title: book.title,
      creator: 'Modus Notes',
      producer: 'Modus Notes',
      compress: true,
    );
    final recipes = book.recipes.toList();
    final number = {for (final (i, r) in recipes.indexed) r: i};
    String? numberOf(CookbookRecipe r) =>
        starts == null ? '000' : starts[number[r]!]?.toString();

    doc.addPage(_cover(recipes));
    doc.addPage(_contents(number, numberOf));
    final chapters = book.chapters;
    for (final chapter in chapters) {
      if (chapters.length > 1 || chapter.depth > 0) {
        doc.addPage(_opener(chapter));
      }
      for (final recipe in chapter.recipes) {
        doc.addPage(_recipe(chapter, recipe, number[recipe]!, found));
      }
    }
    if (book.ingredients.isNotEmpty) {
      doc.addPage(_index(number, numberOf));
    }
    return doc;
  }

  pw.PageTheme _theme({PdfColor? ground}) => pw.PageTheme(
    pageFormat: page.format,
    margin: _margin,
    buildBackground: ground == null
        ? null
        : (context) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: ground),
          ),
  );

  pw.Widget _footer(pw.Context context) => pw.Container(
    alignment: pw.Alignment.center,
    margin: pw.EdgeInsets.only(top: _s3),
    child: pw.Text(
      '${context.pageNumber}',
      style: pw.TextStyle(fontSize: _small, color: _secondary),
    ),
  );

  // ------------------------------------------------------------- cover

  pw.Page _cover(List<CookbookRecipe> recipes) {
    MediaId? photo;
    for (final recipe in recipes) {
      for (final p in recipe.recipe.cover) {
        if (_image(p.media) != null) {
          photo = p.media;
          break;
        }
      }
      if (photo != null) break;
    }
    final width = page.format.width - _margin.horizontal;
    return pw.Page(
      pageTheme: _theme(ground: _background),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (photo != null)
            pw.ClipRRect(
              horizontalRadius: _s2,
              verticalRadius: _s2,
              child: pw.Image(
                _image(photo)!,
                width: width,
                height: width / _phi,
                fit: pw.BoxFit.cover,
              ),
            ),
          pw.Spacer(),
          pw.Container(width: _s5, height: _s1, color: _accent),
          pw.SizedBox(height: _s4),
          pw.Text(
            book.title,
            style: pw.TextStyle(
              font: _display,
              fontSize: _display1,
              color: _text,
              lineSpacing: 0,
            ),
          ),
          pw.SizedBox(height: _s3),
          pw.Text(
            words.recipeCount(recipes.length),
            style: pw.TextStyle(fontSize: _h3, color: _accent),
          ),
          pw.Spacer(flex: 1),
          pw.Text(
            words.madeWith,
            style: pw.TextStyle(fontSize: _small, color: _secondary),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- contents

  pw.MultiPage _contents(
    Map<CookbookRecipe, int> number,
    String? Function(CookbookRecipe) numberOf,
  ) => pw.MultiPage(
    pageTheme: _theme(),
    maxPages: 1000,
    footer: _footer,
    build: (context) => [
      _heading(words.contents, _accent),
      for (final chapter in book.chapters) ...[
        if (book.chapters.length > 1 || chapter.depth > 0)
          pw.Padding(
            padding: pw.EdgeInsets.only(
              top: _s4,
              bottom: _s2,
              left: _s3 * math.max(0, chapter.depth - 1),
            ),
            child: pw.Text(
              chapter.depth == 0 ? book.title : chapter.name,
              style: pw.TextStyle(
                font: _display,
                fontSize: _h3,
                color: _colour(chapter.colours.accent),
              ),
            ),
          ),
        for (final recipe in chapter.recipes)
          pw.Link(
            destination: _anchor(number[recipe]!),
            child: pw.Padding(
              padding: pw.EdgeInsets.only(
                left: _s3 * math.max(0, chapter.depth - 1),
                bottom: _s1,
              ),
              child: _leader(recipe.title, numberOf(recipe) ?? ''),
            ),
          ),
      ],
    ],
  );

  /// A line of the contents: the title, then its page at the right.
  pw.Widget _leader(String title, String pageNumber) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      pw.Expanded(child: pw.Text(title, maxLines: 2)),
      pw.SizedBox(width: _s3),
      pw.SizedBox(
        width: _s5,
        child: pw.Text(
          pageNumber,
          textAlign: pw.TextAlign.right,
          style: pw.TextStyle(color: _secondary),
        ),
      ),
    ],
  );

  // ----------------------------------------------------------- chapter

  pw.Page _opener(CookbookChapter chapter) {
    final accent = _colour(chapter.colours.accent);
    final above = chapter.path.length > 1
        ? chapter.path.sublist(0, chapter.path.length - 1).join(' · ')
        : book.title;
    return pw.Page(
      pageTheme: _theme(ground: _colour(chapter.colours.tint)),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // The title sits at the golden section of the page.
          pw.Spacer(flex: 382),
          if (chapter.depth > 0)
            pw.Text(
              above,
              style: pw.TextStyle(fontSize: _base, color: _secondary),
            ),
          pw.SizedBox(height: _s2),
          pw.Text(
            chapter.depth == 0 ? book.title : chapter.name,
            style: pw.TextStyle(
              font: _display,
              fontSize: _display1,
              color: accent,
              lineSpacing: 0,
            ),
          ),
          pw.SizedBox(height: _s3),
          pw.Container(width: _s5, height: _s1, color: accent),
          pw.SizedBox(height: _s3),
          pw.Text(
            words.recipeCount(chapter.recipes.length),
            style: pw.TextStyle(fontSize: _h3, color: _text),
          ),
          pw.Spacer(flex: 618),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ recipe

  pw.MultiPage _recipe(
    CookbookChapter chapter,
    CookbookRecipe entry,
    int index,
    Map<int, int> found,
  ) {
    final recipe = entry.recipe;
    final accent = _colour(chapter.colours.accent);
    final tint = _colour(chapter.colours.tint);
    final width = page.format.width - _margin.horizontal;
    final heading = chapter.depth == 0 ? book.title : chapter.name;
    final photo = [
      for (final p in recipe.cover)
        if (_image(p.media) != null) p,
    ];
    return pw.MultiPage(
      pageTheme: _theme(),
      maxPages: 1000,
      footer: _footer,
      header: (context) {
        // The first page of the recipe is where it starts.
        found.putIfAbsent(index, () => context.pageNumber);
        return pw.Container(
          margin: pw.EdgeInsets.only(bottom: _s3),
          child: pw.Text(
            heading,
            style: pw.TextStyle(fontSize: _small, color: accent),
          ),
        );
      },
      build: (context) => [
        pw.Anchor(
          name: _anchor(index),
          child: pw.Text(
            entry.title,
            style: pw.TextStyle(
              font: _display,
              fontSize: _h1,
              color: accent,
              lineSpacing: 0,
            ),
          ),
        ),
        pw.SizedBox(height: _s3),
        if (photo.isNotEmpty) ...[
          pw.ClipRRect(
            horizontalRadius: _s2,
            verticalRadius: _s2,
            child: pw.Image(
              _image(photo.first.media)!,
              width: width,
              height: width / _phi,
              fit: pw.BoxFit.cover,
            ),
          ),
          if (photo.first.caption.isNotEmpty) _caption(photo.first.caption),
          pw.SizedBox(height: _s3),
        ],
        if (recipe.description.isNotEmpty) ..._markdown(recipe.description),
        ..._facts(recipe, accent, tint),
        pw.SizedBox(height: _s4),
        pw.Partitions(
          children: [
            pw.Partition(
              flex: 382,
              child: pw.Padding(
                padding: pw.EdgeInsets.only(right: _s4),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: _ingredients(recipe, accent),
                ),
              ),
            ),
            pw.Partition(
              flex: 618,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: _steps(entry, accent, tint),
              ),
            ),
          ],
        ),
        if (photo.length > 1) ...[
          pw.SizedBox(height: _s4),
          _gallery(photo.skip(1).toList(), width),
        ],
        for (final block in entry.document.blocks) ..._block(block, accent),
        if (recipe.tags.isNotEmpty) ...[
          pw.SizedBox(height: _s4),
          pw.Text(
            recipe.tags.map((t) => '#$t').join('  '),
            style: pw.TextStyle(fontSize: _small, color: _secondary),
          ),
        ],
      ],
    );
  }

  /// Servings, times, methods and difficulty in one tinted box.
  List<pw.Widget> _facts(PageRecipe recipe, PdfColor accent, PdfColor tint) {
    final facts = <(String, String)>[
      if (recipe.servings case final servings?) ('', words.servings(servings)),
      ...words.times(recipe),
      if (recipe.difficulty case final d?)
        (words.difficulty, '${'●' * d}${'○' * (3 - d)}'),
      if (recipe.methods.isNotEmpty) ('', recipe.methods.join(', ')),
    ];
    if (facts.isEmpty) return const [];
    return [
      pw.SizedBox(height: _s3),
      pw.Container(
        padding: pw.EdgeInsets.symmetric(horizontal: _s3, vertical: _s2),
        decoration: pw.BoxDecoration(
          color: tint,
          borderRadius: pw.BorderRadius.circular(_s2),
        ),
        child: pw.Wrap(
          spacing: _s4,
          runSpacing: _s1,
          children: [
            for (final (label, value) in facts)
              pw.RichText(
                text: pw.TextSpan(
                  children: [
                    if (label.isNotEmpty)
                      pw.TextSpan(
                        text: '$label ',
                        style: pw.TextStyle(
                          fontSize: _small,
                          color: _secondary,
                        ),
                      ),
                    pw.TextSpan(
                      text: value,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<pw.Widget> _ingredients(PageRecipe recipe, PdfColor accent) {
    if (recipe.ingredients.isEmpty) return [pw.SizedBox()];
    return [
      _subheading(words.ingredients, accent),
      for (final item in recipe.ingredients)
        pw.Padding(
          padding: pw.EdgeInsets.only(bottom: _s2),
          child: pw.RichText(
            text: pw.TextSpan(
              children: [
                if (words.quantity(item) case final q when q.isNotEmpty)
                  pw.TextSpan(
                    text: '$q  ',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                pw.TextSpan(text: item.name),
                if (item.link case final link?)
                  if (Uri.tryParse(link)?.host case final host?)
                    pw.TextSpan(
                      text: '  $host',
                      style: pw.TextStyle(
                        fontSize: _small,
                        color: accent,
                        decoration: pw.TextDecoration.underline,
                      ),
                      annotation: pw.AnnotationUrl(link),
                    ),
              ],
            ),
          ),
        ),
    ];
  }

  List<pw.Widget> _steps(CookbookRecipe entry, PdfColor accent, PdfColor tint) {
    final steps = entry.recipe.steps;
    if (steps.isEmpty) return [pw.SizedBox()];
    final width = (page.format.width - _margin.horizontal) * 0.618 - _s1;
    return [
      _subheading(words.steps, accent),
      for (final (i, step) in steps.indexed) ...[
        ..._markdown(
          step.text,
          lead: pw.TextSpan(
            text: '${i + 1}  ',
            style: pw.TextStyle(font: _display, fontSize: _h3, color: accent),
          ),
        ),
        if (step.pictures.any((p) => _image(p.media) != null)) ...[
          _gallery(step.pictures, width),
          pw.SizedBox(height: _s2),
        ],
        if (step.video != null) _video(entry, accent, tint),
        pw.SizedBox(height: _s3),
      ],
    ];
  }

  pw.Widget _video(CookbookRecipe entry, PdfColor accent, PdfColor tint) {
    final url = entry.page;
    if (url == null) {
      return pw.Padding(
        padding: pw.EdgeInsets.only(bottom: _s2),
        child: pw.Text(
          words.videoInNote,
          style: pw.TextStyle(fontSize: _small, color: _secondary),
        ),
      );
    }
    final side = _s5 * _phi;
    return pw.UrlLink(
      destination: url.toString(),
      child: pw.Container(
        padding: pw.EdgeInsets.all(_s2),
        decoration: pw.BoxDecoration(
          color: tint,
          borderRadius: pw.BorderRadius.circular(_s2),
        ),
        child: pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Container(
              color: _background,
              padding: pw.EdgeInsets.all(_s1),
              child: pw.BarcodeWidget(
                data: url.toString(),
                barcode: pw.Barcode.qrCode(),
                width: side,
                height: side,
                drawText: false,
                color: _text,
              ),
            ),
            pw.SizedBox(width: _s3),
            pw.SizedBox(
              width: side * _phi,
              child: pw.Text(
                words.scanForVideo,
                style: pw.TextStyle(fontSize: _small, color: accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pictures in rows of up to three golden rectangles.
  pw.Widget _gallery(List<RecipePicture> shown, double width) {
    final kept = [
      for (final p in shown)
        if (_image(p.media) != null) p,
    ];
    final across = math.min(3, kept.length);
    final gap = _s2;
    final side = (width - gap * (across - 1)) / across;
    return pw.Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final p in kept)
          pw.SizedBox(
            width: side,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.ClipRRect(
                  horizontalRadius: _s1,
                  verticalRadius: _s1,
                  child: pw.Image(
                    _image(p.media)!,
                    width: side,
                    height: side / _phi,
                    fit: pw.BoxFit.cover,
                  ),
                ),
                if (p.caption.isNotEmpty) _caption(p.caption),
              ],
            ),
          ),
      ],
    );
  }

  /// The other fields of the note, as serv.pub shows them after the steps.
  List<pw.Widget> _block(PageBlock block, PdfColor accent) {
    final body = switch (block) {
      MarkdownBlock(:final text) => _markdown(text),
      TextBlock(:final text) => [pw.Text(text)],
      TagsBlock(:final items) => [pw.Text(items.join(', '))],
      ChecklistBlock(:final items) => [
        for (final item in items)
          pw.Text('${item.done ? '☑' : '☐'}  ${item.text}'),
      ],
      LinksBlock(:final items) => [
        for (final link in items)
          pw.UrlLink(
            destination: link.url,
            child: pw.Text(
              link.title.isEmpty ? link.url : link.title,
              style: pw.TextStyle(
                color: accent,
                decoration: pw.TextDecoration.underline,
              ),
            ),
          ),
      ],
      ImageBlock(:final media, :final caption) => [
        if (_image(media) case final image?)
          pw.Image(
            image,
            width: (page.format.width - _margin.horizontal) / _phi,
          ),
        if (caption.isNotEmpty) _caption(caption),
      ],
      AudioBlock() => const <pw.Widget>[],
    };
    if (body.isEmpty) return const [];
    final short = block is TextBlock && !block.text.contains('\n');
    if (short) {
      return [
        pw.SizedBox(height: _s2),
        pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(
                text: '${block.label}  ',
                style: pw.TextStyle(color: _secondary, fontSize: _small),
              ),
              pw.TextSpan(
                text: block.text,
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      pw.SizedBox(height: _s4),
      _subheading(block.label, accent),
      ...body,
    ];
  }

  // ------------------------------------------------------------- index

  pw.MultiPage _index(
    Map<CookbookRecipe, int> number,
    String? Function(CookbookRecipe) numberOf,
  ) {
    String? letter;
    final lines = <pw.Widget>[];
    for (final item in book.ingredients) {
      final first = _initial(item.name);
      if (first != letter) {
        letter = first;
        lines.add(
          pw.Padding(
            padding: pw.EdgeInsets.only(top: _s4, bottom: _s1),
            child: pw.Text(
              first,
              style: pw.TextStyle(
                font: _display,
                fontSize: _h3,
                color: _accent,
              ),
            ),
          ),
        );
      }
      lines.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(bottom: _s1),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(flex: 618, child: pw.Text(item.name)),
              pw.SizedBox(width: _s3),
              pw.Expanded(
                flex: 382,
                child: pw.Wrap(
                  spacing: _s2,
                  children: [
                    for (final recipe in item.recipes)
                      pw.Link(
                        destination: _anchor(number[recipe]!),
                        child: pw.Text(
                          numberOf(recipe) ?? '',
                          style: pw.TextStyle(color: _secondary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return pw.MultiPage(
      pageTheme: _theme(),
      maxPages: 1000,
      footer: _footer,
      build: (context) => [_heading(words.ingredientIndex, _accent), ...lines],
    );
  }

  static String _initial(String name) {
    final runes = name.trim().runes;
    if (runes.isEmpty) return '#';
    final first = String.fromCharCode(runes.first).toUpperCase();
    return RegExp(r'\p{L}', unicode: true).hasMatch(first) ? first : '#';
  }

  // ---------------------------------------------------------- the text

  pw.Widget _heading(String text, PdfColor colour) => pw.Padding(
    padding: pw.EdgeInsets.only(bottom: _s4),
    child: pw.Text(
      text,
      style: pw.TextStyle(
        font: _display,
        fontSize: _h1,
        color: colour,
        lineSpacing: 0,
      ),
    ),
  );

  pw.Widget _subheading(String text, PdfColor colour) => pw.Padding(
    padding: pw.EdgeInsets.only(bottom: _s3),
    child: pw.Text(
      text,
      style: pw.TextStyle(font: _display, fontSize: _h3, color: colour),
    ),
  );

  pw.Widget _caption(String text) => pw.Padding(
    padding: pw.EdgeInsets.only(top: _s1),
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: _small, color: _secondary),
    ),
  );

  /// [source] read by the notes' own Markdown reader: no HTML, no address
  /// fetched; a picture in the text is shown only when the book has it.
  List<pw.Widget> _markdown(String source, {pw.InlineSpan? lead}) {
    final blocks = MarkdownDocument.parse(source).blocks;
    final out = <pw.Widget>[];
    var first = true;
    for (final block in blocks) {
      out.addAll(_mdBlock(block, first ? lead : null, 0));
      first = false;
    }
    if (out.isEmpty && lead != null) {
      out.add(pw.RichText(text: pw.TextSpan(children: [lead])));
    }
    return out;
  }

  List<pw.Widget> _mdBlock(MdBlock block, pw.InlineSpan? lead, int depth) {
    final gap = pw.EdgeInsets.only(bottom: _s2, left: _s3 * depth);
    pw.Widget paragraph(List<MdInline> inlines, pw.TextStyle? style) =>
        pw.Padding(
          padding: gap,
          child: pw.RichText(
            text: pw.TextSpan(
              style: style,
              children: [?lead, ..._inlines(inlines, const pw.TextStyle())],
            ),
          ),
        );
    switch (block) {
      case MdHeading(:final level, :final inlines):
        return [
          paragraph(
            inlines,
            pw.TextStyle(
              font: _display,
              fontSize: level <= 2 ? _h3 : _base,
              color: _text,
            ),
          ),
        ];
      case MdParagraph(:final inlines):
        final pictures = [
          for (final inline in inlines)
            if (inline case MdImage(:final url) when url.startsWith('image:'))
              if (_mediaOf(url.substring(6)) case final id?)
                if (_image(id) != null) id,
        ];
        return [
          if (inlines.any((i) => i is! MdImage) || lead != null)
            paragraph(inlines, null),
          for (final id in pictures)
            pw.Padding(
              padding: gap,
              child: pw.Image(
                _image(id)!,
                width: (page.format.width - _margin.horizontal) / _phi,
              ),
            ),
        ];
      case MdList(:final ordered, :final start, :final items):
        return [
          if (lead != null) pw.RichText(text: pw.TextSpan(children: [lead])),
          for (final (i, item) in items.indexed) ...[
            for (final (j, inner) in item.blocks.indexed)
              ..._mdBlock(
                inner,
                j == 0
                    ? pw.TextSpan(
                        text: switch (item.checked) {
                          true => '☑  ',
                          false => '☐  ',
                          null => ordered ? '${start + i}.  ' : '•  ',
                        },
                        style: pw.TextStyle(color: _secondary),
                      )
                    : null,
                depth + 1,
              ),
          ],
        ];
      case MdQuote(:final blocks):
        return [
          pw.Container(
            margin: gap,
            padding: pw.EdgeInsets.only(left: _s3),
            decoration: pw.BoxDecoration(
              border: pw.Border(left: pw.BorderSide(color: _accent, width: 2)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final inner in blocks) ..._mdBlock(inner, null, 0),
              ],
            ),
          ),
        ];
      case MdCodeBlock(:final text):
        return [
          pw.Padding(
            padding: gap,
            child: pw.Text(text, style: pw.TextStyle(color: _secondary)),
          ),
        ];
      case MdRule():
        return [pw.Divider(color: _secondary, thickness: 0.5)];
    }
  }

  List<pw.InlineSpan> _inlines(List<MdInline> inlines, pw.TextStyle style) => [
    for (final inline in inlines)
      switch (inline) {
        MdText(:final text) => pw.TextSpan(text: text, style: style),
        MdCode(:final text) => pw.TextSpan(
          text: text,
          style: style.copyWith(color: _secondary),
        ),
        MdStrong(:final children) => pw.TextSpan(
          children: _inlines(
            children,
            style.copyWith(fontWeight: pw.FontWeight.bold),
          ),
        ),
        MdEmphasis(:final children) => pw.TextSpan(
          children: _inlines(children, style.copyWith(color: _secondary)),
        ),
        MdStrike(:final children) => pw.TextSpan(
          children: _inlines(
            children,
            style.copyWith(decoration: pw.TextDecoration.lineThrough),
          ),
        ),
        MdLink(:final children, :final url) => switch (Uri.tryParse(url)) {
          final uri? when uri.isScheme('https') || uri.isScheme('http') =>
            pw.TextSpan(
              children: _inlines(
                children,
                style.copyWith(
                  color: _accent,
                  decoration: pw.TextDecoration.underline,
                ),
              ),
              annotation: pw.AnnotationUrl(uri.toString()),
            ),
          _ => pw.TextSpan(children: _inlines(children, style)),
        },
        // Shown under the paragraph, or by its words alone.
        MdImage(:final alt, :final url) =>
          url.startsWith('image:') &&
                  _mediaOf(url.substring(6)) != null &&
                  _image(_mediaOf(url.substring(6))!) != null
              ? const pw.TextSpan(text: '')
              : pw.TextSpan(
                  text: alt,
                  style: style.copyWith(color: _secondary),
                ),
      },
  ];

  MediaId? _mediaOf(String id) {
    try {
      return MediaId(id);
    } on PublishingException {
      return null;
    }
  }

  pw.ImageProvider? _image(MediaId id) => _images.putIfAbsent(id, () {
    final bytes = pictures[id];
    if (bytes == null) return null;
    try {
      return pw.MemoryImage(bytes);
    } on Object {
      return null;
    }
  });

  static String _anchor(int index) => 'recipe-$index';
}
