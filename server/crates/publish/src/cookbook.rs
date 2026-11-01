//! A site's cookbook: its recipe pages, the showcase at `/<site>/ricette`
//! with a band per category, each category's page and the search, and the
//! page of one recipe. All of it is rendered here, from the index the
//! site's object keeps, without a script: the search is a GET form the
//! object answers, and other servings are links it computes.

use serde::{Deserialize, Serialize};

use crate::names::page_slug;
use crate::page::Page;
use crate::recipe::{self, Recipe, category_slug, duration, fold, iso_duration};
use crate::render::{self, Meta, ORIGIN, block, cut, footer, head, markdown};
use crate::settings::SiteSettings;
use crate::text::escape;

/// The cookbook's address on a site: `/<site>/ricette`. No page may have it.
pub const PATH: &str = "ricette";

/// The longest search a reader can ask, in characters.
pub const MAX_QUERY: usize = 89;

/// The recipes another recipe's page shows from its category.
pub const MORE: usize = 3;

/// One listed recipe, as the showcase, the search and other recipes' pages
/// need it, kept beside the page so they never parse whole pages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Listed {
    pub slug: String,
    pub title: String,
    pub category: String,
    pub description: String,
    pub cover: Option<String>,
    pub total: Option<u32>,
    pub servings: Option<u16>,
    pub difficulty: Option<u8>,
    pub methods: Vec<String>,
    /// Everything a search looks in, folded: title, description,
    /// category, ingredients, tags.
    pub words: String,
    pub updated_ms: u64,
}

impl Listed {
    pub fn of(slug: &str, page: &Page, recipe: &Recipe, updated_ms: u64) -> Self {
        let mut words = vec![page.title.as_str(), recipe.description.as_str(), recipe.category.as_str()];
        words.extend(recipe.ingredients.iter().map(|i| i.name.as_str()));
        words.extend(recipe.tags.iter().map(String::as_str));
        Self {
            slug: slug.to_owned(),
            title: page.title.clone(),
            category: recipe.category.trim().to_owned(),
            description: cut(&render::plain(render::head_of(&recipe.description))),
            cover: recipe.cover.first().map(|p| p.media.clone()),
            total: recipe.total(),
            servings: recipe.servings,
            difficulty: recipe.difficulty,
            methods: recipe.methods.clone(),
            words: searchable(&words.join(" ")),
            updated_ms,
        }
    }

    pub fn category_slug(&self) -> String {
        category_slug(&self.category)
    }
}

/// The most a recipe's search words take, in bytes: every showcase read
/// loads them all, so a recipe with 233 long ingredients cannot make it
/// heavy.
pub const MAX_WORDS: usize = 4181;

/// `text` folded, on one line, cut at [`MAX_WORDS`] on a word's end.
fn searchable(text: &str) -> String {
    let mut out = String::new();
    for word in fold(text).split_whitespace() {
        if out.len() + word.len() + 1 > MAX_WORDS {
            break;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    out
}

/// A category of the cookbook: the name it first came with and the order
/// it came in, which picks its colours.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Category {
    pub slug: String,
    pub name: String,
    pub order: usize,
}

/// What a reader asked for in the address: a search, its filters, other
/// servings. Anything malformed is ignored, never an error.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Query {
    pub text: String,
    pub category: String,
    pub minutes: Option<u32>,
    pub method: String,
    pub servings: Option<u16>,
}

impl Query {
    pub fn parse(raw: Option<&str>) -> Self {
        let mut query = Self::default();
        let Some(raw) = raw else { return query };
        for pair in raw.split('&').take(13) {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            let value = decode(value);
            match key {
                "q" => query.text = value.trim().chars().take(MAX_QUERY).collect(),
                "c" if page_slug(&value) => query.category = value,
                "t" => query.minutes = value.parse().ok().filter(|m| (1..=recipe::MAX_MINUTES).contains(m)),
                "m" => query.method = value.trim().chars().take(recipe::MAX_CATEGORY).collect(),
                "p" => query.servings = value.parse().ok().filter(|n| (1..=recipe::MAX_SERVINGS).contains(n)),
                _ => {}
            }
        }
        query
    }

    /// Whether the showcase is answering a search.
    pub fn searching(&self) -> bool {
        !self.text.is_empty() || !self.category.is_empty() || self.minutes.is_some() || !self.method.is_empty()
    }

    fn matches(&self, entry: &Listed) -> bool {
        let words = fold(&self.text);
        words.split_whitespace().all(|w| entry.words.contains(w))
            && (self.category.is_empty() || entry.category_slug() == self.category)
            && self.minutes.is_none_or(|m| entry.total.is_some_and(|t| t <= m))
            && (self.method.is_empty() || entry.methods.contains(&self.method))
    }
}

/// `%XX` and `+` decoded; bytes that are not UTF-8 dropped; control
/// characters gone.
fn decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() && out.len() < 1024 {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("zz"), 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).chars().filter(|c| !c.is_control()).collect()
}

/// The cookbook's words in the site's language: Italian, or English for
/// every other.
#[derive(Debug)]
pub(crate) struct Words {
    italian: bool,
}

impl Words {
    pub(crate) fn of(lang: &str) -> Self {
        Self { italian: lang == "it" }
    }

    fn pick(&self, it: &'static str, en: &'static str) -> &'static str {
        if self.italian { it } else { en }
    }

    fn recipes(&self) -> &'static str {
        self.pick("Ricette", "Recipes")
    }

    fn count(&self, n: usize) -> String {
        match (self.italian, n) {
            (true, 1) => "1 ricetta".into(),
            (true, n) => format!("{n} ricette"),
            (false, 1) => "1 recipe".into(),
            (false, n) => format!("{n} recipes"),
        }
    }

    fn servings(&self, n: u16) -> String {
        match (self.italian, n) {
            (true, 1) => "1 porzione".into(),
            (true, n) => format!("{n} porzioni"),
            (false, 1) => "1 serving".into(),
            (false, n) => format!("{n} servings"),
        }
    }

    fn other_category(&self) -> &'static str {
        self.pick("Altre ricette", "More recipes")
    }

    fn category_name<'a>(&self, name: &'a str) -> &'a str {
        if name.is_empty() { self.other_category() } else { name }
    }

    fn within(&self, minutes: u32) -> String {
        format!("{} {}", self.pick("Entro", "Within"), duration(minutes))
    }
}

