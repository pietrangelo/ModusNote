import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/open_in_browser.dart';
import '../l10n/generated/app_localizations.dart';
import '../notes/recipes/recipe_text.dart';
import '../notes/schema_text.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import 'field_description.dart';
import 'site_settings_sheet.dart';

/// What the notes need to publish: the vault's [Publisher] and the way to
/// ask the person to prove again that the vault is theirs ([confirm]),
/// which every step that puts something on serv.pub needs.
final class PublishingAccess {
  const PublishingAccess({required this.publisher, required this.confirm});

  final Publisher publisher;

  /// True once the vault is confirmed, asking for the passphrase (or the
  /// passkey) unless an earlier confirmation still lasts.
  final Future<bool> Function() confirm;
}

/// Gives the screens over the notes the vault's [PublishingAccess]; absent
/// in a build without a server.
class PublishingScope extends InheritedWidget {
  const PublishingScope({
    required this.access,
    required super.child,
    super.key,
  });

  final PublishingAccess access;

  static PublishingAccess? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PublishingScope>()?.access;

  @override
  bool updateShouldNotify(PublishingScope oldWidget) =>
      access != oldWidget.access;
}

/// Publishes one note on serv.pub: the site first, if the vault has none;
/// then the fields to show, the layout, pictures or not, a preview as an
/// unlisted draft and the page itself. Says before anything else that the
/// page will be readable by anyone, outside the vault's encryption.
class PublishSheet extends StatefulWidget {
  const PublishSheet({
    required this.access,
    required this.entry,
    required this.schema,
    this.category = '',
    super.key,
  });

  final PublishingAccess access;
  final DynamicEntry entry;
  final SchemaDefinition schema;

  /// The name of the note's category: a recipe's section in the cookbook.
  final String category;

  static Future<void> show(
    BuildContext context, {
    required PublishingAccess access,
    required DynamicEntry entry,
    required SchemaDefinition schema,
    String category = '',
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: Extents.xxl),
    builder: (_) => PublishSheet(
      access: access,
      entry: entry,
      schema: schema,
      category: category,
    ),
  );

