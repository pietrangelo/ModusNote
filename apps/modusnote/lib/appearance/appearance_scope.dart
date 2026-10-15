import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'page_appearance.dart';
import 'reading_fonts.dart';

/// The appearance this device chose. It lives above the app's navigator,
/// so that every route sees it; the open vault fills it from a sealed
/// setting ([attach]) and keeps each change there.
class AppearanceSettings extends ChangeNotifier {
  AppearanceSettings({ReadingFonts? fonts}) : fonts = fonts ?? ReadingFonts() {
    this.fonts.addListener(notifyListeners);
  }

  final ReadingFonts fonts;

  /// The typeface the page is drawn in now: the chosen one once loaded,
  /// the body font until then.
  PageFont get shownFont =>
      fonts.isReady(_page.font) ? _page.font : PageFont.inter;

  Future<void> Function(Uint8List bytes)? _persist;

  PageAppearance _page = const PageAppearance();
  PageAppearance get page => _page;

  set page(PageAppearance page) {
    if (page == _page) return;
    _page = page;
    unawaited(fonts.ensure(page.font));
    notifyListeners();
    if (_persist case final persist?) unawaited(persist(page.toBytes()));
  }

  /// The vault opened: shows what it keeps and keeps each change with
  /// [persist].
  void attach(
    PageAppearance page, {
    required Future<void> Function(Uint8List bytes) persist,
  }) {
    _persist = persist;
    if (page == _page) return;
    _page = page;
    unawaited(fonts.ensure(page.font));
    notifyListeners();
  }

  @override
  void dispose() {
    fonts.removeListener(notifyListeners);
    super.dispose();
  }

  /// The vault closed: nothing more is kept, and the page is back to the
  /// defaults unless [reset] is false (a vault going away with its screen,
  /// while the tree is being taken down, notifies no one).
  void detach({bool reset = true}) {
    _persist = null;
    if (!reset || _page == const PageAppearance()) return;
    _page = const PageAppearance();
    notifyListeners();
  }
}

/// Makes [AppearanceSettings] available below it. A page without a scope
/// above it (a test) shows the defaults and offers no change.
class AppearanceScope extends InheritedNotifier<AppearanceSettings> {
  const AppearanceScope({
    required AppearanceSettings settings,
    required super.child,
    super.key,
  }) : super(notifier: settings);

  static AppearanceSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;

  /// The page this device chose, or the default one.
  static PageAppearance pageOf(BuildContext context) =>
      maybeOf(context)?.page ?? const PageAppearance();
}
