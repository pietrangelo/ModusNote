//! # serv.pub
//!
//! The Worker of serv.pub, the publishing platform of Modus Notes. It only
//! reads: a site's home, pages and stylesheet come rendered from the site's
//! Durable Object (`ModusSite`, in the `modusnote` Worker, which takes the
//! signed writes under `modus.serv.run/api/s/`), its files from R2.
//!
//! It is a Worker of its own, with no API and no static assets but its fonts, so nothing
//! of the vault's web client is ever served from this origin and nothing on
//! it can reach the vault's storage. Every response forbids scripts.
//!
//! [`route`] and [`headers`] are the HTTP surface without the runtime.
#![forbid(unsafe_code)]

use publish::cookbook::PATH as COOKBOOK;
use publish::names::{media_id, page_slug, site_name};
use publish::render::FONT_FILES;

/// The longest query passed on to a site's object: a search and its
/// filters, or other servings. A longer one is dropped.
pub const MAX_QUERY: usize = 512;

/// `query` as it may reach a site's object.
pub fn passed_query(query: Option<&str>) -> String {
    match query {
        Some(q) if !q.is_empty() && q.len() <= MAX_QUERY => format!("?{q}"),
        _ => String::new(),
    }
}

#[cfg(target_arch = "wasm32")]
mod runtime;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PublicRoute {
    /// The platform's own front page.
    Front,
    Robots,
    /// `/<site>` without the slash: redirected to the home.
    Slash(String),
    Home(String),
    Style(String),
    /// A site's Atom feed.
    Feed(String),
    Page(String, String),
    /// A site's cookbook: its showcase, or a search in it.
    Cookbook(String),
    /// One category of a site's cookbook.
    CookbookCategory(String, String),
    Media(String, String),
    /// One of the fonts the stylesheets name, from this Worker's assets.
    Font(&'static str),
    NotFound,
}

/// Maps a path to what serv.pub serves there. The query is passed only to
/// pages and the cookbook (the stylesheet carries a version in it only to
/// bust caches).
/// The part of a file a `Range` header asks for, `bytes=a-b` or `bytes=a-`,
/// as offset and inclusive end: what a video needs to start and seek (Safari
/// plays none without it). Anything else, several ranges included, is
/// ignored and the whole file is sent, as HTTP allows.
pub fn byte_range(header: Option<&str>) -> Option<(u64, Option<u64>)> {
    let spec = header?.trim().strip_prefix("bytes=")?;
    let (first, last) = spec.split_once('-')?;
    let digits = |s: &str| !s.is_empty() && s.len() <= 16 && s.bytes().all(|b| b.is_ascii_digit());
    if !digits(first) {
        return None;
    }
    let first: u64 = first.parse().ok()?;
    if last.is_empty() {
        return Some((first, None));
    }
    let last: u64 = if digits(last) { last.parse().ok()? } else { return None };
    (last >= first).then_some((first, Some(last)))
}

pub fn route(method: &str, path: &str) -> PublicRoute {
    if method != "GET" && method != "HEAD" {
        return PublicRoute::NotFound;
    }
    let segments: Vec<&str> = path.strip_prefix('/').unwrap_or(path).split('/').collect();
    match segments.as_slice() {
        [""] => PublicRoute::Front,
        ["robots.txt"] => PublicRoute::Robots,
        // "fonts" is a reserved site name: no site can be there.
        ["fonts", file] => file
            .strip_suffix(".woff2")
            .and_then(|name| FONT_FILES.iter().find(|f| **f == name))
            .map_or(PublicRoute::NotFound, |name| PublicRoute::Font(name)),
        [site] if site_name(site) => PublicRoute::Slash((*site).to_owned()),
        [site, ""] if site_name(site) => PublicRoute::Home((*site).to_owned()),
        [site, "style.css"] if site_name(site) => PublicRoute::Style((*site).to_owned()),
        // A page's address has no dot, so no page is there.
        [site, "feed.xml"] if site_name(site) => PublicRoute::Feed((*site).to_owned()),
        // No page may take the cookbook's address.
        [site, COOKBOOK] if site_name(site) => PublicRoute::Cookbook((*site).to_owned()),
        [site, COOKBOOK, category] if site_name(site) && page_slug(category) => {
            PublicRoute::CookbookCategory((*site).to_owned(), (*category).to_owned())
        }
        [site, slug] if site_name(site) && page_slug(slug) => PublicRoute::Page((*site).to_owned(), (*slug).to_owned()),
        [site, "m", id] if site_name(site) && media_id(id) => PublicRoute::Media((*site).to_owned(), (*id).to_owned()),
        _ => PublicRoute::NotFound,
    }
}

/// The headers of every response: no script, no frame, no sniffing, no
/// referrer, nothing shared with other origins' scripts.
pub fn headers(content_type: &str, cache: &str) -> Vec<(&'static str, String)> {
    vec![
        ("Content-Type", content_type.to_owned()),
        ("Cache-Control", cache.to_owned()),
        ("Content-Security-Policy", publish::render::CSP.to_owned()),
        ("X-Content-Type-Options", "nosniff".to_owned()),
        ("Referrer-Policy", "no-referrer".to_owned()),
        ("X-Frame-Options", "DENY".to_owned()),
        ("Cross-Origin-Resource-Policy", "same-origin".to_owned()),
        ("Cross-Origin-Opener-Policy", "same-origin".to_owned()),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), interest-cohort=()".to_owned()),
        ("Strict-Transport-Security", "max-age=63072000; includeSubDomains".to_owned()),
    ]
}