fn dots(difficulty: Option<u8>, words: &Words) -> String {
    match difficulty {
        Some(d) => format!(
            "<span class=\"dots\" title=\"{label} {d}/3\">{}{}</span>",
            "●".repeat(usize::from(d)),
            "○".repeat(3 - usize::from(d)),
            label = words.pick("Difficoltà", "Difficulty"),
        ),
        None => String::new(),
    }
}

/// The class that gives an element its category's colours.
fn class_of(categories: &[Category], slug: &str) -> String {
    categories.iter().find(|c| c.slug == slug).map_or_else(String::new, |c| format!("c{}", c.order))
}

fn card(
    site: &str,
    entry: &Listed,
    categories: &[Category],
    words: &Words,
    big: bool,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let picture = match entry.cover.as_deref().filter(|id| uploaded(id)) {
        Some(id) => format!("<img src=\"/{site}/m/{id}\" alt=\"\" loading=\"lazy\">"),
        None => "<span class=\"photo\"></span>".into(),
    };
    let mut meta = Vec::new();
    if let Some(total) = entry.total {
        meta.push(duration(total));
    }
    if let Some(n) = entry.servings {
        meta.push(words.servings(n));
    }
    let dots = dots(entry.difficulty, words);
    if !dots.is_empty() {
        meta.push(dots);
    }
    format!(
        "<a class=\"card {class}{big}\" href=\"/{site}/{slug}\">{picture}<span class=\"txt\"><h3>{title}</h3>\
         <span class=\"meta\">{meta}</span></span></a>",
        class = class_of(categories, &entry.category_slug()),
        big = if big { " big" } else { "" },
        slug = entry.slug,
        title = escape(&entry.title),
        meta = meta.join(" · "),
    )
}

/// The first recipe large, the next three beside it, each smaller by φ.
fn mosaic(
    site: &str,
    entries: &[&Listed],
    categories: &[Category],
    words: &Words,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let Some((first, rest)) = entries.split_first() else { return String::new() };
    let card = |e: &Listed, big| card(site, e, categories, words, big, uploaded);
    let side = match rest {
        [] => String::new(),
        [one] => format!("<div class=\"side\">{}</div>", card(one, false)),
        [one, more @ ..] => format!(
            "<div class=\"side\">{}<div class=\"row\">{}</div></div>",
            card(one, false),
            more.iter().take(2).map(|e| card(e, false)).collect::<String>()
        ),
    };
    format!("<div class=\"mosaic\">{}{side}</div>", card(first, true))
}

fn grid(
    site: &str,
    entries: &[&Listed],
    categories: &[Category],
    words: &Words,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let cards: String = entries.iter().map(|e| card(site, e, categories, words, false, uploaded)).collect();
    format!("<div class=\"grid\">{cards}</div>")
}

fn crumbs(site: &str, settings: &SiteSettings, words: &Words, trail: &[(String, String)]) -> String {
    let mut out = format!("<header class=\"site\"><a href=\"/{site}/\">{}</a>", escape(&settings.title));
    out.push_str(&format!(" <span>›</span> <a href=\"/{site}/{PATH}\">{}</a>", words.recipes()));
    for (href, name) in trail {
        out.push_str(&format!(" <span>›</span> <a href=\"{href}\">{}</a>", escape(name)));
    }
    out.push_str("</header>\n");
    out
}

fn search_form(site: &str, query: &Query, categories: &[Category], entries: &[Listed], words: &Words) -> String {
    let selected = |yes: bool| if yes { " selected" } else { "" };
    let mut options = format!("<option value=\"\">{}</option>", words.pick("Tutte le categorie", "All categories"));
    for c in categories.iter().filter(|c| entries.iter().any(|e| e.category_slug() == c.slug)) {
        options.push_str(&format!(
            "<option value=\"{}\"{}>{}</option>",
            c.slug,
            selected(c.slug == query.category),
            escape(words.category_name(&c.name))
        ));
    }
    let mut times = format!("<option value=\"\">{}</option>", words.pick("Qualsiasi tempo", "Any time"));
    for minutes in [30, 60, 120] {
        times.push_str(&format!(
            "<option value=\"{minutes}\"{}>{}</option>",
            selected(query.minutes == Some(minutes)),
            words.within(minutes)
        ));
    }
    let mut methods: Vec<&str> = entries.iter().flat_map(|e| e.methods.iter().map(String::as_str)).collect();
    methods.sort_unstable();
    methods.dedup();
    let mut ways = format!("<option value=\"\">{}</option>", words.pick("Ogni modalità", "Any method"));
    for method in methods {
        ways.push_str(&format!(
            "<option value=\"{m}\"{}>{m}</option>",
            selected(method == query.method),
            m = escape(method)
        ));
    }
    format!(
        "<form class=\"search\" method=\"get\" action=\"/{site}/{PATH}\" role=\"search\">\
         <input name=\"q\" type=\"search\" maxlength=\"{MAX_QUERY}\" value=\"{q}\" placeholder=\"{hint}\" aria-label=\"{hint}\">\
         <select name=\"c\" aria-label=\"{cl}\">{options}</select>\
         <select name=\"t\" aria-label=\"{tl}\">{times}</select>\
         <select name=\"m\" aria-label=\"{ml}\">{ways}</select>\
         <button type=\"submit\">{go}</button></form>\n",
        q = escape(&query.text),
        hint = words.pick("Cerca per nome, ingrediente o tag", "Search by name, ingredient or tag"),
        cl = words.pick("Categoria", "Category"),
        tl = words.pick("Tempo totale", "Total time"),
        ml = words.pick("Modalità", "Method"),
        go = words.pick("Cerca", "Search"),
    )
}

