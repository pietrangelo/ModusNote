import 'package:flutter/material.dart' hide Typography;
import 'package:flutter/services.dart';
import 'package:publishing/publishing.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import 'publish_sheet.dart';

/// How the site looks and what it says about itself: title, presentation,
/// theme and hues (the colours derived with φ in OKLCH, so none can be
/// unreadable), text size, typeface, home, indexing. A preview shows the
/// colours as serv.pub will. Saving needs the vault confirmed, like every
/// step that changes what anyone can read; so does withdrawing the site.
class SiteSettingsSheet extends StatefulWidget {
  const SiteSettingsSheet({
    required this.access,
    required this.book,
    super.key,
  });

  final PublishingAccess access;
  final SiteBook book;

  static Future<void> show(
    BuildContext context, {
    required PublishingAccess access,
    required SiteBook book,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: Extents.xxl),
    builder: (_) => SiteSettingsSheet(access: access, book: book),
  );

  @override
  State<SiteSettingsSheet> createState() => _SiteSettingsSheetState();
}

class _SiteSettingsSheetState extends State<SiteSettingsSheet> {
  late final TextEditingController _title;
  late final TextEditingController _about;
  late SiteSettings _settings;
  var _busy = false;
  String? _problem;

  /// The hue a slider starts from when the person first turns it on.
  static const _startHue = 45.0;

  @override
  void initState() {
    super.initState();
    _settings = widget.book.settings;
    _title = TextEditingController(text: _settings.title);
    _about = TextEditingController(text: _settings.about);
  }

  @override
  void dispose() {
    _title.dispose();
    _about.dispose();
    super.dispose();
  }

  void _change(SiteSettings next) => setState(() => _settings = next);

