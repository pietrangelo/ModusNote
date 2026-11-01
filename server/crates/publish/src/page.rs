//! A published page as the app sends it: the snapshot `PublicationPolicy`
//! composed, with the labels already in the reader's language and every
//! value already text. The server keeps it as sent once it passes these
//! checks, and renders it to HTML on every read.

use serde::{Deserialize, Serialize};

use crate::names::media_id;
use crate::recipe::Recipe;
use crate::text::{safe_line, safe_text};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub title: String,
    pub layout: Layout,
    /// A listed page is on the site's home and in its feed; an unlisted one
    /// (a draft for the preview) only at its address, never indexed.
    pub listed: bool,
    /// The note's other fields; a recipe may have none.
    pub blocks: Vec<Block>,
    /// A recipe, with the [`Layout::Recipe`] layout and only with it: it
    /// joins the site's cookbook when the page is listed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe: Option<Recipe>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    Essay,
    GoldenSection,
    GoldenCover,
    Book,
    Recipe,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Block {
    /// The body of the note, or any Markdown field.
    Markdown {
        label: String,
        text: String,
    },
    /// A short value already written out: a number, a date, a choice.
    Text {
        label: String,
        text: String,
    },
    Tags {
        label: String,
        items: Vec<String>,
    },
    Checklist {
        label: String,
        items: Vec<Check>,
    },
    Links {
        label: String,
        items: Vec<Link>,
    },
    Image {
        label: String,
        media: String,
        caption: String,
    },
    Audio {
        label: String,
        media: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Check {
    pub text: String,
    pub done: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
    pub url: String,
    pub title: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
    Json,
    Title,
    Blocks,
    Label,
    Text,
    Item,
    Url,
    Media,
    /// A recipe without the recipe layout, or the layout without one.
    Recipe,
}

pub const MAX_TITLE: usize = 200;
pub const MAX_LABEL: usize = 89;
/// A note's Markdown, like the app's own limit for a field.
pub const MAX_MARKDOWN: usize = 500_000;
pub const MAX_SHORT: usize = 610;
pub const MAX_BLOCKS: usize = 64;
pub const MAX_ITEMS: usize = 500;
pub const MAX_URL: usize = 2048;

impl Page {
    pub fn parse(json: &[u8]) -> Result<Self, Invalid> {
        let page: Self = serde_json::from_slice(json).map_err(|_| Invalid::Json)?;
        page.check()?;
        Ok(page)
    }

    pub fn check(&self) -> Result<(), Invalid> {
        if !safe_line(&self.title, MAX_TITLE) {
            return Err(Invalid::Title);
        }
        let recipe = matches!(self.layout, Layout::Recipe);
        if recipe != self.recipe.is_some() {
            return Err(Invalid::Recipe);
        }
        if (self.blocks.is_empty() && !recipe) || self.blocks.len() > MAX_BLOCKS {
            return Err(Invalid::Blocks);
        }
        if let Some(recipe) = &self.recipe {
            recipe.check()?;
        }
        self.blocks.iter().try_for_each(Block::check)
    }

    /// Every media file the page shows, in order: they must be uploaded
    /// before the page.
    pub fn media(&self) -> Vec<String> {
        let mut out = self.recipe.as_ref().map(Recipe::media).unwrap_or_default();
        for block in &self.blocks {
            match block {
                Block::Image { media, .. } | Block::Audio { media, .. } => out.push(media.clone()),
                Block::Markdown { text, .. } => out.extend(crate::render::images_in(text)),
                _ => {}
            }
        }
        out
    }
}

impl Block {
    pub fn label(&self) -> &str {
        match self {
            Self::Markdown { label, .. }
            | Self::Text { label, .. }
            | Self::Tags { label, .. }
            | Self::Checklist { label, .. }
            | Self::Links { label, .. }
            | Self::Image { label, .. }
            | Self::Audio { label, .. } => label,
        }
    }

    fn check(&self) -> Result<(), Invalid> {
        if !safe_line(self.label(), MAX_LABEL) {
            return Err(Invalid::Label);
        }
        let items = |n: usize| if n == 0 || n > MAX_ITEMS { Err(Invalid::Item) } else { Ok(()) };
        let line = |s: &str| if safe_line(s, MAX_SHORT) { Ok(()) } else { Err(Invalid::Item) };
        match self {
            Self::Markdown { text, .. } => {
                if !safe_text(text, MAX_MARKDOWN) {
                    return Err(Invalid::Text);
                }
            }
            Self::Text { text, .. } => {
                if text.is_empty() || !safe_line(text, MAX_SHORT) {
                    return Err(Invalid::Text);
                }
            }
            Self::Tags { items: tags, .. } => {
                items(tags.len())?;
                tags.iter().try_for_each(|t| line(t))?;
            }
            Self::Checklist { items: checks, .. } => {
                items(checks.len())?;
                checks.iter().try_for_each(|c| line(&c.text))?;
            }
            Self::Links { items: links, .. } => {
                items(links.len())?;
                for link in links {
                    line(&link.title)?;
                    if !web_url(&link.url) {
                        return Err(Invalid::Url);
                    }
                }
            }
            Self::Image { media, caption, .. } => {
                line(caption)?;
                if !media_id(media) {
                    return Err(Invalid::Media);
                }
            }
            Self::Audio { media, .. } => {
                if !media_id(media) {
                    return Err(Invalid::Media);
                }
            }
        }
        Ok(())
    }
}

/// An `https://` or `http://` address of printable ASCII with a host, as the
/// app's `WebLink` keeps them; nothing else becomes a link on a page.
pub fn web_url(url: &str) -> bool {
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"));
    let Some(rest) = rest else { return false };
    url.len() <= MAX_URL
        && url.bytes().all(|b| (0x21..=0x7E).contains(&b) && b != b'"' && b != b'<' && b != b'>' && b != b'\\')
        && rest.split(['/', '?', '#']).next().is_some_and(|host| !host.is_empty() && !host.contains('@'))
}

#[cfg(test)]
pub(crate) fn sample() -> Page {
    Page {
        title: "Il faro".into(),
        layout: Layout::Essay,
        listed: true,
        recipe: None,
        blocks: vec![
            Block::Markdown { label: String::new(), text: "# Prima\n\nLa luce *gira*.".into() },
            Block::Tags { label: "Tag".into(), items: vec!["mare".into(), "notte".into()] },
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_page_round_trips() {
        let json = serde_json::to_vec(&sample()).unwrap();
        assert_eq!(Page::parse(&json), Ok(sample()));
        let wire = String::from_utf8(json).unwrap();
        assert!(wire.contains(r#""kind":"markdown""#), "{wire}");
    }

    #[test]
    fn unknown_fields_and_kinds_are_refused() {
        assert_eq!(
            Page::parse(br#"{"title":"x","layout":"essay","listed":true,"blocks":[],"x":1}"#),
            Err(Invalid::Json)
        );
        assert_eq!(
            Page::parse(
                br#"{"title":"x","layout":"essay","listed":true,"blocks":[{"kind":"html","label":"","text":"<b>"}]}"#
            ),
            Err(Invalid::Json)
        );
    }

    #[test]
    fn checks() {
        let with = |block: Block| Page { blocks: vec![block], ..sample() }.check();
        assert_eq!(Page { blocks: vec![], ..sample() }.check(), Err(Invalid::Blocks));
        assert_eq!(Page { title: "a\u{202E}b".into(), ..sample() }.check(), Err(Invalid::Title));
        assert_eq!(with(Block::Text { label: String::new(), text: String::new() }), Err(Invalid::Text));
        assert_eq!(with(Block::Tags { label: String::new(), items: vec![] }), Err(Invalid::Item));
        assert_eq!(with(Block::Audio { label: String::new(), media: "../x".into() }), Err(Invalid::Media));
        let link = |url: &str| {
            with(Block::Links { label: String::new(), items: vec![Link { url: url.into(), title: "t".into() }] })
        };
        assert_eq!(link("https://example.org/a?b#c"), Ok(()));
        for bad in [
            "javascript:alert(1)",
            "data:text/html,x",
            "https://",
            "https://a b",
            "https://u@evil",
            "//x.org",
            "https://x.org/\"onmouseover",
        ] {
            assert_eq!(link(bad), Err(Invalid::Url), "{bad}");
        }
    }

    #[test]
    fn a_recipe_needs_its_layout_and_may_have_no_blocks() {
        let recipe = Page { layout: Layout::Recipe, recipe: Some(crate::recipe::sample()), blocks: vec![], ..sample() };
        assert_eq!(recipe.check(), Ok(()));
        let json = serde_json::to_vec(&recipe).unwrap();
        assert_eq!(Page::parse(&json), Ok(recipe.clone()));
        assert_eq!(Page { layout: Layout::Essay, ..recipe.clone() }.check(), Err(Invalid::Recipe));
        assert_eq!(Page { layout: Layout::Recipe, ..sample() }.check(), Err(Invalid::Recipe));
        assert_eq!(recipe.media(), ["CCCCCCCCCCCCCCCC", "DDDDDDDDDDDDDDDD"]);
        // Pages without a recipe keep their wire format.
        assert!(!String::from_utf8(serde_json::to_vec(&sample()).unwrap()).unwrap().contains("recipe"));
    }

    #[test]
    fn media_in_order() {
        let page = Page {
            blocks: vec![
                Block::Markdown { label: String::new(), text: "![a](image:AAAAAAAAAAAAAAAA)".into() },
                Block::Audio { label: String::new(), media: "BBBBBBBBBBBBBBBB".into() },
            ],
            ..sample()
        };
        assert_eq!(page.media(), ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"]);
    }
}
