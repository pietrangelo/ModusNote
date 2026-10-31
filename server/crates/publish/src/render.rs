//! Pages to HTML and a site's colours to CSS, on the server, so a page is
//! the same for every reader and holds nothing it was not checked for.
//!
//! The pages carry no script and allow none (`default-src 'none'`). Markdown
//! goes through `pulldown-cmark` as events and only known elements come out:
//! raw HTML in a note is shown as text, a link is made only to the web
//! (`https:`, `http:`), to an address (`mailto:`) or to another page of the
//! site (`page:<slug>`), and a picture only from a file the site uploaded
//! (`image:<media>`). Everything else is escaped text.

use pulldown_cmark::{Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::names::{media_id, page_slug};
use crate::page::{Block, Layout, Page, web_url};
use crate::settings::{Font, HomeLayout, SiteSettings};
use crate::text::escape;

/// φ, and the scales the stylesheet takes from it.
pub const PHI: f64 = 1.618_033_988_749_895;
pub const SPACING: [u32; 9] = [3, 5, 8, 13, 21, 34, 55, 89, 144];
pub const MEASURE: u32 = 610;
pub const WIDE: u32 = 987;

/// Where serv.pub is, for the addresses link previews and feeds need whole.
pub const ORIGIN: &str = "https://serv.pub";

/// The characters serv.pub's fonts hold (Latin, punctuation, arrows, maths
/// and the checklist's boxes): any other falls back to the reader's fonts.
/// Must match `server/pages/fonts/make_web_fonts.py`.
pub const UNICODE_RANGE: &str = "U+0000-024F,U+0259,U+02B0-02FF,U+0300-036F,U+1E00-1EFF,U+2000-206F,U+20A0-20CF,\
U+2100-218F,U+2190-21FF,U+2200-22FF,U+2600-26FF";

/// The fonts serv.pub serves, at `/fonts/<name>.woff2`.
pub const FONT_FILES: [&str; 8] =
    ["jakarta", "inter", "literata", "literata-italic", "atkinson", "atkinson-italic", "quattro", "quattro-italic"];

/// The longest description a page gives link previews and feeds, in
/// characters.
pub const EXCERPT: usize = 233;

/// The newest listed pages a site's feed carries.
pub const FEED_ENTRIES: usize = 21;

/// The policy every page and stylesheet goes out with.
pub const CSP: &str = "default-src 'none'; style-src 'self'; img-src 'self'; media-src 'self'; font-src 'self'; \
                       base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

fn options() -> Options {
    Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS
}

/// The media ids of the pictures `markdown` shows, in order.
pub fn images_in(markdown: &str) -> Vec<String> {
    Parser::new_ext(markdown, options())
        .filter_map(|event| match event {
            Event::Start(Tag::Image { dest_url, .. }) => {
                dest_url.strip_prefix("image:").filter(|id| media_id(id)).map(str::to_owned)
            }
            _ => None,
        })
        .collect()
}

/// Where a Markdown link may go from a page of `site`, or None to show
/// only its text.
fn href(dest: &str, site: &str) -> Option<String> {
    if web_url(dest) {
        return Some(dest.to_owned());
    }
    if let Some(slug) = dest.strip_prefix("page:") {
        return page_slug(slug).then(|| format!("/{site}/{slug}"));
    }
    if let Some(address) = dest.strip_prefix("mailto:") {
        let plain = address.len() <= 254
            && address.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_+@".contains(&b))
            && address.matches('@').count() == 1
            && !address.starts_with('@')
            && !address.ends_with('@');
        return plain.then(|| dest.to_owned());
    }
    None
}

/// `markdown` as HTML for a page of `site`. `uploaded` says which media the
/// site holds. The page's title is its only `h1`: headings move down one.
pub fn markdown(markdown: &str, site: &str, uploaded: &dyn Fn(&str) -> bool) -> String {
    let mut out = String::new();
    // A picture's alt text arrives as events inside it; collect it there.
    let mut image: Option<(Option<String>, String)> = None;
    // Whether each open link became an element.
    let mut links: Vec<bool> = Vec::new();
    let mut in_head = false;
    for event in Parser::new_ext(markdown, options()) {
        if let Some((_, alt)) = image.as_mut() {
            match event {
                Event::End(TagEnd::Image) => {
                    let (src, alt) = image.take().unwrap_or_default();
                    match src {
                        Some(src) => {
                            out.push_str(&format!(r#"<img src="{src}" alt="{}" loading="lazy">"#, escape(&alt)))
                        }
                        None => out.push_str(&escape(&alt)),
                    }
                }
                Event::Text(text) | Event::Code(text) => alt.push_str(&text),
                _ => {}
            }
            continue;
        }
        match event {
            Event::Start(tag) => match tag {
                Tag::Paragraph => out.push_str("<p>"),
                Tag::Heading { level, .. } => out.push_str(&format!("<h{}>", heading(level))),
                Tag::BlockQuote(_) => out.push_str("<blockquote>"),
                Tag::CodeBlock(_) => out.push_str("<pre><code>"),
                Tag::List(Some(start)) => out.push_str(&format!(r#"<ol start="{start}">"#)),
                Tag::List(None) => out.push_str("<ul>"),
                Tag::Item => out.push_str("<li>"),
                Tag::Emphasis => out.push_str("<em>"),
                Tag::Strong => out.push_str("<strong>"),
                Tag::Strikethrough => out.push_str("<del>"),
                Tag::Link { dest_url, .. } => match href(&dest_url, site) {
                    Some(target) => {
                        let external = !target.starts_with('/');
                        let rel = if external { r#" rel="nofollow noopener noreferrer ugc""# } else { "" };
                        out.push_str(&format!(r#"<a href="{}"{rel}>"#, escape(&target)));
                        links.push(true);
                    }
                    None => links.push(false),
                },
                Tag::Image { dest_url, .. } => {
                    let src = dest_url
                        .strip_prefix("image:")
                        .filter(|id| media_id(id) && uploaded(id))
                        .map(|id| format!("/{site}/m/{id}"));
                    image = Some((src, String::new()));
                }
                Tag::Table(_) => out.push_str("<table>"),
                Tag::TableHead => {
                    in_head = true;
                    out.push_str("<thead><tr>");
                }
                Tag::TableRow => out.push_str("<tr>"),
                Tag::TableCell => out.push_str(if in_head { "<th>" } else { "<td>" }),
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => out.push_str("</p>"),
                TagEnd::Heading(level) => out.push_str(&format!("</h{}>", heading(level))),
                TagEnd::BlockQuote(_) => out.push_str("</blockquote>"),
                TagEnd::CodeBlock => out.push_str("</code></pre>"),
                TagEnd::List(true) => out.push_str("</ol>"),
                TagEnd::List(false) => out.push_str("</ul>"),
                TagEnd::Item => out.push_str("</li>"),
                TagEnd::Emphasis => out.push_str("</em>"),
                TagEnd::Strong => out.push_str("</strong>"),
                TagEnd::Strikethrough => out.push_str("</del>"),
                TagEnd::Link => {
                    if links.pop() == Some(true) {
                        out.push_str("</a>");
                    }
                }
                TagEnd::Table => out.push_str("</tbody></table>"),
                TagEnd::TableHead => {
                    in_head = false;
                    out.push_str("</tr></thead><tbody>");
                }
                TagEnd::TableRow => out.push_str("</tr>"),
                TagEnd::TableCell => out.push_str(if in_head { "</th>" } else { "</td>" }),
                _ => {}
            },
            Event::Text(text) | Event::Html(text) | Event::InlineHtml(text) | Event::FootnoteReference(text) => {
                out.push_str(&escape(&text));
            }
            Event::Code(text) => out.push_str(&format!("<code>{}</code>", escape(&text))),
            Event::SoftBreak => out.push('\n'),
            Event::HardBreak => out.push_str("<br>"),
            Event::Rule => out.push_str("<hr>"),
            Event::TaskListMarker(done) => out.push_str(if done { "☑ " } else { "☐ " }),
            _ => {}
        }
    }
    out
}

fn heading(level: HeadingLevel) -> u8 {
    (level as u8 + 1).min(6)
}

/// A page listed on a site's home, in a book's contents and in the feed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub slug: String,
    pub title: String,
    pub updated_ms: u64,
    /// The page's [`excerpt`].
    pub summary: String,
}

/// `markdown` as plain text on one line: what it says, without markup.
pub fn plain(markdown: &str) -> String {
    let mut out = String::new();
    let mut in_image = 0usize;
    for event in Parser::new_ext(markdown, options()) {
        match event {
            Event::Start(Tag::Image { .. }) => in_image += 1,
            Event::End(TagEnd::Image) => in_image = in_image.saturating_sub(1),
            Event::Text(text) | Event::Code(text) if in_image == 0 => out.push_str(&text),
            Event::SoftBreak
            | Event::HardBreak
            | Event::End(TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::Item | TagEnd::TableCell) => out.push(' '),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `text` cut to at most [`EXCERPT`] characters, at a space when there is
/// one, with an ellipsis when cut.
fn cut(text: &str) -> String {
    if text.chars().count() <= EXCERPT {
        return text.to_owned();
    }
    let head: String = text.chars().take(EXCERPT - 1).collect();
    let head = match head.rfind(' ') {
        Some(at) if at > head.len() / 2 => &head[..at],
        _ => head.as_str(),
    };
    format!("{}…", head.trim_end_matches(|c: char| c.is_whitespace() || ",;:.".contains(c)))
}

/// What a page says first, for link previews and feeds: its first text.
pub fn excerpt(page: &Page) -> String {
    for block in &page.blocks {
        let text = match block {
            Block::Markdown { text, .. } => plain(text),
            Block::Text { text, .. } => text.split_whitespace().collect::<Vec<_>>().join(" "),
            _ => continue,
        };
        if !text.is_empty() {
            return cut(&text);
        }
    }
    String::new()
}

/// The first picture a page shows, for link previews.
pub fn first_image(page: &Page, uploaded: &dyn Fn(&str) -> bool) -> Option<String> {
    page.blocks.iter().find_map(|block| match block {
        Block::Image { media, .. } => uploaded(media).then(|| media.clone()),
        Block::Markdown { text, .. } => images_in(text).into_iter().find(|id| uploaded(id)),
        _ => None,
    })
}

/// What a page tells link previews about itself.
struct Meta<'a> {
    /// Its path on serv.pub.
    path: String,
    description: &'a str,
    image: Option<String>,
    article: bool,
}

fn head(settings: &SiteSettings, site: &str, title: &str, indexable: bool, style: &str, meta: &Meta<'_>) -> String {
    let robots = if indexable { "" } else { "<meta name=\"robots\" content=\"noindex, nofollow\">\n" };
    let url = escape(&format!("{ORIGIN}{}", meta.path));
    let mut tags = format!(
        "<link rel=\"canonical\" href=\"{url}\">\n<meta property=\"og:url\" content=\"{url}\">\n\
         <meta property=\"og:type\" content=\"{kind}\">\n",
        kind = if meta.article { "article" } else { "website" },
    );
    if !meta.description.is_empty() {
        let description = escape(meta.description);
        tags.push_str(&format!(
            "<meta name=\"description\" content=\"{description}\">\n\
             <meta property=\"og:description\" content=\"{description}\">\n"
        ));
    }
    let card = match &meta.image {
        Some(id) => {
            tags.push_str(&format!("<meta property=\"og:image\" content=\"{ORIGIN}/{site}/m/{id}\">\n"));
            "summary_large_image"
        }
        None => "summary",
    };
    tags.push_str(&format!("<meta name=\"twitter:card\" content=\"{card}\">\n"));
    format!(
        "<!doctype html>\n<html lang=\"{lang}\">\n<head>\n<meta charset=\"utf-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <meta name=\"referrer\" content=\"no-referrer\">\n{robots}<title>{title}</title>\n\
         <meta property=\"og:title\" content=\"{title}\">\n<meta property=\"og:site_name\" content=\"{site_title}\">\n\
         {tags}<link rel=\"alternate\" type=\"application/atom+xml\" href=\"/{site}/feed.xml\" title=\"{site_title}\">\n\
         <link rel=\"stylesheet\" href=\"/{site}/style.css?v={style}\">\n</head>\n",
        lang = escape(&settings.lang),
        title = escape(title),
        site_title = escape(&settings.title),
    )
}

fn masthead(settings: &SiteSettings, site: &str) -> String {
    format!(r#"<header class="site"><a href="/{site}/">{}</a></header>"#, escape(&settings.title))
}

fn footer() -> &'static str {
    "<footer class=\"site\"><p>Modus Notes · serv.pub</p></footer>\n</body>\n</html>\n"
}

fn label(text: &str) -> String {
    if text.is_empty() { String::new() } else { format!("<h2 class=\"label\">{}</h2>", escape(text)) }
}

fn block(block: &Block, site: &str, uploaded: &dyn Fn(&str) -> bool) -> String {
    let media = |id: &str| uploaded(id).then(|| format!("/{site}/m/{id}"));
    match block {
        Block::Markdown { label: l, text } => {
            format!("<section class=\"text\">{}{}</section>", label(l), markdown(text, site, uploaded))
        }
        Block::Text { label: l, text } => {
            format!("<section class=\"field\">{}<p>{}</p></section>", label(l), escape(text))
        }
        Block::Tags { label: l, items } => {
            let tags: String = items.iter().map(|t| format!("<li>{}</li>", escape(t))).collect();
            format!("<section class=\"tags\">{}<ul>{tags}</ul></section>", label(l))
        }
        Block::Checklist { label: l, items } => {
            let checks: String = items
                .iter()
                .map(|c| format!("<li class=\"{}\">{}</li>", if c.done { "done" } else { "open" }, escape(&c.text)))
                .collect();
            format!("<section class=\"checklist\">{}<ul>{checks}</ul></section>", label(l))
        }
        Block::Links { label: l, items } => {
            let links: String = items
                .iter()
                .map(|link| {
                    let title = if link.title.is_empty() { &link.url } else { &link.title };
                    format!(
                        r#"<li><a href="{}" rel="nofollow noopener noreferrer ugc">{}</a></li>"#,
                        escape(&link.url),
                        escape(title)
                    )
                })
                .collect();
            format!("<section class=\"links\">{}<ul>{links}</ul></section>", label(l))
        }
        Block::Image { label: l, media: id, caption } => match media(id) {
            Some(src) => format!(
                "<figure>{}<img src=\"{src}\" alt=\"{c}\" loading=\"lazy\"><figcaption>{c}</figcaption></figure>",
                label(l),
                c = escape(caption)
            ),
            None => String::new(),
        },
        Block::Audio { label: l, media: id } => match media(id) {
            Some(src) => format!(
                "<section class=\"audio\">{}<audio controls preload=\"none\" src=\"{src}\"></audio></section>",
                label(l)
            ),
            None => String::new(),
        },
    }
}

/// A page of `site`. `contents` are the site's listed pages, for the book
/// layout; `style` versions the stylesheet so a new theme shows at once.
pub fn page(
    site: &str,
    slug: &str,
    settings: &SiteSettings,
    page: &Page,
    contents: &[Entry],
    style: &str,
    uploaded: &dyn Fn(&str) -> bool,
) -> String {
    let indexable = settings.indexable && page.listed;
    let description = excerpt(page);
    let meta = Meta {
        path: format!("/{site}/{slug}"),
        description: &description,
        image: first_image(page, uploaded),
        article: true,
    };
    let title_text = if page.title.is_empty() { &settings.title } else { &page.title };
    let mut out = head(settings, site, title_text, indexable, style, &meta);
    let layout = match page.layout {
        Layout::Essay => "essay",
        Layout::GoldenSection => "golden-section",
        Layout::GoldenCover => "golden-cover",
        Layout::Book => "book",
    };
    out.push_str(&format!("<body class=\"{layout}\">\n{}\n", masthead(settings, site)));
    let title = if page.title.is_empty() { String::new() } else { format!("<h1>{}</h1>", escape(&page.title)) };
    let (main, aside): (Vec<&Block>, Vec<&Block>) = match page.layout {
        // The wide column keeps the text, the narrow one everything else.
        Layout::GoldenSection => page.blocks.iter().partition(|b| matches!(b, Block::Markdown { .. })),
        _ => (page.blocks.iter().collect(), Vec::new()),
    };
    let render = |blocks: &[&Block]| blocks.iter().map(|b| block(b, site, uploaded)).collect::<String>();
    match page.layout {
        Layout::GoldenCover => {
            out.push_str(&format!(
                "<div class=\"cover\">{title}</div>\n<main><article>{}</article></main>\n",
                render(&main)
            ));
        }
        Layout::Book => {
            let items: String = contents
                .iter()
                .map(|e| format!(r#"<li><a href="/{site}/{}">{}</a></li>"#, e.slug, escape(&e.title)))
                .collect();
            out.push_str(&format!(
                "<main><nav class=\"contents\"><ol>{items}</ol></nav><article>{title}{}</article></main>\n",
                render(&main)
            ));
        }
        Layout::GoldenSection => {
            out.push_str(&format!(
                "<main><article>{title}{}</article><aside>{}</aside></main>\n",
                render(&main),
                render(&aside)
            ));
        }
        Layout::Essay => out.push_str(&format!("<main><article>{title}{}</article></main>\n", render(&main))),
    }
    out.push_str(footer());
    out
}

/// A site's home: its title, its words about itself and its listed pages,
/// the newest first.
pub fn home(site: &str, settings: &SiteSettings, entries: &[Entry], style: &str) -> String {
    let description = cut(&plain(&settings.about));
    let meta = Meta { path: format!("/{site}/"), description: &description, image: None, article: false };
    let mut out = head(settings, site, &settings.title, settings.indexable, style, &meta);
    let layout = match settings.home {
        HomeLayout::Collection => "collection",
        HomeLayout::Essay => "essay",
    };
    out.push_str(&format!("<body class=\"home {layout}\">\n<main>\n<h1>{}</h1>\n", escape(&settings.title)));
    if !settings.about.is_empty() {
        out.push_str(&format!("<div class=\"about\">{}</div>\n", markdown(&settings.about, site, &|_| false)));
    }
    let items: String = entries
        .iter()
        .map(|e| {
            let title = if e.title.is_empty() { e.slug.as_str() } else { e.title.as_str() };
            format!(r#"<li><a href="/{site}/{}">{}</a></li>"#, e.slug, escape(title))
        })
        .collect();
    out.push_str(&format!("<ul class=\"pages\">{items}</ul>\n</main>\n"));
    out.push_str(footer());
    out
}

/// `ms` since the epoch as an RFC 3339 time in UTC, as Atom wants it.
pub fn rfc3339(ms: u64) -> String {
    let secs = ms / 1000;
    let (days, rest) = ((secs / 86_400) as i64, secs % 86_400);
    // Days to a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rest / 3600, rest / 60 % 60, rest % 60)
}

/// A site's Atom feed: its newest listed pages, with what each says first.
/// Atom, not RSS: one format every reader takes, with real dates and ids.
pub fn feed(site: &str, settings: &SiteSettings, entries: &[Entry]) -> String {
    let home = format!("{ORIGIN}/{site}/");
    let updated = rfc3339(entries.iter().map(|e| e.updated_ms).max().unwrap_or(0));
    let mut out = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\" xml:lang=\"{lang}\">\n\
         <title>{title}</title>\n<id>{home}</id>\n<updated>{updated}</updated>\n\
         <link rel=\"alternate\" type=\"text/html\" href=\"{home}\"/>\n\
         <link rel=\"self\" type=\"application/atom+xml\" href=\"{home}feed.xml\"/>\n\
         <author><name>{title}</name></author>\n<generator>Modus Notes · serv.pub</generator>\n",
        lang = escape(&settings.lang),
        title = escape(&settings.title),
    );
    if !settings.about.is_empty() {
        out.push_str(&format!("<subtitle>{}</subtitle>\n", escape(&cut(&plain(&settings.about)))));
    }
    for entry in entries.iter().take(FEED_ENTRIES) {
        let url = format!("{home}{}", entry.slug);
        let title = if entry.title.is_empty() { &entry.slug } else { &entry.title };
        out.push_str(&format!(
            "<entry>\n<title>{}</title>\n<id>{url}</id>\n<link rel=\"alternate\" type=\"text/html\" href=\"{url}\"/>\n\
             <updated>{}</updated>\n",
            escape(title),
            rfc3339(entry.updated_ms),
        ));
        if !entry.summary.is_empty() {
            out.push_str(&format!("<summary>{}</summary>\n", escape(&entry.summary)));
        }
        out.push_str("</entry>\n");
    }
    out.push_str("</feed>\n");
    out
}

/// The body's face: its file names (regular, italic if it has one) and the
/// system fonts that stand in while it loads or for what it lacks.
fn body_font(font: Font) -> (&'static str, Option<&'static str>, &'static str) {
    match font {
        Font::Inter => ("inter", None, "system-ui,-apple-system,\"Segoe UI\",sans-serif"),
        Font::Literata => ("literata", Some("literata-italic"), "Georgia,\"Times New Roman\",serif"),
        Font::Atkinson => ("atkinson", Some("atkinson-italic"), "system-ui,-apple-system,\"Segoe UI\",sans-serif"),
        Font::Quattro => ("quattro", Some("quattro-italic"), "ui-monospace,\"SF Mono\",Menlo,monospace"),
    }
}

fn font_face(family: &str, file: &str, italic: bool) -> String {
    format!(
        "@font-face{{font-family:\"{family}\";src:url(/fonts/{file}.woff2) format(\"woff2\");font-weight:100 900;\
font-style:{};font-display:swap;unicode-range:{UNICODE_RANGE}}}\n",
        if italic { "italic" } else { "normal" }
    )
}

fn px(value: f64) -> u32 {
    value.round() as u32
}

/// A site's stylesheet: its colours, and sizes and proportions all from φ.
pub fn css(settings: &SiteSettings) -> String {
    let t = &settings.theme;
    let b = f64::from(settings.body);
    let [_, xxs, xs, s, m, l, xl, xxl, _] = SPACING;
    let (regular, italic, fallback) = body_font(settings.font);
    let mut faces = font_face("Modus Heading", "jakarta", false);
    faces.push_str(&font_face("Modus Text", regular, false));
    if let Some(italic) = italic {
        faces.push_str(&font_face("Modus Text", italic, true));
    }
    faces
        + &format!(
            ":root{{color-scheme:{scheme};--bg:{bg};--surface:{surface};--text:{text};--muted:{muted};--accent:{accent};\
--accent2:{accent2};--body:{body}px;--caption:{caption}px;--h3:{h3}px;--h2:{h2}px;--h1:{h1}px;--measure:{MEASURE}px;\
--wide:{WIDE}px}}\n\
*{{box-sizing:border-box}}\n\
html{{background:var(--bg);color:var(--text);font:var(--body)/{PHI:.3} \"Modus Text\",{fallback}}}\n\
body{{margin:0;padding:{l}px {m}px {xl}px}}\n\
h1,h2,h3,h4,h5,h6{{font-family:\"Modus Heading\",system-ui,sans-serif;line-height:1.236;margin:{l}px 0 {s}px}}\n\
h1{{font-size:var(--h1)}}h2{{font-size:var(--h2)}}h3{{font-size:var(--h3)}}h4,h5,h6{{font-size:var(--body)}}\n\
p,ul,ol,blockquote,pre,table,figure{{margin:0 0 {m}px}}\n\
a{{color:var(--accent);text-underline-offset:{xxs}px}}a:visited{{color:var(--accent2)}}\n\
img{{display:block;max-width:100%;height:auto;margin:{m}px 0;border-radius:{s}px}}\n\
figure{{margin:{l}px 0}}figcaption,.label,footer.site{{color:var(--muted);font-size:var(--caption)}}\n\
.label{{text-transform:uppercase;letter-spacing:.0618em;margin:{l}px 0 {xs}px}}\n\
blockquote{{border-left:{xxs}px solid var(--accent);padding:0 0 0 {m}px;color:var(--muted)}}\n\
pre,code{{font-family:ui-monospace,\"SF Mono\",Menlo,monospace;font-size:.889em}}\n\
pre{{background:var(--surface);padding:{m}px;border-radius:{s}px;overflow-x:auto}}\n\
table{{border-collapse:collapse}}th,td{{border-bottom:1px solid var(--surface);padding:{xs}px {s}px;text-align:left}}\n\
hr{{border:0;border-top:1px solid var(--surface);margin:{xl}px 0}}\n\
audio{{width:100%}}\n\
.tags ul{{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:{xs}px}}\
.tags li{{background:var(--surface);border-radius:{m}px;padding:{xxs}px {s}px;font-size:var(--caption)}}\n\
.checklist ul{{list-style:none;padding:0}}.checklist li.done{{color:var(--muted);text-decoration:line-through}}\n\
header.site{{max-width:var(--wide);margin:0 auto {xl}px}}header.site a{{color:var(--muted);text-decoration:none;font-weight:600}}\n\
footer.site{{max-width:var(--wide);margin:{xxl}px auto 0}}\n\
main{{margin:0 auto;max-width:var(--measure)}}\n\
.golden-section main,.book main{{max-width:var(--wide);display:grid;gap:{xl}px}}\n\
.golden-section main{{grid-template-columns:61.8fr 38.2fr}}\n\
.book main{{grid-template-columns:38.2fr 61.8fr}}\n\
.contents ol{{padding-left:{m}px}}.contents a{{color:var(--muted)}}\n\
aside{{border-left:1px solid var(--surface);padding-left:{l}px}}\n\
.cover{{max-width:var(--wide);margin:0 auto {xl}px;aspect-ratio:{PHI:.3}/1;background:var(--surface);border-radius:{m}px;\
display:grid;grid-template-rows:61.8fr 38.2fr;padding:0 {xl}px}}.cover h1{{grid-row:2;align-self:start;margin:0}}\n\
.home .about{{color:var(--muted)}}\n\
.pages{{list-style:none;padding:0}}.pages li{{margin:0 0 {s}px}}\n\
.collection main{{max-width:var(--wide)}}\n\
.collection .pages{{display:grid;grid-template-columns:repeat(auto-fill,minmax(233px,1fr));gap:{l}px}}\n\
.collection .pages a{{display:flex;align-items:flex-end;aspect-ratio:{PHI:.3}/1;background:var(--surface);\
border-radius:{m}px;padding:{m}px;text-decoration:none;font-family:\"Modus Heading\",system-ui,sans-serif;font-size:var(--h3);line-height:1.236}}\n\
@media (max-width:{MEASURE}px){{body{{padding:{m}px {s}px {l}px}}\
.golden-section main,.book main{{display:block}}aside{{border:0;padding:0}}.cover{{padding:0 {m}px}}\
:root{{--h1:{h2}px;--h2:{h3}px}}}}\n\
",
            scheme = if t.dark { "dark" } else { "light" },
            bg = t.background,
            surface = t.surface,
            text = t.text,
            muted = t.secondary,
            accent = t.accent,
            accent2 = t.second_accent,
            body = settings.body,
            caption = px(b / PHI),
            h3 = px(b * PHI),
            h2 = px(b * PHI * PHI),
            h1 = px(b * PHI * PHI * PHI),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::{self, Check, Link};
    use crate::settings;

    const SITE: &str = "quaderno";
    const PIC: &str = "AAAAAAAAAAAAAAAA";

    fn md(text: &str) -> String {
        markdown(text, SITE, &|id| id == PIC)
    }

    #[test]
    fn raw_html_is_text() {
        assert_eq!(md("<script>alert(1)</script>"), "&lt;script&gt;alert(1)&lt;/script&gt;");
        assert_eq!(md("a <img src=x onerror=alert(1)> b"), "<p>a &lt;img src=x onerror=alert(1)&gt; b</p>");
        assert!(!md("<div onclick=\"x\">\n\nhi\n\n</div>").contains("<div"));
    }

    #[test]
    fn links_only_to_the_web_mail_and_the_site() {
        assert_eq!(
            md("[a](https://x.org)"),
            r#"<p><a href="https://x.org" rel="nofollow noopener noreferrer ugc">a</a></p>"#
        );
        assert_eq!(md("[a](page:il-faro)"), r#"<p><a href="/quaderno/il-faro">a</a></p>"#);
        assert_eq!(
            md("[a](mailto:p@x.org)"),
            r#"<p><a href="mailto:p@x.org" rel="nofollow noopener noreferrer ugc">a</a></p>"#
        );
        for bad in [
            "javascript:alert(1)",
            "data:text/html,x",
            "note:abc",
            "page:../x",
            "//evil.org",
            "vbscript:x",
            "mailto:a@b@c",
        ] {
            assert_eq!(md(&format!("[a]({bad})")), "<p>a</p>", "{bad}");
        }
        assert_eq!(md("<javascript:alert(1)>"), "<p>javascript:alert(1)</p>");
    }

    #[test]
    fn pictures_only_from_the_sites_files() {
        assert_eq!(md(&format!("![il mare]({PIC})")), "<p>il mare</p>");
        assert_eq!(
            md(&format!("![il *mare*](image:{PIC})")),
            format!(r#"<p><img src="/quaderno/m/{PIC}" alt="il mare" loading="lazy"></p>"#)
        );
        assert_eq!(md("![x](image:BBBBBBBBBBBBBBBB)"), "<p>x</p>", "not uploaded");
        assert_eq!(md("![x\"onerror=\"y](https://evil.org/p.png)"), "<p>x&quot;onerror=&quot;y</p>");
        assert_eq!(images_in(&format!("![a](image:{PIC}) ![b](image:bad) ![c](https://x.org/c.png)")), [PIC]);
    }

    #[test]
    fn headings_move_down_and_markup_is_known() {
        assert_eq!(md("# A\n###### B"), "<h2>A</h2><h6>B</h6>");
        assert_eq!(md("*a* **b** ~~c~~ `d<`"), "<p><em>a</em> <strong>b</strong> <del>c</del> <code>d&lt;</code></p>");
        assert_eq!(md("- [x] fatto\n- [ ] da fare"), "<ul><li>☑ fatto</li><li>☐ da fare</li></ul>");
        assert_eq!(md("3. tre\n4. quattro"), r#"<ol start="3"><li>tre</li><li>quattro</li></ol>"#);
        assert_eq!(
            md("| a |\n|---|\n| b |"),
            "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>"
        );
        assert_eq!(md("```\n<b>\n```"), "<pre><code>&lt;b&gt;\n</code></pre>");
    }

    #[test]
    fn a_page_has_no_script_and_its_title_once() {
        let html = page(SITE, "il-faro", &settings::sample(), &page::sample(), &[], "1", &|_| false);
        assert!(html.starts_with("<!doctype html>"));
        assert!(!html.to_lowercase().contains("<script"));
        assert_eq!(html.matches("<h1>").count(), 1);
        assert!(html.contains("<h1>Il faro</h1>"));
        assert!(html.contains(r#"<meta name="robots" content="noindex, nofollow">"#), "not indexable by default");
        assert!(html.contains(r#"<html lang="it">"#));
        assert!(html.contains(r#"href="/quaderno/style.css?v=1""#));
    }

    #[test]
    fn indexed_only_when_the_site_allows_and_the_page_is_listed() {
        let mut s = settings::sample();
        s.indexable = true;
        let listed = page(SITE, "il-faro", &s, &page::sample(), &[], "1", &|_| false);
        assert!(!listed.contains("noindex"));
        let draft = page::Page { listed: false, ..page::sample() };
        assert!(page(SITE, "il-faro", &s, &draft, &[], "1", &|_| false).contains("noindex"));
    }

    #[test]
    fn blocks_are_escaped_and_media_must_be_uploaded() {
        let p = page::Page {
            layout: page::Layout::GoldenSection,
            title: "<T>".into(),
            blocks: vec![
                Block::Markdown { label: String::new(), text: "testo".into() },
                Block::Text { label: "BPM".into(), text: "<120>".into() },
                Block::Checklist { label: String::new(), items: vec![Check { text: "a&b".into(), done: true }] },
                Block::Links {
                    label: String::new(),
                    items: vec![Link { url: "https://x.org/?a=1&b=2".into(), title: String::new() }],
                },
                Block::Image { label: String::new(), media: PIC.into(), caption: "\"c\"".into() },
                Block::Audio { label: String::new(), media: "BBBBBBBBBBBBBBBB".into() },
            ],
            ..page::sample()
        };
        let html = page(SITE, "il-faro", &settings::sample(), &p, &[], "1", &|id| id == PIC);
        assert!(html.contains("<h1>&lt;T&gt;</h1>"));
        assert!(html.contains("&lt;120&gt;"));
        assert!(html.contains(r#"<li class="done">a&amp;b</li>"#));
        assert!(html.contains(r#"href="https://x.org/?a=1&amp;b=2""#));
        assert!(html.contains(&format!(r#"src="/quaderno/m/{PIC}" alt="&quot;c&quot;""#)));
        assert!(!html.contains("<audio"), "audio not uploaded");
        // Golden section: the text in the article, the rest in the aside.
        let aside = html.split("<aside>").nth(1).unwrap();
        assert!(aside.contains("BPM") && !aside.contains("testo"));
    }

    #[test]
    fn home_lists_pages_and_book_lists_contents() {
        let entries =
            [Entry { slug: "il-faro".into(), title: "Il <faro>".into(), updated_ms: 1, summary: String::new() }];
        let html = home(SITE, &settings::sample(), &entries, "1");
        assert!(html.contains(r#"<a href="/quaderno/il-faro">Il &lt;faro&gt;</a>"#));
        assert!(html.contains(r#"<body class="home collection">"#));
        let book = page::Page { layout: page::Layout::Book, ..page::sample() };
        assert!(
            page(SITE, "il-faro", &settings::sample(), &book, &entries, "1", &|_| false)
                .contains("<nav class=\"contents\">")
        );
    }

    #[test]
    fn the_stylesheet_is_built_on_phi() {
        let css = css(&settings::sample());
        assert!(css.contains("--body:18px;--caption:11px;--h3:29px;--h2:47px;--h1:76px"), "{css}");
        assert!(css.contains("--bg:#090C15"));
        assert!(css.contains("grid-template-columns:61.8fr 38.2fr"));
        assert!(css.contains("grid-template-columns:38.2fr 61.8fr"));
        assert!(css.contains("aspect-ratio:1.618/1"));
        assert!(css.contains("--measure:610px"));
        // Fonts only from serv.pub itself, and only those it serves.
        for url in css.split("url(").skip(1) {
            let file = url.split(')').next().unwrap();
            let name = file.strip_prefix("/fonts/").and_then(|f| f.strip_suffix(".woff2")).unwrap();
            assert!(FONT_FILES.contains(&name), "{file}");
        }
    }

    #[test]
    fn the_body_font_is_the_sites_and_headings_are_jakarta() {
        let inter = css(&settings::sample());
        assert!(inter.contains("url(/fonts/jakarta.woff2)") && inter.contains("url(/fonts/inter.woff2)"));
        assert!(!inter.contains("font-style:italic"), "Inter has no italic file");
        assert!(inter.contains("font-display:swap"));
        assert!(inter.contains(&format!("unicode-range:{UNICODE_RANGE}")));
        let mut s = settings::sample();
        s.font = Font::Literata;
        let literata = css(&s);
        assert!(
            literata.contains("url(/fonts/literata.woff2)") && literata.contains("url(/fonts/literata-italic.woff2)")
        );
        assert!(literata.contains(r#"font:var(--body)/1.618 "Modus Text",Georgia"#), "{literata}");
        assert!(!literata.contains("inter.woff2"));
        for font in [Font::Inter, Font::Literata, Font::Atkinson, Font::Quattro] {
            let (regular, italic, _) = body_font(font);
            assert!(FONT_FILES.contains(&regular));
            assert!(italic.is_none_or(|i| FONT_FILES.contains(&i)));
        }
    }

    #[test]
    fn link_previews_tell_title_words_picture_and_address() {
        let p = page::Page {
            blocks: vec![
                Block::Image { label: String::new(), media: "BBBBBBBBBBBBBBBB".into(), caption: String::new() },
                Block::Markdown {
                    label: String::new(),
                    text: format!("## Prima\n\nLa luce *gira* <\"sempre\">. ![x](image:{PIC})"),
                },
            ],
            ..page::sample()
        };
        let html = page(SITE, "il-faro", &settings::sample(), &p, &[], "1", &|id| id == PIC);
        assert!(html.contains(r#"<link rel="canonical" href="https://serv.pub/quaderno/il-faro">"#));
        assert!(html.contains(r#"<meta property="og:url" content="https://serv.pub/quaderno/il-faro">"#));
        assert!(html.contains(r#"<meta property="og:type" content="article">"#));
        assert!(
            html.contains(
                r#"<meta property="og:description" content="Prima La luce gira &lt;&quot;sempre&quot;&gt;.">"#
            ),
            "{html}"
        );
        // The first picture the site holds, at its whole address.
        assert!(html.contains(&format!(r#"<meta property="og:image" content="https://serv.pub/quaderno/m/{PIC}">"#)));
        assert!(html.contains(r#"content="summary_large_image""#));
        assert!(html.contains(r#"<link rel="alternate" type="application/atom+xml" href="/quaderno/feed.xml""#));
        let home = home(SITE, &settings::sample(), &[], "1");
        assert!(home.contains(r#"<meta property="og:type" content="website">"#));
        assert!(home.contains(r#"<meta name="description" content="Racconti e canzoni.">"#));
        assert!(home.contains(r#"content="summary""#) && !home.contains("og:image"));
    }

    #[test]
    fn excerpts_are_plain_and_short() {
        assert_eq!(plain("# A\n\n*b* `c` [d](https://x.org) ![alt](image:x)\n- e"), "A b c d e");
        let long = "parola ".repeat(100);
        let p =
            page::Page { blocks: vec![Block::Markdown { label: String::new(), text: long.clone() }], ..page::sample() };
        let e = excerpt(&p);
        assert!(e.chars().count() <= EXCERPT, "{e}");
        assert!(e.ends_with("parola…"), "{e}");
        let tags = page::Page { blocks: vec![page::sample().blocks[1].clone()], ..page::sample() };
        assert_eq!(excerpt(&tags), "", "only text describes a page");
    }

    #[test]
    fn the_feed_is_atom_escaped_and_bounded() {
        let entries: Vec<Entry> = (0..30)
            .map(|i| Entry {
                slug: format!("p-{i}"),
                title: "<b>&".into(),
                updated_ms: 1_793_404_800_000 - i * 1000,
                summary: "a < b".into(),
            })
            .collect();
        let xml = feed(SITE, &settings::sample(), &entries);
        assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"utf-8\"?>"));
        assert!(xml.contains(r#"<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="it">"#));
        assert!(xml.contains("<id>https://serv.pub/quaderno/</id>"));
        assert!(
            xml.contains(r#"<link rel="self" type="application/atom+xml" href="https://serv.pub/quaderno/feed.xml"/>"#)
        );
        assert!(xml.contains("<updated>2026-10-31T00:00:00Z</updated>"), "{xml}");
        assert_eq!(xml.matches("<entry>").count(), FEED_ENTRIES);
        assert!(xml.contains("<title>&lt;b&gt;&amp;</title>"));
        assert!(xml.contains("<summary>a &lt; b</summary>"));
        assert!(!xml.contains("<b>"));
        assert!(feed(SITE, &settings::sample(), &[]).contains("<updated>1970-01-01T00:00:00Z</updated>"));
    }

    #[test]
    fn dates_are_rfc3339() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1_793_448_245_999), "2026-10-31T12:04:05Z");
    }
}