  void _theme({
    BaseTheme? base,
    double? Function()? accentHue,
    double? Function()? backgroundHue,
  }) {
    final theme = _settings.theme;
    _change(
      _settings.copyWith(
        theme: SiteTheme(
          base ?? theme.base,
          accentHue: accentHue != null ? accentHue() : theme.accentHue,
          backgroundHue: backgroundHue != null
              ? backgroundHue()
              : theme.backgroundHue,
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() step) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await step();
    } on PublishingUnavailableException {
      _problem = l10n.publishOffline;
    } on NoSiteException {
      _problem = l10n.publishNoKey;
    } on NotPublishableException {
      _problem = l10n.publishFailed;
    } on PublishingConfirmationRequiredException {
      // The confirmation ran out: nothing was sent.
    } on Object {
      _problem = l10n.publishFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final title = _title.text.trim().isEmpty
        ? widget.book.name.value
        : _title.text;
    final settings = SiteSettings(
      title: title,
      about: _about.text,
      lang: _settings.lang,
      theme: _settings.theme,
      body: _settings.body,
      home: _settings.home,
      indexable: _settings.indexable,
      font: _settings.font,
    );
    if (!await widget.access.confirm()) return;
    await widget.access.publisher.updateSettings(settings);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).siteSaved)),
    );
  });

  Future<void> _withdrawSite() async {
    final l10n = AppLocalizations.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.siteWithdrawTitle),
        content: Text(l10n.siteWithdrawBody(widget.book.name.url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('site-withdraw-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.siteWithdrawConfirm),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(() async {
      if (!await widget.access.confirm()) return;
      await widget.access.publisher.withdrawSite();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.siteWithdrawn)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = ModusPalette.of(context).muted;
    final feed = '${widget.book.name.url}/feed.xml';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: Spacing.l,
          right: Spacing.l,
          bottom: Spacing.l,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.siteSettingsTitle, style: theme.textTheme.titleLarge),
            SelectableText(
              widget.book.home.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: Spacing.l),
            _SitePreview(
              settings: _settings.copyWith(
                title: _title.text.trim().isEmpty
                    ? widget.book.name.value
                    : _title.text,
              ),
            ),
            const SizedBox(height: Spacing.l),
            TextField(
              key: const ValueKey('site-title'),
              controller: _title,
              enabled: !_busy,
              maxLength: SiteSettings.maxTitle,
              decoration: InputDecoration(labelText: l10n.publishSiteTitle),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Spacing.s),
            TextField(
              key: const ValueKey('site-about'),
              controller: _about,
              enabled: !_busy,
              minLines: 2,
              maxLines: 8,
              maxLength: SiteSettings.maxAbout,
              decoration: InputDecoration(
                labelText: l10n.siteAbout,
                helperText: l10n.siteAboutHelp,
              ),
            ),
            const SizedBox(height: Spacing.l),
            _Heading(l10n.appTheme),
            Wrap(
              spacing: Spacing.s,
              runSpacing: Spacing.s,
              children: [
                for (final base in BaseTheme.values)
                  ChoiceChip(
                    key: ValueKey('site-theme-${base.name}'),
                    label: Text(switch (base) {
                      BaseTheme.modus => l10n.themeModus,
                      BaseTheme.restful => l10n.themeRestful,
                      BaseTheme.paper => l10n.themePaper,
                    }),
                    selected: _settings.theme.base == base,
                    onSelected: _busy ? null : (_) => _theme(base: base),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.m),
            _HueControl(
              key: const ValueKey('site-accent-hue'),
              label: l10n.siteAccentHue,
              hue: _settings.theme.accentHue,
              enabled: !_busy,
              onChanged: (hue) => _theme(accentHue: () => hue),
            ),
            _HueControl(
              key: const ValueKey('site-background-hue'),
              label: l10n.siteBackgroundHue,
              hue: _settings.theme.backgroundHue,
              enabled: !_busy,
              onChanged: (hue) => _theme(backgroundHue: () => hue),
            ),
            const SizedBox(height: Spacing.m),
            _Heading(l10n.siteBody),
            SegmentedButton<BodySize>(
              key: const ValueKey('site-body'),
              segments: [
                for (final size in BodySize.values)
                  ButtonSegment(value: size, label: Text('${size.px} px')),
              ],
              selected: {_settings.body},
              showSelectedIcon: false,
              onSelectionChanged: _busy
                  ? null
                  : (sizes) => _change(_settings.copyWith(body: sizes.first)),
            ),
            const SizedBox(height: Spacing.l),
            _Heading(l10n.pageFont),
            Wrap(
              spacing: Spacing.s,
              runSpacing: Spacing.s,
              children: [
                for (final font in SiteFont.values)
                  ChoiceChip(
                    key: ValueKey('site-font-${font.name}'),
                    label: Text(switch (font) {
                      SiteFont.inter => l10n.pageFontInter,
                      SiteFont.literata => l10n.pageFontLiterata,
                      SiteFont.atkinson => l10n.pageFontAtkinson,
                      SiteFont.quattro => l10n.pageFontQuattro,
                    }),
                    selected: _settings.font == font,
                    onSelected: _busy
                        ? null
                        : (_) => _change(_settings.copyWith(font: font)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.l),
            _Heading(l10n.siteHome),
            Wrap(
              spacing: Spacing.s,
              runSpacing: Spacing.s,
              children: [
                for (final home in const [
                  PublicationLayout.collection,
                  PublicationLayout.essay,
                ])
                  ChoiceChip(
                    key: ValueKey('site-home-${home.name}'),
                    label: Text(
                      home == PublicationLayout.collection
                          ? l10n.siteHomeCollection
                          : l10n.siteHomeEssay,
                    ),
                    selected: _settings.home == home,
                    onSelected: _busy
                        ? null
                        : (_) => _change(_settings.copyWith(home: home)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.m),
            SwitchListTile(
              key: const ValueKey('site-indexable'),
              contentPadding: EdgeInsets.zero,
              value: _settings.indexable,
              onChanged: _busy
                  ? null
                  : (on) => _change(_settings.copyWith(indexable: on)),
              title: Text(l10n.siteIndexable),
              subtitle: Text(l10n.siteIndexableHelp),
            ),
            const SizedBox(height: Spacing.s),
            _Heading(l10n.siteFeed),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    feed,
                    key: const ValueKey('site-feed'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: l10n.publishCopyLink,
                  icon: const Icon(Icons.link),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: feed));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.publishLinkCopied)),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: Spacing.l),
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else
              FilledButton(
                key: const ValueKey('site-save'),
                onPressed: _save,
                child: Text(l10n.siteSave),
              ),
            if (_problem case final problem?) ...[
              const SizedBox(height: Spacing.m),
              Text(
                problem,
                key: const ValueKey('site-problem'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: Spacing.xl),
            TextButton.icon(
              key: const ValueKey('site-withdraw'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: _busy ? null : _withdrawSite,
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text(l10n.siteWithdraw),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.s),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// A hue of the theme: the theme's own until the person turns it on, then
/// a slider round the colour wheel.
class _HueControl extends StatelessWidget {
  const _HueControl({
    required this.label,
    required this.hue,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String label;
  final double? hue;
  final bool enabled;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hue = this.hue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: hue != null,
          onChanged: enabled
              ? (on) => onChanged(on ? _SiteSettingsSheetState._startHue : null)
              : null,
          title: Text(label),
          subtitle: Text(l10n.siteHueOwn),
        ),
        if (hue != null)
          Slider(
            value: hue,
            max: 355,
            divisions: 71,
            label: '${hue.round()}°',
            onChanged: enabled ? onChanged : null,
          ),
      ],
    );
  }
}

/// The site as serv.pub will paint it: a golden rectangle in its colours,
/// the title climbing from the body by φ.
class _SitePreview extends StatelessWidget {
  const _SitePreview({required this.settings});

  final SiteSettings settings;

  static Color _color(Srgb c) => Color.fromARGB(0xFF, c.r, c.g, c.b);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = SitePalette.of(settings.theme);
    final type = Typography(settings.body);
    // Scaled to the preview: the body at the app's own caption size.
    const scale = 13 / 18;
    final text = _color(palette.text);
    return AspectRatio(
      key: const ValueKey('site-preview'),
      aspectRatio: Golden.phi,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _color(palette.background),
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: _color(palette.surface)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                settings.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _color(palette.secondaryText),
                  fontSize: type.caption * scale,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(flex: 382),
              Text(
                l10n.sitePreviewTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  color: text,
                  fontSize: type.h2 * scale,
                  fontWeight: FontWeight.w700,
                  height: 1.236,
                ),
              ),
              const SizedBox(height: Spacing.s),
              Text(
                l10n.sitePreviewText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: text,
                  fontSize: type.body * scale,
                  height: type.lineHeight,
                ),
              ),
              Text(
                l10n.sitePreviewLink,
                style: TextStyle(
                  color: _color(palette.accent),
                  fontSize: type.body * scale,
                  decoration: TextDecoration.underline,
                  decorationColor: _color(palette.accent),
                ),
              ),
              const Spacer(flex: 618),
              Container(
                height: Spacing.xxs,
                width: Extents.s,
                color: _color(palette.secondAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