/// The showcase: a band per category, in the order they came, newest
/// recipes first; or, with a search, what matches it (never indexed).
#[allow(clippy::too_many_arguments)]
pub fn showcase(
    site: &str,
    settings: &SiteSettings,
    categories: &[Category],
    entries: &[Listed],
    query: &Query,
    style: &str,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let words = Words::of(&settings.lang);
    let searching = query.searching();
    let title = if searching {
        format!("{} · {}", words.pick("Ricerca", "Search"), words.recipes())
    } else {
        format!("{} · {}", words.recipes(), settings.title)
    };
    let description = format!("{} · {}", words.recipes(), settings.title);
    let meta = Meta { path: format!("/{site}/{PATH}"), description: &description, image: None, article: false };
    let mut out = head(settings, site, &title, settings.indexable && !searching, style, &meta);
    out.push_str("<body class=\"cookbook\">\n");
    out.push_str(&crumbs(site, settings, &words, &[]));
    out.push_str("<main>\n");
    if searching {
        let heading = if query.text.is_empty() {
            words.pick("Ricerca", "Search").to_owned()
        } else {
            format!("{} «{}»", words.pick("Risultati per", "Results for"), escape(&query.text))
        };
        out.push_str(&format!("<section class=\"hero\"><h1>{heading}</h1></section>\n"));
        out.push_str(&search_form(site, query, categories, entries, &words));
        let found: Vec<&Listed> = entries.iter().filter(|e| query.matches(e)).collect();
        if found.is_empty() {
            out.push_str(&format!(
                "<p class=\"empty\">{}</p>\n",
                words.pick(
                    "Nessuna ricetta trovata. Prova con meno parole, o togli un filtro.",
                    "No recipe found. Try fewer words, or remove a filter."
                )
            ));
        } else {
            out.push_str(&format!("<p class=\"count\">{}</p>\n", words.count(found.len())));
            out.push_str(&grid(site, &found, categories, &words, uploaded));
        }
    } else {
        out.push_str(&format!("<section class=\"hero\"><h1>{}</h1></section>\n", words.recipes()));
        out.push_str(&search_form(site, query, categories, entries, &words));
        for category in categories {
            let list: Vec<&Listed> = entries.iter().filter(|e| e.category_slug() == category.slug).collect();
            if list.is_empty() {
                continue;
            }
            out.push_str(&format!(
                "<section class=\"band c{order}\"><div class=\"band-head\"><h2>{name}</h2>\
                 <a href=\"/{site}/{PATH}/{slug}\">{all} →</a></div>{mosaic}</section>\n",
                order = category.order,
                name = escape(words.category_name(&category.name)),
                slug = category.slug,
                all = words.count(list.len()),
                mosaic = mosaic(site, &list[..list.len().min(4)], categories, &words, uploaded),
            ));
        }
    }
    out.push_str("</main>\n");
    out.push_str(footer());
    out
}

/// One category's page, in its colours; None when it has no recipe.
pub fn category_page(
    site: &str,
    settings: &SiteSettings,
    categories: &[Category],
    entries: &[Listed],
    slug: &str,
    style: &str,
    uploaded: &dyn Fn(&str) -> bool,
) -> Option<String> {
    let category = categories.iter().find(|c| c.slug == slug)?;
    let list: Vec<&Listed> = entries.iter().filter(|e| e.category_slug() == slug).collect();
    if list.is_empty() {
        return None;
    }
    let words = Words::of(&settings.lang);
    let name = words.category_name(&category.name);
    let description = format!("{name} · {} · {}", words.recipes(), settings.title);
    let meta = Meta { path: format!("/{site}/{PATH}/{slug}"), description: &description, image: None, article: false };
    let mut out = head(settings, site, &format!("{name} · {}", words.recipes()), settings.indexable, style, &meta);
    out.push_str(&format!("<body class=\"cookbook c{}\">\n", category.order));
    out.push_str(&crumbs(site, settings, &words, &[]));
    out.push_str(&format!(
        "<main>\n<section class=\"band\"><div class=\"band-head\"><h1>{}</h1><span class=\"count\">{}</span></div>{}</section>\n\
         <a class=\"back\" href=\"/{site}/{PATH}\">← {}</a>\n</main>\n",
        escape(name),
        words.count(list.len()),
        grid(site, &list, categories, &words, uploaded),
        words.pick("Tutte le categorie", "All categories"),
    ));
    out.push_str(footer());
    Some(out)
}

/// The host of a shop's address, as the page shows it: «su esempio.it».
fn host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    rest.split(['/', '?', '#']).next().unwrap_or(rest)
}

/// What search engines read of a recipe (schema.org/Recipe), as JSON in a
/// data block: never run, and with `<`, `>` and `&` written as escapes so
/// nothing in it can close the element.
fn structured(
    site: &str,
    slug: &str,
    page: &Page,
    recipe: &Recipe,
    lang: &str,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let mut data = serde_json::json!({
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": page.title,
        "url": format!("{ORIGIN}/{site}/{slug}"),
        "inLanguage": lang,
    });
    let object = data.as_object_mut().expect("an object");
    let mut put = |key: &str, value: serde_json::Value| {
        object.insert(key.to_owned(), value);
    };
    if !recipe.description.is_empty() {
        put("description", render::plain(render::head_of(&recipe.description)).into());
    }
    let images: Vec<String> =
        recipe.cover.iter().filter(|p| uploaded(&p.media)).map(|p| format!("{ORIGIN}/{site}/m/{}", p.media)).collect();
    if !images.is_empty() {
        put("image", images.into());
    }
    if !recipe.category.is_empty() {
        put("recipeCategory", recipe.category.clone().into());
    }
    if !recipe.tags.is_empty() {
        put("keywords", recipe.tags.join(", ").into());
    }
    if let Some(n) = recipe.servings {
        put("recipeYield", n.to_string().into());
    }
    for (key, minutes) in [("prepTime", recipe.prep), ("cookTime", recipe.cook), ("totalTime", recipe.total())] {
        if let Some(m) = minutes {
            put(key, iso_duration(m).into());
        }
    }
    if !recipe.methods.is_empty() {
        put("cookingMethod", recipe.methods.join(", ").into());
    }
    put("recipeIngredient", recipe.ingredients.iter().map(|i| i.line(lang)).collect::<Vec<_>>().into());
    let steps: Vec<serde_json::Value> = recipe
        .steps
        .iter()
        .map(|s| render::plain(&s.text))
        .filter(|t| !t.is_empty())
        .map(|text| serde_json::json!({ "@type": "HowToStep", "text": text }))
        .collect();
    put("recipeInstructions", steps.into());
    let json = data.to_string().replace('<', "\\u003c").replace('>', "\\u003e").replace('&', "\\u0026");
    format!("<script type=\"application/ld+json\">{json}</script>\n")
}

