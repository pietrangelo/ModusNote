import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'page_appearance.dart';

/// The typefaces of the page, loaded from the app's own assets the first
/// time they are chosen: on the web nothing is downloaded for a typeface
/// no one picked, and the first start costs no more than before.
class ReadingFonts extends ChangeNotifier {
  ReadingFonts({Future<void> Function(PageFont font)? load})
    : _load = load ?? _fromAssets;

  final Future<void> Function(PageFont font) _load;
  final _ready = <PageFont>{PageFont.inter};
  final _loading = <PageFont, Future<void>>{};

  /// Whether text can be drawn in [font]: until then the page keeps the
  /// body font, so it never shows a half-loaded family.
  bool isReady(PageFont font) => _ready.contains(font);

  /// Loads [font] once; a failure (a damaged asset) leaves the page in
  /// the body font and can be tried again.
  Future<void> ensure(PageFont font) {
    if (isReady(font)) return Future.value();
    return _loading[font] ??= _load(font).then(
      (_) {
        _ready.add(font);
        notifyListeners();
      },
      onError: (Object _) {
        _loading.remove(font);
      },
    );
  }

  static Future<void> _fromAssets(PageFont font) {
    final loader = FontLoader(font.family);
    for (final asset in font.assets) {
      loader.addFont(rootBundle.load(asset));
    }
    return loader.load();
  }
}