  @override
  State<PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<PublishSheet> {
  final _name = TextEditingController();
  final _title = TextEditingController();
  late final Set<FieldKey> _fields;
  late PublicationLayout _layout;
  var _pictures = true;

  /// Whether the cookbook shows the note's category: its name is the
  /// person's own and leaves the vault only when they see it and agree.
  var _withCategory = true;
  var _loading = true;
  var _busy = false;
  SiteBook? _book;
  String? _problem;

  bool get _isRecipe => widget.schema.id.name == Recipe.schema;

  /// The layouts this note may take: a recipe's own first.
  List<PublicationLayout> get _layouts => [
    if (_isRecipe) PublicationLayout.recipe,
    PublicationLayout.essay,
    PublicationLayout.goldenSection,
    PublicationLayout.goldenCover,
    PublicationLayout.book,
  ];

  bool get _hasPictures =>
      AttachmentsValue.imagesOf(widget.entry).isNotEmpty ||
      StepsValue.videosOf(widget.entry).isNotEmpty ||
      widget.entry.attributes.values.any(
        (v) => v is TextValue && InlineImages.find(v.text).isNotEmpty,
      );

  @override
  void initState() {
    super.initState();
    _fields = {
      for (final field in PublicationPolicy.publishableFields(widget.schema))
        if (_hasValue(widget.entry.valueOf(field.key))) field.key,
    };
    _layout = PublicationLayout.forSchemaName(widget.schema.id.name);
    _load();
  }

  static bool _hasValue(FieldValue? value) => switch (value) {
    null || SecretValue() => false,
    TextValue(:final text) => text.trim().isNotEmpty,
    TagListValue(:final tags) => tags.isNotEmpty,
    ChecklistValue(:final items) => items.isNotEmpty,
    AttachmentsValue(:final items) => items.isNotEmpty,
    _ => true,
  };

  Future<void> _load() async {
    final book = await widget.access.publisher.book();
    if (!mounted) return;
    setState(() {
      _book = book;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _title.dispose();
    super.dispose();
  }

  PublishedPage? get _page => _book?.pages[widget.entry.id];

  Future<void> _run(Future<void> Function() step) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await step();
    } on SiteNameTakenException {
      _problem = l10n.publishSiteNameTaken;
    } on InvalidSiteNameException {
      _problem = l10n.publishSiteNameInvalid;
    } on NotPublishableException {
      _problem = l10n.publishNothing;
    } on PublishingUnavailableException {
      _problem = l10n.publishOffline;
    } on PublishingRejectedException catch (e) {
      _problem = e.reason == PublishingRejection.limit
          ? l10n.publishLimit
          : l10n.publishFailed;
    } on NoSiteException {
      _problem = l10n.publishNoKey;
    } on PublishingConfirmationRequiredException {
      // The confirmation ran out: nothing was sent.
    } on Object {
      _problem = l10n.publishFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim() => _run(() async {
    final name = SiteName(_name.text.trim());
    final title = _title.text.trim().isEmpty ? name.value : _title.text;
    final lang = Localizations.localeOf(context).languageCode == 'it'
        ? 'it'
        : 'en';
    if (!await widget.access.confirm()) return;
    final book = await widget.access.publisher.claim(
      name,
      SiteSettings(title: title, lang: lang),
    );
    if (mounted) setState(() => _book = book);
  });

  Future<void> _publish({required bool listed}) => _run(() async {
    final book = _book;
    if (book == null) return;
    final texts = SchemaText(AppLocalizations.of(context));
    final recipes = RecipeText(AppLocalizations.of(context));
    final words = RecipeWords(
      unit: recipes.unit,
      option: texts.option,
      category: _withCategory ? widget.category : '',
    );
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (!await widget.access.confirm()) return;
    final content = PublicationPolicy.compose(
      entry: widget.entry,
      schema: widget.schema,
      fields: _fields,
      published: book.slugs,
      includePictures: _pictures,
    );
    final url = await widget.access.publisher.publish(
      entry: widget.entry.id,
      content: content,
      schema: widget.schema,
      labelOf: (field) => texts.label(field.label),
      describe: (field, value) => describeField(texts, locale, field, value),
      ingredientLine: recipes.line,
      recipeWords: words,
      draft: !listed,
      layout: _layout,
    );
    final next = await widget.access.publisher.book();
    if (!mounted) return;
    setState(() => _book = next);
    if (!listed) await openInBrowser(url);
  });

  /// The site's own panel; the site may come back changed, or withdrawn.
  Future<void> _openSite(SiteBook book) async {
    await SiteSettingsSheet.show(context, access: widget.access, book: book);
    final next = await widget.access.publisher.book();
    if (mounted) setState(() => _book = next);
  }

  Future<void> _withdraw() => _run(() async {
    await widget.access.publisher.withdraw(widget.entry.id);
    final next = await widget.access.publisher.book();
    if (!mounted) return;
    setState(() => _book = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).publishWithdrawn)),
    );
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final book = _book;
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
            Text(l10n.publishTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.m),
            const _PublicWarning(),
            const SizedBox(height: Spacing.l),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (book == null)
              ..._siteForm(context)
            else
              ..._pageForm(context, book),
            if (_problem case final problem?) ...[
              const SizedBox(height: Spacing.m),
              Text(
                problem,
                key: const ValueKey('publish-problem'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _siteForm(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return [
      Text(l10n.publishSiteIntro, style: theme.textTheme.bodyMedium),
      const SizedBox(height: Spacing.m),
      TextField(
        key: const ValueKey('publish-site-name'),
        controller: _name,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: SiteName.maxLength,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[a-z0-9-]')),
        ],
        decoration: InputDecoration(
          labelText: l10n.publishSiteName,
          prefixText: 'serv.pub/',
          helperText: l10n.publishSiteNameHelp,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: Spacing.s),
      TextField(
        key: const ValueKey('publish-site-title'),
        controller: _title,
        enabled: !_busy,
        maxLength: SiteSettings.maxTitle,
        decoration: InputDecoration(labelText: l10n.publishSiteTitle),
      ),
      const SizedBox(height: Spacing.m),
      if (_busy)
        _Working(text: l10n.publishCreatingSite)
      else
        FilledButton(
          key: const ValueKey('publish-create-site'),
          onPressed: _name.text.trim().length < SiteName.minLength
              ? null
              : _claim,
          child: Text(l10n.publishCreateSite),
        ),
    ];
  }

  List<Widget> _pageForm(BuildContext context, SiteBook book) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final texts = SchemaText(l10n);
    final page = _page;
    final ready = !_busy && _fields.isNotEmpty;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              book.home.toString(),
              key: const ValueKey('publish-site'),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ModusPalette.of(context).muted,
              ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('publish-site-settings'),
            onPressed: _busy ? null : () => _openSite(book),
            icon: const Icon(Icons.palette_outlined),
            label: Text(l10n.siteSettingsOpen),
          ),
        ],
      ),
      const SizedBox(height: Spacing.m),
      if (page != null) ...[
        _PageLink(url: book.pageUrl(page.slug), listed: page.listed),
        if (page.listed && _layout == PublicationLayout.recipe)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('publish-open-cookbook'),
              onPressed: () => openInBrowser(book.cookbookUrl),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(l10n.publishOpenCookbook),
            ),
          ),
        const SizedBox(height: Spacing.l),
      ],
      Text(l10n.publishFields, style: theme.textTheme.titleMedium),
      for (final field in PublicationPolicy.publishableFields(widget.schema))
        CheckboxListTile(
          key: ValueKey('publish-field-${field.key.value}'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _fields.contains(field.key),
          onChanged: _busy || !_hasValue(widget.entry.valueOf(field.key))
              ? null
              : (on) => setState(
                  () => on == true
                      ? _fields.add(field.key)
                      : _fields.remove(field.key),
                ),
          title: Text(texts.label(field.label)),
        ),
      const SizedBox(height: Spacing.m),
      Text(l10n.publishLayout, style: theme.textTheme.titleMedium),
      const SizedBox(height: Spacing.s),
      Wrap(
        spacing: Spacing.s,
        runSpacing: Spacing.s,
        children: [
          for (final layout in _layouts)
            ChoiceChip(
              key: ValueKey('publish-layout-${layout.name}'),
              label: Text(switch (layout) {
                PublicationLayout.goldenSection =>
                  l10n.publishLayoutGoldenSection,
                PublicationLayout.goldenCover => l10n.publishLayoutGoldenCover,
                PublicationLayout.book => l10n.publishLayoutBook,
                PublicationLayout.recipe => l10n.publishLayoutRecipe,
                _ => l10n.publishLayoutEssay,
              }),
              selected: _layout == layout,
              onSelected: _busy
                  ? null
                  : (_) => setState(() => _layout = layout),
            ),
        ],
      ),
      if (_layout == PublicationLayout.recipe) ...[
        const SizedBox(height: Spacing.s),
        Text(
          l10n.publishLayoutRecipeHelp,
          key: const ValueKey('publish-recipe-help'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: ModusPalette.of(context).muted,
          ),
        ),
        if (widget.category.trim().isNotEmpty)
          SwitchListTile(
            key: const ValueKey('publish-category'),
            contentPadding: EdgeInsets.zero,
            value: _withCategory,
            onChanged: _busy
                ? null
                : (on) => setState(() => _withCategory = on),
            title: Text(l10n.publishRecipeCategory(widget.category.trim())),
            subtitle: Text(l10n.publishRecipeCategoryHelp),
          ),
      ],
      if (_hasPictures) ...[
        const SizedBox(height: Spacing.s),
        SwitchListTile(
          key: const ValueKey('publish-pictures'),
          contentPadding: EdgeInsets.zero,
          value: _pictures,
          onChanged: _busy ? null : (on) => setState(() => _pictures = on),
          title: Text(l10n.publishPictures),
          subtitle: Text(l10n.publishPicturesHelp),
        ),
      ],
      const SizedBox(height: Spacing.l),
      if (_busy)
        _Working(text: l10n.publishWorking)
      else ...[
        Row(
          children: [
            Expanded(
              flex: 382,
              child: OutlinedButton(
                key: const ValueKey('publish-preview'),
                onPressed: ready ? () => _publish(listed: false) : null,
                child: Text(l10n.publishPreview),
              ),
            ),
            const SizedBox(width: Spacing.s),
            Expanded(
              flex: 618,
              child: FilledButton(
                key: const ValueKey('publish-confirm'),
                onPressed: ready ? () => _publish(listed: true) : null,
                child: Text(switch ((page, _layout)) {
                  (_?, _) => l10n.publishUpdate,
                  (null, PublicationLayout.recipe) => l10n.publishToCookbook,
                  _ => l10n.publishConfirm,
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.s),
        Text(
          l10n.publishPreviewHelp,
          style: theme.textTheme.bodySmall?.copyWith(
            color: ModusPalette.of(context).muted,
          ),
        ),
        if (page != null || book.drafts[widget.entry.id] != null) ...[
          const SizedBox(height: Spacing.m),
          TextButton.icon(
            key: const ValueKey('publish-withdraw'),
            onPressed: _withdraw,
            icon: const Icon(Icons.public_off),
            label: Text(l10n.publishWithdraw),
          ),
        ],
      ],
    ];
  }
}

/// Said before anything else, in gold like the passphrase warning.
class _PublicWarning extends StatelessWidget {
  const _PublicWarning();

  @override
  Widget build(BuildContext context) {
    final palette = ModusPalette.of(context);
    return DecoratedBox(
      key: const ValueKey('publish-warning'),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: palette.primary, width: Spacing.xxs),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.public, size: IconSizes.inline, color: palette.primary),
            const SizedBox(width: Spacing.s),
            Expanded(
              child: Text(
                AppLocalizations.of(context).publishWarning,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageLink extends StatelessWidget {
  const _PageLink({required this.url, required this.listed});

  final Uri url;
  final bool listed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          listed ? l10n.publishListed : l10n.publishDraft,
          style: theme.textTheme.labelLarge?.copyWith(
            color: ModusPalette.of(context).primary,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        SelectableText(
          url.toString(),
          key: const ValueKey('publish-url'),
          style: theme.textTheme.bodyMedium,
        ),
        Wrap(
          spacing: Spacing.s,
          children: [
            TextButton.icon(
              onPressed: () => openInBrowser(url),
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.publishOpen),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url.toString()));
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.publishLinkCopied)));
              },
              icon: const Icon(Icons.link),
              label: Text(l10n.publishCopyLink),
            ),
          ],
        ),
      ],
    );
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(
        dimension: IconSizes.inline,
        child: CircularProgressIndicator(strokeWidth: Spacing.xxs),
      ),
      const SizedBox(width: Spacing.m),
      Expanded(child: Text(text)),
    ],
  );
}