/// A recipe's page: cover, times, ingredients beside the steps (38.2 to
/// 61.8), the note's other fields, and more of its category. With
/// `servings` from the address the amounts are scaled; such a page is
/// never indexed, its canonical address is the plain one.
#[allow(clippy::too_many_arguments)]
pub fn recipe_page(
    site: &str,
    slug: &str,
    settings: &SiteSettings,
    page: &Page,
    recipe: &Recipe,
    categories: &[Category],
    others: &[Listed],
    servings: Option<u16>,
    style: &str,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let words = Words::of(&settings.lang);
    let lang = settings.lang.as_str();
    let base = recipe.servings;
    let chosen = base.map(|b| servings.unwrap_or(b));
    let rescaled = servings.is_some_and(|s| Some(s) != base);
    let indexable = settings.indexable && page.listed && servings.is_none();
    let description = cut(&render::plain(render::head_of(&recipe.description)));
    let cover = recipe.cover.iter().find(|p| uploaded(&p.media));
    let meta = Meta {
        path: format!("/{site}/{slug}"),
        description: &description,
        image: cover.map(|p| p.media.clone()),
        article: true,
    };
    let title = if page.title.is_empty() { settings.title.as_str() } else { page.title.as_str() };
    let mut out = head(settings, site, title, indexable && !rescaled, style, &meta);
    let category_slug = category_slug(&recipe.category);
    let class = class_of(categories, &category_slug);
    let category_name = words.category_name(&recipe.category).to_owned();
    out.push_str(&format!("<body class=\"recipe {class}\">\n"));
    out.push_str(&crumbs(
        site,
        settings,
        &words,
        &[(format!("/{site}/{PATH}/{category_slug}"), category_name.clone())],
    ));
    out.push_str("<main>\n<article>\n");

    // The opening: a golden rectangle, the photo and the name on the spiral's point.
    let photo = match cover {
        Some(p) => format!("<img src=\"/{site}/m/{}\" alt=\"{}\">", p.media, escape(&p.caption)),
        None => "<span class=\"photo\"></span>".into(),
    };
    let lead = if description.is_empty() { String::new() } else { format!("<p>{}</p>", escape(&description)) };
    out.push_str(&format!(
        "<div class=\"opening\">{photo}<div class=\"words\"><span class=\"kicker\">{}</span><div><h1>{}</h1>{lead}</div></div></div>\n",
        escape(&category_name),
        escape(&page.title),
    ));
    let gallery: String = recipe
        .cover
        .iter()
        .skip(1)
        .filter(|p| uploaded(&p.media))
        .map(|p| format!("<img src=\"/{site}/m/{}\" alt=\"{}\" loading=\"lazy\">", p.media, escape(&p.caption)))
        .collect();
    if !gallery.is_empty() {
        out.push_str(&format!("<div class=\"gallery\">{gallery}</div>\n"));
    }

    // The times.
    let mut times = String::new();
    for (label, minutes) in [
        (words.pick("Preparazione", "Preparation"), recipe.prep),
        (words.pick("Cottura", "Cooking"), recipe.cook),
        (words.pick("Totale", "Total"), recipe.total()),
    ] {
        if let Some(m) = minutes {
            times.push_str(&format!(
                "<div><span class=\"k\">{label}</span><span class=\"v\">{}</span></div>",
                duration(m)
            ));
        }
    }
    let mut extra = Vec::new();
    if !recipe.methods.is_empty() {
        extra.push(recipe.methods.iter().map(|m| escape(m)).collect::<Vec<_>>().join(", "));
    }
    let dots = dots(recipe.difficulty, &words);
    if !dots.is_empty() {
        extra.push(dots);
    }
    if let Some(rest) = recipe.rest.filter(|r| *r > 0) {
        extra.push(format!("{} {}", words.pick("Riposo", "Rest"), duration(rest)));
    }
    if !extra.is_empty() {
        times.push_str(&format!(
            "<div class=\"extra\"><span class=\"k\">{}</span><span class=\"x\">{}</span></div>",
            words.pick("Modalità e difficoltà", "Method and difficulty"),
            extra.join(" · ")
        ));
    }
    if !times.is_empty() {
        out.push_str(&format!("<div class=\"times\">{times}</div>\n"));
    }

    // Ingredients beside the steps.
    out.push_str("<div class=\"cook\">\n");
    if !recipe.ingredients.is_empty() {
        out.push_str(&format!("<aside class=\"ingredients\"><h2>{}</h2>", words.pick("Ingredienti", "Ingredients")));
        if let (Some(base), Some(now)) = (base, chosen) {
            let step = |to: u16, sign: &str, label: &str| {
                if (1..=recipe::MAX_SERVINGS).contains(&to) {
                    let href = if to == base { format!("/{site}/{slug}") } else { format!("/{site}/{slug}?p={to}") };
                    format!("<a href=\"{href}\" rel=\"nofollow\" aria-label=\"{label}\">{sign}</a>")
                } else {
                    format!("<span class=\"off\" aria-hidden=\"true\">{sign}</span>")
                }
            };
            out.push_str(&format!(
                "<div class=\"servings\">{}<span>{}</span>{}</div>",
                step(now.saturating_sub(1), "−", words.pick("Una porzione in meno", "One serving fewer")),
                words.servings(now),
                step(now + 1, "+", words.pick("Una porzione in più", "One serving more")),
            ));
        }
        out.push_str("<ul>");
        for item in &recipe.ingredients {
            let item = match (base, chosen) {
                (Some(b), Some(n)) => item.scaled(b, n),
                _ => item.clone(),
            };
            let shop = match &item.link {
                Some(url) => format!(
                    "<a class=\"shop\" href=\"{}\" rel=\"nofollow ugc sponsored noopener noreferrer\">{} {}</a>",
                    escape(url),
                    words.pick("su", "at"),
                    escape(host(url))
                ),
                None => String::new(),
            };
            out.push_str(&format!(
                "<li><span class=\"qty\">{}</span><span>{}{shop}</span></li>",
                escape(&item.how_much(lang)),
                escape(item.name.trim())
            ));
        }
        out.push_str("</ul></aside>\n");
    }
    if !recipe.steps.is_empty() {
        out.push_str(&format!("<section class=\"steps\"><h2>{}</h2><ol>", words.pick("Preparazione", "Method")));
        for step in &recipe.steps {
            let pictures: String = step
                .pictures
                .iter()
                .filter(|p| uploaded(&p.media))
                .map(|p| format!("<img src=\"/{site}/m/{}\" alt=\"{}\" loading=\"lazy\">", p.media, escape(&p.caption)))
                .collect();
            let pictures = if pictures.is_empty() { pictures } else { format!("<div class=\"pics\">{pictures}</div>") };
            // No autoplay, nothing loaded before it is asked for but its
            // first frame's size: the page stays light.
            let video = match &step.video {
                Some(id) if uploaded(id) => {
                    format!(
                        "<video class=\"clip\" controls playsinline preload=\"metadata\" src=\"/{site}/m/{id}\"></video>"
                    )
                }
                _ => String::new(),
            };
            out.push_str(&format!("<li><div>{}{pictures}{video}</div></li>", markdown(&step.text, site, uploaded)));
        }
        out.push_str("</ol></section>\n");
    }
    out.push_str("</div>\n");

    // The note's other fields, and its tags.
    let blocks: String = page.blocks.iter().map(|b| block(b, site, uploaded)).collect();
    if !blocks.is_empty() {
        out.push_str(&format!("<div class=\"notes\">{blocks}</div>\n"));
    }
    if !recipe.tags.is_empty() {
        let tags: String = recipe.tags.iter().map(|t| format!("<li>{}</li>", escape(t))).collect();
        out.push_str(&format!("<section class=\"tags\"><ul>{tags}</ul></section>\n"));
    }
    out.push_str("</article>\n");

    // More of the category.
    let more: Vec<&Listed> =
        others.iter().filter(|e| e.slug != slug && e.category_slug() == category_slug).take(MORE).collect();
    if !more.is_empty() {
        out.push_str(&format!(
            "<section class=\"more\"><h2>{} {}</h2>{}</section>\n",
            words.pick("Altre ricette di", "More from"),
            escape(&category_name),
            grid(site, &more, categories, &words, uploaded)
        ));
    }
    out.push_str(&format!(
        "<a class=\"back\" href=\"/{site}/{PATH}\">← {}</a>\n</main>\n",
        words.pick("Tutte le ricette", "All recipes")
    ));
    if indexable {
        out.push_str(&structured(site, slug, page, recipe, lang, uploaded));
    }
    out.push_str(footer());
    out
}