/// Pages change when their author republishes: a minute in any cache.
pub const PAGE_CACHE: &str = "public, max-age=60";
/// A file never changes under its id (the app draws a new id per upload).
pub const MEDIA_CACHE: &str = "public, max-age=31536000, immutable";
pub const NO_CACHE: &str = "no-store";
/// A font changes only with a new deploy of this Worker: a day in any cache.
pub const FONT_CACHE: &str = "public, max-age=86400";

pub const ROBOTS: &str = "User-agent: *\nAllow: /\n";

/// serv.pub's front page, fixed: what the platform is.
pub const FRONT: &str = "<!doctype html>\n<html lang=\"it\">\n<head>\n<meta charset=\"utf-8\">\n\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>serv.pub</title>\n</head>\n\
<body>\n<h1>serv.pub</h1>\n<p>Pagine pubblicate con Modus Notes. Ogni sito è scritto dal suo autore, \
che sceglie quali note rendere pubbliche.</p>\n<p lang=\"en\">Pages published with Modus Notes. Each site is \
written by its author, who chooses which notes to make public.</p>\n</body>\n</html>\n";

pub const NOT_FOUND: &str = "<!doctype html>\n<html lang=\"it\">\n<head>\n<meta charset=\"utf-8\">\n\
<meta name=\"robots\" content=\"noindex\">\n<title>Non trovato</title>\n</head>\n<body>\n<h1>404</h1>\n\
<p>Questa pagina non esiste o è stata ritirata.</p>\n<p lang=\"en\">This page does not exist or was taken down.</p>\n\
</body>\n</html>\n";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes() {
        assert_eq!(route("GET", "/"), PublicRoute::Front);
        assert_eq!(route("GET", "/robots.txt"), PublicRoute::Robots);
        assert_eq!(route("GET", "/quaderno"), PublicRoute::Slash("quaderno".into()));
        assert_eq!(route("GET", "/quaderno/"), PublicRoute::Home("quaderno".into()));
        assert_eq!(route("HEAD", "/quaderno/style.css"), PublicRoute::Style("quaderno".into()));
        assert_eq!(route("GET", "/quaderno/il-faro"), PublicRoute::Page("quaderno".into(), "il-faro".into()));
        assert_eq!(route("GET", "/quaderno/feed.xml"), PublicRoute::Feed("quaderno".into()));
        assert_eq!(route("GET", "/quaderno/ricette"), PublicRoute::Cookbook("quaderno".into()));
        assert_eq!(
            route("GET", "/quaderno/ricette/pane-e-lievitati"),
            PublicRoute::CookbookCategory("quaderno".into(), "pane-e-lievitati".into())
        );
        assert_eq!(route("GET", "/fonts/literata-italic.woff2"), PublicRoute::Font("literata-italic"));
        for name in FONT_FILES {
            assert_eq!(route("GET", &format!("/fonts/{name}.woff2")), PublicRoute::Font(name));
        }
        assert_eq!(
            route("GET", "/quaderno/m/AAAAAAAAAAAAAAAA"),
            PublicRoute::Media("quaderno".into(), "AAAAAAAAAAAAAAAA".into())
        );
    }

    #[test]
    fn nothing_else() {
        for path in [
            "/index.html",
            "/api/info",
            "/api/",
            "/main.dart.wasm",
            "/quaderno/il-faro/",
            "/quaderno/Il_Faro",
            "/quaderno/m/short",
            "/quaderno/m/AAAAAAAAAAAAAAAA/x",
            "/Quaderno/",
            "//quaderno",
            "/quaderno/../x",
            "/assets/",
            "/fonts/",
            "/fonts/comic.woff2",
            "/fonts/inter.ttf",
            "/fonts/inter",
            "/fonts/../inter.woff2",
            "/fonts/LICENCES.txt",
            "/fonts/inter.woff2/x",
            "/quaderno/feed.rss",
            "/quaderno/ricette/",
            "/quaderno/ricette/Dolci",
            "/quaderno/ricette/a/b",
            "/quaderno/ricette/../x",
        ] {
            assert_eq!(route("GET", path), PublicRoute::NotFound, "{path}");
        }
        assert_eq!(route("POST", "/quaderno/"), PublicRoute::NotFound);
        assert_eq!(route("PUT", "/quaderno/il-faro"), PublicRoute::NotFound);
    }

    #[test]
    fn every_response_forbids_scripts() {
        let h = headers("text/html; charset=utf-8", PAGE_CACHE);
        let csp = &h.iter().find(|(name, _)| *name == "Content-Security-Policy").unwrap().1;
        assert!(csp.starts_with("default-src 'none'"));
        assert!(!csp.contains("script-src"));
        assert!(h.iter().any(|(n, v)| *n == "X-Content-Type-Options" && v == "nosniff"));
        assert!(!FRONT.contains("<script") && !NOT_FOUND.contains("<script"));
        // The cookbook's search is a form to the same origin, nowhere else.
        assert!(csp.contains("form-action 'self'"));
    }

    #[test]
    fn only_short_queries_reach_a_site() {
        assert_eq!(passed_query(None), "");
        assert_eq!(passed_query(Some("")), "");
        assert_eq!(passed_query(Some("q=pane&p=4")), "?q=pane&p=4");
        assert_eq!(passed_query(Some(&"a".repeat(MAX_QUERY + 1))), "");
    }

    #[test]
    fn ranges_of_a_file() {
        assert_eq!(byte_range(Some("bytes=0-")), Some((0, None)));
        assert_eq!(byte_range(Some("bytes=100-199")), Some((100, Some(199))));
        assert_eq!(byte_range(Some("bytes=200-100")), None);
        assert_eq!(byte_range(Some("bytes=-500")), None, "a suffix: the whole file");
        assert_eq!(byte_range(Some("bytes=0-1,5-9")), None);
        assert_eq!(byte_range(Some("items=0-1")), None);
        assert_eq!(byte_range(Some("bytes=99999999999999999-")), None);
        assert_eq!(byte_range(None), None);
    }
}
