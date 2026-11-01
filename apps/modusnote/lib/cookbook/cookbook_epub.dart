import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:publishing/publishing.dart';

import '../backup/zip_writer.dart';
import '../notes/markdown/markdown_document.dart';
import 'cookbook.dart';
import 'cookbook_words.dart';

/// Writes a [Cookbook] as an EPUB 3 for e-readers (Kobo, Apple Books,
/// Google Play Books; a Kindle takes it through «Send to Kindle»): a
/// title page, the contents, a page per chapter and per recipe, and the
/// index of ingredients, all linked. The text reflows, so the layout is
/// left to the reader; the chapters keep their colours. Every word of the
/// person is escaped, and the Markdown is read by the notes' own reader,
/// so no markup of theirs reaches the file. No script, no font, no
/// address fetched.
final class CookbookEpub {
  CookbookEpub({
    required this.book,
    required this.words,
    required this.pictures,
    this.lang = 'it',
    Random? random,
  }) : _random = random ?? Random.secure();

  final Cookbook book;
  final CookbookWords words;

  /// The pictures the book shows, as JPEG or PNG; a picture not here is
  /// left out.
  final Map<MediaId, Uint8List> pictures;
  final String lang;
  final Random _random;

  /// The whole file.
  Uint8List render({required DateTime at}) {
    final zip = ZipWriter(at: at);
    // First and stored: what tells a reader the archive is an EPUB.
    zip.add('mimetype', ascii.encode('application/epub+zip'));
    zip.add('META-INF/container.xml', utf8.encode(_container));
    final recipes = book.recipes.toList();
    final number = {for (final (i, r) in recipes.indexed) r: i};
    final files = <String, String>{}; // path → media type
    final spine = <String>[];
    final images = <MediaId, String>{};

    String? imageOf(MediaId id) {
      if (images[id] case final name?) return name;
      final bytes = pictures[id];
      if (bytes == null) return null;
      final type = _imageType(bytes);
      if (type == null) return null;
      final name =
          'images/p${images.length}.${type == 'image/png' ? 'png' : 'jpg'}';
      images[id] = name;
      zip.add('EPUB/$name', bytes);
      files[name] = type;
      return name;
    }

    void page(String name, String title, String body) {
      zip.add('EPUB/$name', utf8.encode(_page(title, body)));
      files[name] = 'application/xhtml+xml';
      spine.add(name);
    }

    // The title page, with the first photo of the book.
    String? cover;
    for (final recipe in recipes) {
      for (final p in recipe.recipe.cover) {
        cover ??= imageOf(p.media);
      }
    }
    page(
      'title.xhtml',
      book.title,
      '<section class="cover">'
          '${cover == null ? '' : '<img class="photo" src="$cover" alt=""/>'}'
          '<h1>${_e(book.title)}</h1>'
          '<p class="count">${_e(words.recipeCount(recipes.length))}</p>'
          '<p class="made">${_e(words.madeWith)}</p>'
          '</section>',
    );

    final chapters = book.chapters;
    final separate = chapters.length > 1 || chapters.any((c) => c.depth > 0);
    final nav = StringBuffer('<ol>');
    for (final (c, chapter) in chapters.indexed) {
      final name = chapter.depth == 0 ? book.title : chapter.name;
      final colour = 'c$c';
      if (separate) {
        final file = 'chapter-$c.xhtml';
        page(
          file,
          name,
          '<section class="opener $colour">'
          '${chapter.depth > 1 ? '<p class="above">${_e(chapter.path.sublist(0, chapter.path.length - 1).join(' · '))}</p>' : ''}'
          '<h1>${_e(name)}</h1>'
          '<p class="count">${_e(words.recipeCount(chapter.recipes.length))}</p>'
          '</section>',
        );
        nav.write('<li><a href="$file">${_e(name)}</a><ol>');
      }
      for (final recipe in chapter.recipes) {
        final file = _recipeFile(number[recipe]!);
        page(file, recipe.title, _recipe(recipe, colour, imageOf));
        nav.write('<li><a href="$file">${_e(recipe.title)}</a></li>');
      }
      if (separate) nav.write('</ol></li>');
    }
    if (book.ingredients.isNotEmpty) {
      page('ingredients.xhtml', words.ingredientIndex, _index(number));
      nav.write(
        '<li><a href="ingredients.xhtml">${_e(words.ingredientIndex)}</a></li>',
      );
    }
    nav.write('</ol>');
    zip.add(
      'EPUB/nav.xhtml',
      utf8.encode(
        _page(
          words.contents,
          '<nav epub:type="toc" id="toc"><h1>${_e(words.contents)}</h1>'
          '$nav</nav>',
        ),
      ),
    );
    zip.add('EPUB/style.css', utf8.encode(_style()));
    zip.add(
      'EPUB/package.opf',
      utf8.encode(_package(files, spine, images[_firstCover()], at)),
    );
    return zip.finish();
  }