/// The cookbook's part of a site's stylesheet: each category's colours,
/// the showcase's bands and golden mosaic, a recipe's opening, times and
/// columns. Sizes from the same Fibonacci steps as the rest.
pub fn css(settings: &SiteSettings, categories: usize) -> String {
    use render::{PHI, SPACING};
    let [_, xxs, xs, s, m, l, xl, xxl, _] = SPACING;
    let mut out = String::new();
    for order in 0..categories {
        let c = crate::colour::category(&settings.theme, order);
        out.push_str(&format!(".c{order}{{--cat:{};--tint:{}}}\n", c.accent, c.tint));
    }
    out.push_str(&format!(
        ".cookbook main,.recipe main{{max-width:var(--wide)}}\n\
.cookbook h1,.recipe .hero h1{{font-size:var(--h1);letter-spacing:-.02em}}\n\
header.site span{{color:var(--muted);margin:0 {xxs}px}}\n\
.search{{display:grid;grid-template-columns:1fr auto auto auto auto;gap:{xs}px;margin:{m}px 0 {xxl}px;\
background:var(--surface);border-radius:{l}px;padding:{xs}px}}\n\
.search input,.search select,.search button{{font:inherit;font-size:16px;color:var(--text);background:transparent;\
border:0;padding:{xs}px {s}px;min-width:0}}\n\
.search select{{border-left:1px solid var(--bg)}}\n\
.search button{{background:var(--text);color:var(--bg);border-radius:{s}px;font-weight:600;cursor:pointer}}\n\
.count{{color:var(--muted)}}.empty{{padding:{xl}px;background:var(--surface);border-radius:{l}px;color:var(--muted)}}\n\
.band{{margin:0 0 {xxl}px;padding:{xl}px;border-radius:{l}px;background:var(--tint,var(--surface))}}\n\
.band-head{{display:flex;justify-content:space-between;align-items:baseline;gap:{s}px;flex-wrap:wrap;margin-bottom:{l}px}}\n\
.band-head h1,.band-head h2{{color:var(--cat,var(--accent));margin:0}}.band-head h2{{font-size:var(--h2)}}\n\
.band-head a{{color:var(--cat,var(--accent));font-weight:600}}\n\
.mosaic{{display:grid;grid-template-columns:61.8fr 38.2fr;gap:{l}px}}\n\
.mosaic .side{{display:grid;gap:{l}px;align-content:start}}.mosaic .row{{display:grid;grid-template-columns:61.8fr 38.2fr;gap:{s}px}}\n\
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(233px,1fr));gap:{l}px}}\n\
.card{{display:flex;flex-direction:column;text-decoration:none;color:var(--text);background:var(--surface);\
border-radius:{s}px;overflow:hidden}}\n\
.card img,.card .photo{{display:block;width:100%;aspect-ratio:{PHI:.3}/1;object-fit:cover;margin:0;border-radius:0;flex:1 0 auto}}\n\
.photo{{background:linear-gradient(135deg,var(--tint,var(--surface)),var(--cat,var(--accent)))}}\n\
.card .txt{{display:block;padding:{s}px {s}px {m}px}}\n\
.card h3{{font-size:var(--body);margin:0}}.card.big h3{{font-size:var(--h3)}}.card:hover h3{{color:var(--cat,var(--accent))}}\n\
.card .meta{{display:block;font-size:var(--caption);color:var(--muted);margin-top:{xxs}px}}\n\
.dots{{color:var(--cat,var(--accent));letter-spacing:2px}}\n\
.opening{{display:grid;grid-template-columns:61.8fr 38.2fr;min-height:377px;border-radius:{l}px;overflow:hidden;\
background:var(--tint,var(--surface))}}\n\
.opening img,.opening .photo{{display:block;width:100%;height:100%;object-fit:cover;margin:0;border-radius:0}}\n\
.opening .words{{display:grid;grid-template-rows:38.2fr auto;padding:{xl}px {l}px}}\n\
.kicker{{align-self:end;font-size:var(--caption);font-weight:700;letter-spacing:.12em;text-transform:uppercase;\
color:var(--cat,var(--accent))}}\n\
.opening h1{{font-size:var(--h2);margin:{xs}px 0 0}}.opening p{{color:var(--muted);margin:{s}px 0 0}}\n\
.gallery{{display:grid;grid-template-columns:repeat(auto-fill,minmax(144px,1fr));gap:{xs}px;margin:{xs}px 0 0}}\n\
.gallery img{{aspect-ratio:{PHI:.3}/1;object-fit:cover;margin:0}}\n\
.times{{display:grid;grid-template-columns:repeat(auto-fit,minmax(144px,1fr));gap:{xs}px;margin:{l}px 0 {xxl}px}}\n\
.times>div{{background:var(--surface);border-radius:{s}px;padding:{s}px}}.times .extra{{grid-column:span 2}}\n\
.times .k{{display:block;font-size:var(--caption);letter-spacing:.1em;text-transform:uppercase;color:var(--muted);font-weight:600}}\n\
.times .v{{display:block;font-family:\"Modus Heading\",system-ui,sans-serif;font-size:var(--h3);font-weight:700}}\n\
.cook{{display:grid;grid-template-columns:38.2fr 61.8fr;gap:{xxl}px;align-items:start}}\n\
.ingredients{{position:sticky;top:{l}px;background:var(--surface);border-radius:{l}px;padding:{l}px;\
border-top:{xxs}px solid var(--cat,var(--accent))}}\n\
.ingredients h2,.steps h2,.more h2{{font-size:var(--h3);margin:0 0 {s}px}}\n\
.servings{{display:flex;align-items:center;gap:{xs}px;margin-bottom:{s}px;font-weight:600}}\n\
.servings a,.servings .off{{display:inline-grid;place-items:center;width:34px;height:34px;border-radius:50%;\
background:var(--tint,var(--bg));color:var(--cat,var(--accent));text-decoration:none;font-size:21px;font-weight:700}}\n\
.servings .off{{opacity:.38}}\n\
.ingredients ul{{list-style:none;padding:0;margin:0}}\n\
.ingredients li{{display:grid;grid-template-columns:auto 1fr;gap:{xs}px;padding:{xs}px 0;border-bottom:1px solid var(--bg)}}\n\
.qty{{font-weight:600;color:var(--cat,var(--accent));min-width:4.5em}}\n\
.shop{{display:block;font-size:var(--caption);color:var(--muted)}}\n\
.steps ol{{list-style:none;padding:0;margin:0;counter-reset:step}}\n\
.steps li{{counter-increment:step;display:grid;grid-template-columns:{xxl}px 1fr;gap:{s}px;padding:0 0 {xl}px}}\n\
.steps li::before{{content:counter(step);font:800 var(--h3)/1 \"Modus Heading\",system-ui,sans-serif;color:var(--cat,var(--accent))}}\n\
.steps li p:last-child{{margin-bottom:0}}\n\
.pics{{display:grid;grid-template-columns:61.8fr 38.2fr;gap:{xs}px;margin-top:{s}px}}\
.pics img{{aspect-ratio:{PHI:.3}/1;object-fit:cover;margin:0}}\n\
.clip{{display:block;width:100%;max-height:610px;margin-top:{s}px;border-radius:{xs}px;background:var(--surface)}}\n\
.notes{{margin-top:{xl}px}}\n\
.more{{margin-top:{xxl}px;padding-top:{xl}px;border-top:1px solid var(--surface)}}\n\
.back{{display:inline-block;margin-top:{l}px;font-weight:600;color:var(--cat,var(--accent))}}\n\
@media (max-width:760px){{.search{{grid-template-columns:1fr 1fr}}.search input{{grid-column:1/-1}}\
.mosaic,.mosaic .row,.cook,.opening{{grid-template-columns:1fr}}.opening img,.opening .photo{{aspect-ratio:{PHI:.3}/1;height:auto}}\
.opening .words{{display:block;padding:{l}px}}.ingredients{{position:static}}.band{{padding:{l}px}}.times .extra{{grid-column:1/-1}}}}\n"
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::{Block, Layout};
    use crate::settings;

    const SITE: &str = "quaderno";

    fn recipe_page_of(r: Recipe) -> Page {
        Page { title: "Parmigiana".into(), layout: Layout::Recipe, listed: true, blocks: vec![], recipe: Some(r) }
    }

    fn listed(slug: &str, title: &str, category: &str, minutes: u32, ms: u64) -> Listed {
        let mut r = recipe::sample();
        r.category = category.into();
        r.prep = Some(minutes);
        r.cook = None;
        r.rest = None;
        let page = Page { title: title.into(), ..recipe_page_of(r.clone()) };
        Listed::of(slug, &page, &r, ms)
    }

    fn categories() -> Vec<Category> {
        vec![
            Category { slug: "primi".into(), name: "Primi".into(), order: 0 },
            Category { slug: "verdure".into(), name: "Verdure".into(), order: 1 },
            Category { slug: "dolci".into(), name: "Dolci".into(), order: 2 },
        ]
    }

    fn entries() -> Vec<Listed> {
        vec![
            listed("carbonara", "Spaghetti alla carbonara", "Primi", 25, 5),
            listed("parmigiana", "Parmigiana di melanzane", "Verdure", 100, 4),
            listed("risotto", "Risotto alla zucca", "Primi", 50, 3),
            listed("tiramisu", "Tiramisù", "Dolci", 30, 2),
            listed("cianfotta", "Cianfotta", "Verdure", 60, 1),
        ]
    }

    #[test]
    fn queries_are_read_leniently() {
        let q = Query::parse(Some("q=Crème+br%C3%BBl%C3%A9e&c=dolci&t=60&m=Forno&p=8&x=1"));
        assert_eq!(q.text, "Crème brûlée");
        assert_eq!(q.category, "dolci");
        assert_eq!(q.minutes, Some(60));
        assert_eq!(q.method, "Forno");
        assert_eq!(q.servings, Some(8));
        let bad = Query::parse(Some("q=%ZZ%&c=../x&t=-1&p=0&p=101&q2=%0A"));
        assert_eq!(bad.text, "%ZZ%");
        assert_eq!((bad.category.as_str(), bad.minutes, bad.servings), ("", None, None));
        assert_eq!(Query::parse(Some(&format!("q={}", "a".repeat(500)))).text.chars().count(), MAX_QUERY);
        assert_eq!(Query::parse(Some("q=a%0Ab%00c")).text, "abc");
        assert!(!Query::parse(None).searching());
        assert!(!Query::parse(Some("p=4")).searching());
    }

    #[test]
    fn search_words_are_bounded() {
        let mut r = recipe::sample();
        r.ingredients = vec![r.ingredients[0].clone(); 233];
        for (i, item) in r.ingredients.iter_mut().enumerate() {
            item.name = format!("{i} {}", "à".repeat(190));
        }
        let page = recipe_page_of(r.clone());
        let entry = Listed::of("x", &page, &r, 1);
        assert!(entry.words.len() <= MAX_WORDS);
        assert!(entry.words.starts_with("parmigiana"), "{}", &entry.words[..40]);
        assert!(!entry.words.contains('à'));
    }

    #[test]
    fn search_finds_without_accents_and_filters() {
        let all = entries();
        let find = |raw: &str| {
            let q = Query::parse(Some(raw));
            all.iter().filter(|e| q.matches(e)).map(|e| e.slug.as_str()).collect::<Vec<_>>()
        };
        assert_eq!(find("q=TIRAMISU"), ["tiramisu"]);
        assert_eq!(
            find("q=melanzane"),
            ["carbonara", "parmigiana", "risotto", "tiramisu", "cianfotta"],
            "an ingredient"
        );
        assert_eq!(find("q=risotto+zucca"), ["risotto"]);
        assert_eq!(find("q=risotto+pesce"), Vec::<&str>::new());
        assert_eq!(find("c=primi"), ["carbonara", "risotto"]);
        assert_eq!(find("t=30"), ["carbonara", "tiramisu"]);
        assert_eq!(find("m=Forno&c=dolci"), ["tiramisu"]);
        assert_eq!(find("m=Vapore"), Vec::<&str>::new());
    }

    #[test]
    fn the_showcase_has_a_band_per_category_and_no_script() {
        let html = showcase(SITE, &settings::sample(), &categories(), &entries(), &Query::default(), "1", &|_| true);
        assert!(!html.contains("<script"));
        assert_eq!(html.matches("<section class=\"band").count(), 3);
        let primi = html.find("class=\"band c0\"").unwrap();
        let verdure = html.find("class=\"band c1\"").unwrap();
        assert!(primi < verdure, "in the order the categories came");
        assert!(html.contains("<a href=\"/quaderno/ricette/primi\">2 ricette →</a>"));
        assert!(html.contains("<div class=\"mosaic\"><a class=\"card c0 big\" href=\"/quaderno/carbonara\">"));
        assert!(html.contains("<form class=\"search\" method=\"get\" action=\"/quaderno/ricette\""));
        assert!(html.contains("<option value=\"dolci\">Dolci</option>"));
        assert!(html.contains("src=\"/quaderno/m/CCCCCCCCCCCCCCCC\""));
    }

    #[test]
    fn a_search_is_never_indexed_and_echoes_escaped() {
        let mut s = settings::sample();
        s.indexable = true;
        let plain = showcase(SITE, &s, &categories(), &entries(), &Query::default(), "1", &|_| true);
        assert!(!plain.contains("noindex"));
        let q = Query::parse(Some("q=%3Cscript%3E%22"));
        let html = showcase(SITE, &s, &categories(), &entries(), &q, "1", &|_| true);
        assert!(html.contains("noindex"));
        assert!(!html.contains("<script>"));
        assert!(html.contains("value=\"&lt;script&gt;&quot;\""));
        assert!(html.contains("Nessuna ricetta trovata"));
        let found = showcase(SITE, &s, &categories(), &entries(), &Query::parse(Some("q=zucca")), "1", &|_| true);
        assert!(found.contains("1 ricetta") && found.contains("/quaderno/risotto"));
        assert!(found.contains("value=\"zucca\""));
    }

    #[test]
    fn a_category_page_in_its_colours() {
        let html =
            category_page(SITE, &settings::sample(), &categories(), &entries(), "primi", "1", &|_| false).unwrap();
        assert!(html.contains("<body class=\"cookbook c0\">"));
        assert!(html.contains("<h1>Primi</h1>"));
        assert!(html.contains("<span class=\"photo\"></span>"), "a cover not uploaded is not shown");
        assert_eq!(category_page(SITE, &settings::sample(), &categories(), &[], "primi", "1", &|_| true), None);
        assert_eq!(category_page(SITE, &settings::sample(), &categories(), &entries(), "x", "1", &|_| true), None);
    }

    #[test]
    fn a_steps_video_plays_only_when_asked_and_only_if_uploaded() {
        let mut r = recipe::sample();
        r.steps[1].video = Some("VVVVVVVVVVVVVVVV".into());
        let page = recipe_page_of(r.clone());
        let html = recipe_page(SITE, "p", &settings::sample(), &page, &r, &categories(), &[], None, "1", &|_| true);
        assert!(html.contains(
            "<video class=\"clip\" controls playsinline preload=\"metadata\" src=\"/quaderno/m/VVVVVVVVVVVVVVVV\"></video>"
        ));
        assert!(!html.contains("autoplay"));
        let missing = recipe_page(SITE, "p", &settings::sample(), &page, &r, &categories(), &[], None, "1", &|id| {
            id != "VVVVVVVVVVVVVVVV"
        });
        assert!(!missing.contains("<video"));
    }

    #[test]
    fn a_recipe_page_scales_links_to_shops_and_lists_its_category() {
        let page = recipe_page_of(recipe::sample());
        let r = page.recipe.clone().unwrap();
        let cats = categories();
        let html =
            recipe_page(SITE, "parmigiana", &settings::sample(), &page, &r, &cats, &entries(), None, "1", &|_| true);
        assert!(html.contains("<body class=\"recipe c1\">"));
        assert!(html.contains("<h1>Parmigiana</h1>"));
        assert_eq!(html.matches("<h1>").count(), 1);
        assert!(html.contains("<span class=\"v\">1 h 40 min</span>"));
        assert!(html.contains("<span>6 porzioni</span>"));
        assert!(html.contains("href=\"/quaderno/parmigiana?p=7\""));
        assert!(html.contains("href=\"/quaderno/parmigiana?p=5\""));
        assert!(html.contains("<span class=\"qty\">1,5 kg</span><span>Melanzane</span>"));
        assert!(html.contains(
            "<a class=\"shop\" href=\"https://esempio.it/passata\" rel=\"nofollow ugc sponsored noopener noreferrer\">su esempio.it</a>"
        ));
        assert!(html.contains("<strong>30 minuti</strong>"));
        assert!(html.contains("alt=\"Fette\""));
        assert!(!html.contains("<script"), "not indexable: no structured data");
        // The other recipe of the category, not this one.
        let more = html.split("<section class=\"more\">").nth(1).unwrap();
        assert!(more.contains("/quaderno/cianfotta\""));
        assert!(!more.contains("/quaderno/parmigiana\"") && !more.contains("carbonara"));

        let seven =
            recipe_page(SITE, "parmigiana", &settings::sample(), &page, &r, &cats, &[], Some(7), "1", &|_| true);
        assert!(seven.contains("<span class=\"qty\">1,8 kg</span>"));
        assert!(seven.contains("<span class=\"qty\">815 ml</span>"));
        assert!(seven.contains("href=\"/quaderno/parmigiana\" rel=\"nofollow\" aria-label=\"Una porzione in meno\""));
        assert!(seven.contains("noindex"));
        let hundred =
            recipe_page(SITE, "parmigiana", &settings::sample(), &page, &r, &cats, &[], Some(100), "1", &|_| true);
        assert!(hundred.contains("<span class=\"off\" aria-hidden=\"true\">+</span>"));
    }

    #[test]
    fn structured_data_only_when_indexable_and_never_breaks_out() {
        let mut s = settings::sample();
        s.indexable = true;
        let mut r = recipe::sample();
        r.description = "</script><script>alert(1)</script> & <b>".into();
        r.ingredients[0].name = "</script>".into();
        let page = recipe_page_of(r.clone());
        let html = recipe_page(SITE, "parmigiana", &s, &page, &r, &categories(), &[], None, "1", &|_| true);
        let start = html.find("<script type=\"application/ld+json\">").expect("structured data");
        let json = &html[start + 35..];
        let json = &json[..json.find("</script>").unwrap()];
        assert!(!json.contains('<') && !json.contains('>'), "{json}");
        let data: serde_json::Value = serde_json::from_str(json).unwrap();
        assert_eq!(data["@type"], "Recipe");
        assert_eq!(data["totalTime"], "PT1H40M");
        assert_eq!(data["recipeYield"], "6");
        assert_eq!(data["image"][0], "https://serv.pub/quaderno/m/CCCCCCCCCCCCCCCC");
        assert_eq!(data["recipeIngredient"][0], "1,5 kg </script>");
        assert_eq!(html.matches("<script").count(), 1);
        let scaled = recipe_page(SITE, "parmigiana", &s, &page, &r, &categories(), &[], Some(3), "1", &|_| true);
        assert!(!scaled.contains("<script"));
    }

    #[test]
    fn other_fields_follow_the_recipe() {
        let mut page = recipe_page_of(recipe::sample());
        page.blocks = vec![Block::Markdown { label: "Note".into(), text: "Meglio il giorno dopo.".into() }];
        let r = page.recipe.clone().unwrap();
        let html = recipe_page(SITE, "p", &settings::sample(), &page, &r, &categories(), &[], None, "1", &|_| true);
        assert!(html.contains("<div class=\"notes\">"));
        assert!(html.contains("Meglio il giorno dopo."));
    }

    #[test]
    fn english_sites_read_in_english() {
        let mut s = settings::sample();
        s.lang = "en".into();
        let page = recipe_page_of(recipe::sample());
        let r = page.recipe.clone().unwrap();
        let html = recipe_page(SITE, "p", &s, &page, &r, &categories(), &[], None, "1", &|_| true);
        assert!(html.contains("<h2>Ingredients</h2>") && html.contains("6 servings") && html.contains("1.5 kg"));
    }

    #[test]
    fn the_stylesheet_colours_every_category() {
        let css = css(&settings::sample(), 3);
        assert!(css.contains(".c0{--cat:#") && css.contains(".c2{--cat:#") && !css.contains(".c3{"));
        assert!(css.contains("grid-template-columns:38.2fr 61.8fr"));
        assert!(css.contains("grid-template-columns:61.8fr 38.2fr"));
    }
}
