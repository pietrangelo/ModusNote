//! The addresses of serv.pub, with the rules of the Dart domain
//! (`packages/publishing`, `SiteName` and `PageSlug`): `serv.pub/<site>/<page>`
//! and `serv.pub/<site>/m/<media>`.

/// Names the platform serves itself, or that would pass for it.
pub const RESERVED: &[&str] = &[
    "about",
    "abuse",
    "admin",
    "api",
    "app",
    "assets",
    "blog",
    "contact",
    "feed",
    "fonts",
    "help",
    "info",
    "legal",
    "login",
    "modus",
    "modusnote",
    "modusnotes",
    "official",
    "privacy",
    "report",
    "robots",
    "rss",
    "security",
    "segnala",
    "serv",
    "servpub",
    "sitemap",
    "static",
    "status",
    "support",
    "terms",
    "well-known",
    "www",
];

/// ASCII lowercase letters and digits in groups joined by single hyphens.
fn hyphenated(value: &str) -> bool {
    !value.is_empty()
        && value
            .split('-')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()))
}

/// A site's name: 3 to 34 characters, never a reserved one.
pub fn site_name(value: &str) -> bool {
    (3..=34).contains(&value.len()) && hyphenated(value) && !RESERVED.contains(&value)
}

/// A page's slug: 1 to 89 characters.
pub fn page_slug(value: &str) -> bool {
    value.len() <= 89 && hyphenated(value)
}

/// A media file's id: 16 to 64 of `A-Z a-z 0-9 - _`. The app draws a fresh
/// random one for each upload, never the id of a vault blob, so nothing on
/// the server ties a site to a workspace.
pub fn media_id(value: &str) -> bool {
    (16..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn site_names_follow_the_dart_rules() {
        for good in ["abc", "pietrangelo", "modus-notes-2", &"a".repeat(34)] {
            assert!(site_name(good), "{good}");
        }
        for bad in
            ["ab", &"a".repeat(35), "Pietro", "perché", "a.b.c", "a/b/c", "a b c", "аbc", "-abc", "abc-", "ab--c"]
        {
            assert!(!site_name(bad), "{bad}");
        }
        for reserved in RESERVED.iter().filter(|r| r.len() >= 3) {
            assert!(!site_name(reserved), "{reserved}");
        }
    }

    #[test]
    fn slugs_and_media_ids() {
        assert!(page_slug("una-pagina"));
        assert!(page_slug(&"a".repeat(89)));
        for bad in ["", "Una", "a--b", "-a", "a-", "a/b", "..", &"a".repeat(90)] {
            assert!(!page_slug(bad), "{bad}");
        }
        assert!(media_id("AbCdEf0123456789"));
        assert!(!media_id("short"));
        assert!(!media_id("abcdefghijklmnop/"));
    }
}