  MediaId? _firstCover() {
    for (final recipe in book.recipes) {
      for (final p in recipe.recipe.cover) {
        if (pictures.containsKey(p.media)) return p.media;
      }
    }
    return null;
  }

  String _recipe(
    CookbookRecipe entry,
    String colour,
    String? Function(MediaId) imageOf,
  ) {
    final recipe = entry.recipe;
    final out = StringBuffer('<article class="recipe $colour">')
      ..write('<h1>${_e(entry.title)}</h1>');
    final photos = [
      for (final p in recipe.cover)
        if (imageOf(p.media) case final src?) (src, p.caption),
    ];
    if (photos.isNotEmpty) out.write(_figure(photos.first, 'photo'));
    if (recipe.description.isNotEmpty) {
      out.write(_markdown(recipe.description, imageOf));
    }
    final facts = [
      if (recipe.servings case final s?) ('', words.servings(s)),
      ...words.times(recipe),
      if (recipe.difficulty case final d?)
        (words.difficulty, '${'●' * d}${'○' * (3 - d)}'),
      if (recipe.methods.isNotEmpty) ('', recipe.methods.join(', ')),
    ];
    if (facts.isNotEmpty) {
      out.write('<p class="facts">');
      out.write(
        facts
            .map(
              (f) => f.$1.isEmpty
                  ? '<b>${_e(f.$2)}</b>'
                  : '<span>${_e(f.$1)}</span> <b>${_e(f.$2)}</b>',
            )
            .join(' · '),
      );
      out.write('</p>');
    }
    if (recipe.ingredients.isNotEmpty) {
      out.write('<h2>${_e(words.ingredients)}</h2><ul class="ingredients">');
      for (final item in recipe.ingredients) {
        final q = words.quantity(item);
        out.write('<li>');
        if (q.isNotEmpty) out.write('<b>${_e(q)}</b> ');
        out.write(_e(item.name));
        if (item.link case final link? when _web(link) != null) {
          out.write(
            ' <a class="shop" href="${_a(link)}">${_e(_web(link)!.host)}</a>',
          );
        }
        out.write('</li>');
      }
      out.write('</ul>');
    }
    if (recipe.steps.isNotEmpty) {
      out.write('<h2>${_e(words.steps)}</h2><ol class="steps">');
      for (final step in recipe.steps) {
        out.write('<li>${_markdown(step.text, imageOf)}');
        final shown = [
          for (final p in step.pictures)
            if (imageOf(p.media) case final src?) (src, p.caption),
        ];
        for (final p in shown) {
          out.write(_figure(p, 'step'));
        }
        if (step.video != null) {
          out.write(switch (entry.page) {
            final url? =>
              '<p class="video"><a href="${_a(url.toString())}">'
                  '${_e(words.watchVideo)}</a></p>',
            null => '<p class="video">${_e(words.videoInNote)}</p>',
          });
        }
        out.write('</li>');
      }
      out.write('</ol>');
    }
    for (final p in photos.skip(1)) {
      out.write(_figure(p, 'photo'));
    }
    for (final block in entry.document.blocks) {
      out.write(_block(block, imageOf));
    }
    if (recipe.tags.isNotEmpty) {
      out.write(
        '<p class="tags">${_e(recipe.tags.map((t) => '#$t').join('  '))}</p>',
      );
    }
    out.write('</article>');
    return out.toString();
  }

  String _block(PageBlock block, String? Function(MediaId) imageOf) {
    final label = '<h2>${_e(block.label)}</h2>';
    return switch (block) {
      TextBlock(:final text) when !text.contains('\n') =>
        '<p class="fact"><span>${_e(block.label)}</span> <b>${_e(text)}</b></p>',
      TextBlock(:final text) => '$label<p>${_e(text)}</p>',
      MarkdownBlock(:final text) => '$label${_markdown(text, imageOf)}',
      TagsBlock(:final items) => '$label<p>${_e(items.join(', '))}</p>',
      ChecklistBlock(:final items) =>
        '$label<ul class="checklist">${[for (final i in items) '<li>${i.done ? '☑' : '☐'} ${_e(i.text)}</li>'].join()}</ul>',
      LinksBlock(:final items) =>
        '$label<ul>${[for (final l in items)
          if (_web(l.url) != null) '<li><a href="${_a(l.url)}">${_e(l.title.isEmpty ? l.url : l.title)}</a></li>'].join()}</ul>',
      ImageBlock(:final media, :final caption) => switch (imageOf(media)) {
        final src? => '$label${_figure((src, caption), 'photo')}',
        null => caption.isEmpty ? '' : '$label<p>${_e(caption)}</p>',
      },
      AudioBlock() => '',
    };
  }

  String _index(Map<CookbookRecipe, int> number) {
    final out = StringBuffer('<section class="index">')
      ..write('<h1>${_e(words.ingredientIndex)}</h1><dl>');
    for (final item in book.ingredients) {
      out.write('<dt>${_e(item.name)}</dt><dd>');
      out.write(
        item.recipes
            .map(
              (r) => '<a href="${_recipeFile(number[r]!)}">${_e(r.title)}</a>',
            )
            .join(', '),
      );
      out.write('</dd>');
    }
    out.write('</dl></section>');
    return out.toString();
  }

  String _figure((String, String) picture, String kind) {
    final (src, caption) = picture;
    return '<figure class="$kind"><img src="$src" alt="${_a(caption)}"/>'
        '${caption.isEmpty ? '' : '<figcaption>${_e(caption)}</figcaption>'}'
        '</figure>';
  }

  // ---------------------------------------------------------- Markdown

  String _markdown(String source, String? Function(MediaId) imageOf) {
    final out = StringBuffer();
    for (final block in MarkdownDocument.parse(source).blocks) {
      _mdBlock(block, out, imageOf);
    }
    return out.toString();
  }

  void _mdBlock(
    MdBlock block,
    StringBuffer out,
    String? Function(MediaId) imageOf,
  ) {
    switch (block) {
      case MdHeading(:final level, :final inlines):
        // Below the recipe's own h1 and its h2.
        final h = (level + 2).clamp(3, 6);
        out.write('<h$h>${_inlines(inlines, imageOf)}</h$h>');
      case MdParagraph(:final inlines):
        out.write('<p>${_inlines(inlines, imageOf)}</p>');
      case MdList(:final ordered, :final start, :final items):
        final tag = ordered ? 'ol' : 'ul';
        out.write(ordered && start != 1 ? '<ol start="$start">' : '<$tag>');
        for (final item in items) {
          out.write('<li>');
          if (item.checked case final done?) out.write(done ? '☑ ' : '☐ ');
          for (final inner in item.blocks) {
            _mdBlock(inner, out, imageOf);
          }
          out.write('</li>');
        }
        out.write('</$tag>');
      case MdQuote(:final blocks):
        out.write('<blockquote>');
        for (final inner in blocks) {
          _mdBlock(inner, out, imageOf);
        }
        out.write('</blockquote>');
      case MdCodeBlock(:final text):
        out.write('<pre>${_e(text)}</pre>');
      case MdRule():
        out.write('<hr/>');
    }
  }

  String _inlines(
    List<MdInline> inlines,
    String? Function(MediaId) imageOf,
  ) => inlines.map((inline) {
    return switch (inline) {
      MdText(:final text) => _e(text),
      MdCode(:final text) => '<code>${_e(text)}</code>',
      MdStrong(:final children) =>
        '<strong>${_inlines(children, imageOf)}</strong>',
      MdEmphasis(:final children) => '<em>${_inlines(children, imageOf)}</em>',
      MdStrike(:final children) => '<del>${_inlines(children, imageOf)}</del>',
      MdLink(:final children, :final url) => switch (_web(url)) {
        final uri? =>
          '<a href="${_a(uri.toString())}">${_inlines(children, imageOf)}</a>',
        null => _inlines(children, imageOf),
      },
      MdImage(:final alt, :final url) => switch (_picture(url, imageOf)) {
        final src? => '<img class="inline" src="$src" alt="${_a(alt)}"/>',
        null => _e(alt),
      },
    };
  }).join();

  String? _picture(String url, String? Function(MediaId) imageOf) {
    if (!url.startsWith('image:')) return null;
    try {
      return imageOf(MediaId(url.substring(6)));
    } on PublishingException {
      return null;
    }
  }

  static Uri? _web(String url) => switch (Uri.tryParse(url)) {
    final uri?
        when (uri.isScheme('https') || uri.isScheme('http')) &&
            uri.host.isNotEmpty =>
      uri,
    _ => null,
  };

  // ---------------------------------------------------------- the files

  static String _recipeFile(int index) => 'recipe-$index.xhtml';

  String _page(String title, String body) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE html>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops" '
      'xml:lang="${_a(lang)}" lang="${_a(lang)}">'
      '<head><meta charset="UTF-8"/><title>${_e(title)}</title>'
      '<link rel="stylesheet" type="text/css" href="style.css"/></head>'
      '<body>$body</body></html>\n';

  String _package(
    Map<String, String> files,
    List<String> spine,
    String? cover,
    DateTime at,
  ) {
    final id = _uuid();
    final modified = '${at.toUtc().toIso8601String().substring(0, 19)}Z';
    final items = StringBuffer(
      '<item id="nav" href="nav.xhtml" '
      'media-type="application/xhtml+xml" properties="nav"/>'
      '<item id="css" href="style.css" media-type="text/css"/>',
    );
    final ids = <String, String>{};
    for (final (i, MapEntry(key: path, value: type)) in files.entries.indexed) {
      final item = 'f$i';
      ids[path] = item;
      items.write(
        '<item id="$item" href="$path" media-type="$type"'
        '${path == cover ? ' properties="cover-image"' : ''}/>',
      );
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="id" xml:lang="${_a(lang)}">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="id">urn:uuid:$id</dc:identifier>'
        '<dc:title>${_e(book.title)}</dc:title>'
        '<dc:language>${_e(lang)}</dc:language>'
        '<meta property="dcterms:modified">$modified</meta>'
        '</metadata>'
        '<manifest>$items</manifest>'
        '<spine>${[for (final page in spine) '<itemref idref="${ids[page]}"/>'].join()}'
        '</spine></package>\n';
  }

  String _uuid() {
    final b = List.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// The type of a picture by its first bytes; null for one an EPUB
  /// reader need not show.
  static String? _imageType(Uint8List b) {
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length > 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    return null;
  }

  // The φ scale of the app, in em: half steps below and above the text.
  static const _small = '.786em';
  static const _body = '1em';
  static const _h2 = '1.272em';
  static const _h1 = '2.618em';

  String _style() {
    String hex(Srgb c) => c.hex;
    final p = book.palette;
    final out = StringBuffer(
      'body{font-family:sans-serif;line-height:1.5;color:${hex(p.text)};}'
      'h1{font-size:$_h1;line-height:1.15;margin:0 0 .618em;color:${hex(p.accent)};}'
      'h2{font-size:$_h2;margin:1.618em 0 .618em;color:${hex(p.accent)};}'
      'h3,h4,h5,h6{font-size:$_body;margin:1em 0 .382em;}'
      'figure{margin:1em 0;}figure img{width:100%;height:auto;}'
      'figure.step img{width:61.8%;}'
      'figcaption{font-size:$_small;color:${hex(p.secondaryText)};}'
      'img.inline{max-width:61.8%;height:auto;display:block;margin:.618em 0;}'
      '.facts,.fact{border-radius:.382em;padding:.382em .618em;}'
      '.facts span,.fact span{font-size:$_small;color:${hex(p.secondaryText)};}'
      'ul.ingredients{list-style:none;padding:0;}ul.ingredients li{margin:.382em 0;}'
      'a.shop{font-size:$_small;}'
      'ol.steps li{margin:0 0 1em;}'
      '.video{font-size:$_small;}'
      '.tags,.made,.above{color:${hex(p.secondaryText)};font-size:$_small;}'
      '.cover h1{font-size:$_h1;margin-top:1.618em;color:${hex(p.text)};}'
      '.cover .count{color:${hex(p.accent)};}'
      '.cover img.photo{width:100%;height:auto;}'
      '.opener{padding:38.2% 1em 2em;}'
      '.opener .count{font-size:$_h2;}'
      'dl dt{margin-top:.618em;}dl dd{margin:0 0 0 1.618em;}',
    );
    for (final (c, chapter) in book.chapters.indexed) {
      final accent = chapter.colours.accent.hex;
      final tint = chapter.colours.tint.hex;
      out.write(
        '.c$c h1,.c$c h2,.c$c a{color:$accent;}'
        '.c$c .facts,.c$c .fact{background:$tint;}'
        '.opener.c$c{background:$tint;}',
      );
    }
    return out.toString();
  }

  static const _container =
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="EPUB/package.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles>'
      '</container>\n';

  /// [text] as XHTML text: the markup characters escaped, and the
  /// characters XML 1.0 forbids dropped.
  static String _e(String text) => text
      .replaceAll(_forbidden, '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// [text] inside a double-quoted attribute.
  static String _a(String text) => _e(text).replaceAll('"', '&quot;');

  static final _forbidden = RegExp(
    '[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\uFFFE\\uFFFF]',
  );
}
