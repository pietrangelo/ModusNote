//! One site on serv.pub, in its own Durable Object (named by the site's
//! name), over the same key-value [`Store`] port as the sync server.
//!
//! Whoever first claims a free name, with a proof of work, owns it: the key
//! that signed the claim. Every later write must be signed by that key, with
//! the `MN1` credential of the sync API (time within two minutes, nonce
//! never reused). The key is the site's own, drawn by the app and sealed in
//! the vault: nothing here names a workspace, a device or a member.
//!
//! Reads are public and unsigned: they render the stored settings and pages
//! to HTML and CSS.

use ledger::{MemberKey, SignatureCheck};
use serde::{Deserialize, Serialize};
use sync::{Denied, Request, Store, Unavailable, authenticate};

use crate::cookbook::{self, Category, Listed, Query};
use crate::names::{media_id, page_slug};
use crate::page::Page;
use crate::render::{self, Entry};
use crate::settings::SiteSettings;

const OWNER: &str = "owner";
const SETTINGS: &str = "settings";
const STYLE: &str = "style";
const PAGES: &str = "page/";
const MEDIA: &str = "media/";
const BYTES: &str = "bytes";
/// The cookbook's index: one entry per listed recipe, by slug.
const RECIPES: &str = "recipe/";
/// The cookbook's categories, by slug, with the order they came in.
const CATEGORIES: &str = "category/";

/// What one site may hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SiteLimits {
    pub pages: usize,
    pub media: usize,
    pub media_bytes: u64,
    pub media_file: u64,
    /// Files and bytes for a site with a cookbook: recipes are mostly
    /// photographs.
    pub cookbook_media: usize,
    pub cookbook_bytes: u64,
}

impl Default for SiteLimits {
    fn default() -> Self {
        Self {
            pages: 233,
            media: 377,
            media_bytes: 144 << 20,
            media_file: 21 << 20,
            cookbook_media: 987,
            cookbook_bytes: 610 << 20,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SiteError {
    Denied(Denied),
    /// No site, page or file by that name.
    NotFound,
    /// The name belongs to another key.
    Taken,
    /// A body that is not what the route takes.
    Invalid,
    /// A page shows a file the site does not hold.
    MissingMedia,
    /// One more page, file or byte than the site may hold.
    Full,
    Unavailable,
}

impl From<Denied> for SiteError {
    fn from(denied: Denied) -> Self {
        match denied {
            Denied::Unavailable => Self::Unavailable,
            other => Self::Denied(other),
        }
    }
}

impl From<Unavailable> for SiteError {
    fn from(_: Unavailable) -> Self {
        Self::Unavailable
    }
}

/// The kinds of file a page may show, recognised by their first bytes:
/// served with that type and `nosniff`, so nothing uploaded runs as a page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaType {
    Jpeg,
    Png,
    Webp,
    Ogg,
    /// Recordings made in a browser (Opus in WebM).
    Webm,
}

impl MediaType {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "jpeg" => Some(Self::Jpeg),
            "png" => Some(Self::Png),
            "webp" => Some(Self::Webp),
            "ogg" => Some(Self::Ogg),
            "webm" => Some(Self::Webm),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Jpeg => "jpeg",
            Self::Png => "png",
            Self::Webp => "webp",
            Self::Ogg => "ogg",
            Self::Webm => "webm",
        }
    }

    pub fn content_type(self) -> &'static str {
        match self {
            Self::Jpeg => "image/jpeg",
            Self::Png => "image/png",
            Self::Webp => "image/webp",
            Self::Ogg => "audio/ogg",
            Self::Webm => "audio/webm",
        }
    }

    /// Whether `bytes` start as a file of this type does.
    pub fn matches(self, bytes: &[u8]) -> bool {
        match self {
            Self::Jpeg => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
            Self::Png => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            Self::Webp => bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP",
            Self::Ogg => bytes.starts_with(b"OggS"),
            // The EBML header every Matroska file opens with.
            Self::Webm => bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct Stored {
    page: Page,
    updated_ms: u64,
}

#[derive(Debug)]
pub struct Site<S, C> {
    name: String,
    store: S,
    check: C,
    limits: SiteLimits,
}

impl<S: Store, C: SignatureCheck> Site<S, C> {
    pub fn new(name: &str, store: S, check: C) -> Self {
        Self { name: name.to_owned(), store, check, limits: SiteLimits::default() }
    }

    pub fn with_limits(mut self, limits: SiteLimits) -> Self {
        self.limits = limits;
        self
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    fn owner(&self) -> Result<Option<MemberKey>, SiteError> {
        Ok(self.store.get(OWNER)?.and_then(|bytes| bytes.try_into().ok()).map(MemberKey))
    }

    /// A signed write by the owner: anyone else is refused.
    fn by_owner(&mut self, request: &Request<'_>) -> Result<(), SiteError> {
        let owner = self.owner()?.ok_or(SiteError::NotFound)?;
        let caller = authenticate(&mut self.store, &self.check, request)?;
        if caller.key != owner {
            return Err(SiteError::Denied(Denied::Forbidden));
        }
        Ok(())
    }

    /// Takes the name for the key that signed, with its first settings; the
    /// proof of work is checked before. Claiming again with the same key
    /// changes nothing.
    pub fn claim(&mut self, request: &Request<'_>, settings: &[u8]) -> Result<bool, SiteError> {
        let settings = SiteSettings::parse(settings).map_err(|_| SiteError::Invalid)?;
        let caller = authenticate(&mut self.store, &self.check, request)?;
        match self.owner()? {
            Some(owner) if owner == caller.key => Ok(false),
            Some(_) => Err(SiteError::Taken),
            None => {
                let json = serde_json::to_vec(&settings).map_err(|_| SiteError::Invalid)?;
                self.store.transaction(|store| {
                    store.put(OWNER, &caller.key.0)?;
                    store.put(SETTINGS, &json)?;
                    store.put(STYLE, &request.now_ms.to_be_bytes())?;
                    Ok::<_, SiteError>(())
                })?;
                Ok(true)
            }
        }
    }

    pub fn put_settings(&mut self, request: &Request<'_>, settings: &[u8]) -> Result<(), SiteError> {
        let settings = SiteSettings::parse(settings).map_err(|_| SiteError::Invalid)?;
        self.by_owner(request)?;
        let json = serde_json::to_vec(&settings).map_err(|_| SiteError::Invalid)?;
        self.store.put(SETTINGS, &json)?;
        self.store.put(STYLE, &request.now_ms.to_be_bytes())?;
        Ok(())
    }

    /// Publishes or replaces a page. Its files must be uploaded first, so a
    /// page never shows a broken picture.
    pub fn put_page(&mut self, request: &Request<'_>, slug: &str, body: &[u8]) -> Result<bool, SiteError> {
        if !page_slug(slug) || slug == cookbook::PATH {
            return Err(SiteError::NotFound);
        }
        let page = Page::parse(body).map_err(|_| SiteError::Invalid)?;
        self.by_owner(request)?;
        for id in page.media() {
            if self.store.get(&format!("{MEDIA}{id}"))?.is_none() {
                return Err(SiteError::MissingMedia);
            }
        }
        let key = format!("{PAGES}{slug}");
        let new = self.store.get(&key)?.is_none();
        if new && self.store.list(PAGES, None, usize::MAX)?.len() >= self.limits.pages {
            return Err(SiteError::Full);
        }
        let listed = match &page.recipe {
            Some(recipe) if page.listed => Some(Listed::of(slug, &page, recipe, request.now_ms)),
            _ => None,
        };
        let category = match &listed {
            Some(entry) => self.category_for(entry)?,
            None => None,
        };
        let stored =
            serde_json::to_vec(&Stored { page, updated_ms: request.now_ms }).map_err(|_| SiteError::Invalid)?;
        let index = format!("{RECIPES}{slug}");
        let entry = match &listed {
            Some(entry) => Some(serde_json::to_vec(entry).map_err(|_| SiteError::Invalid)?),
            None => None,
        };
        self.store.transaction(|store| {
            store.put(&key, &stored)?;
            match &entry {
                Some(entry) => store.put(&index, entry)?,
                None => store.delete(&index)?,
            }
            if let Some((key, value)) = &category {
                store.put(key, value)?;
                // A new category brings its colours to the stylesheet.
                store.put(STYLE, &request.now_ms.to_be_bytes())?;
            }
            Ok::<_, SiteError>(())
        })?;
        Ok(new)
    }

    /// The record of `entry`'s category when it is new to the cookbook: the
    /// next order, which picks its colours and never changes.
    fn category_for(&self, entry: &Listed) -> Result<Option<(String, Vec<u8>)>, SiteError> {
        let slug = entry.category_slug();
        let key = format!("{CATEGORIES}{slug}");
        if self.store.get(&key)?.is_some() {
            return Ok(None);
        }
        let order = self.store.list(CATEGORIES, None, usize::MAX)?.len();
        let category = Category { slug, name: entry.category.clone(), order };
        Ok(Some((key, serde_json::to_vec(&category).map_err(|_| SiteError::Invalid)?)))
    }

    pub fn delete_page(&mut self, request: &Request<'_>, slug: &str) -> Result<(), SiteError> {
        if !page_slug(slug) {
            return Err(SiteError::NotFound);
        }
        self.by_owner(request)?;
        let key = format!("{PAGES}{slug}");
        if self.store.get(&key)?.is_none() {
            return Err(SiteError::NotFound);
        }
        let index = format!("{RECIPES}{slug}");
        self.store.transaction(|store| {
            store.delete(&key)?;
            store.delete(&index)?;
            Ok::<_, SiteError>(())
        })
    }

    /// Counts a file about to be uploaded (its bytes go to R2, not here).
    /// Uploading the same id again replaces it.
    pub fn admit_media(
        &mut self,
        request: &Request<'_>,
        id: &str,
        kind: MediaType,
        size: u64,
    ) -> Result<(), SiteError> {
        if !media_id(id) {
            return Err(SiteError::NotFound);
        }
        if size == 0 || size > self.limits.media_file {
            return Err(SiteError::Full);
        }
        self.by_owner(request)?;
        let key = format!("{MEDIA}{id}");
        let previous = self.store.get(&key)?.map(|v| media_size(&v)).unwrap_or(0);
        let (files, bytes) = if self.has_cookbook()? {
            (self.limits.media.max(self.limits.cookbook_media), self.limits.media_bytes.max(self.limits.cookbook_bytes))
        } else {
            (self.limits.media, self.limits.media_bytes)
        };
        if previous == 0 && self.store.list(MEDIA, None, usize::MAX)?.len() >= files {
            return Err(SiteError::Full);
        }
        let total = self.bytes()? - previous + size;
        if total > bytes {
            return Err(SiteError::Full);
        }
        self.store.transaction(|store| {
            store.put(&key, format!("{}|{size}", kind.name()).as_bytes())?;
            store.put(BYTES, &total.to_be_bytes())?;
            Ok::<_, SiteError>(())
        })
    }

    /// Forgets a file no page shows any more; the runtime deletes it from R2.
    pub fn delete_media(&mut self, request: &Request<'_>, id: &str) -> Result<(), SiteError> {
        if !media_id(id) {
            return Err(SiteError::NotFound);
        }
        self.by_owner(request)?;
        let key = format!("{MEDIA}{id}");
        let size = self.store.get(&key)?.map(|v| media_size(&v)).ok_or(SiteError::NotFound)?;
        let total = self.bytes()?.saturating_sub(size);
        self.store.transaction(|store| {
            store.delete(&key)?;
            store.put(BYTES, &total.to_be_bytes())?;
            Ok::<_, SiteError>(())
        })
    }

    /// Takes the whole site down: settings, pages, files and the name, which
    /// anyone may claim again. The runtime deletes the files from R2.
    pub fn delete(&mut self, request: &Request<'_>) -> Result<(), SiteError> {
        self.by_owner(request)?;
        self.store.clear()?;
        Ok(())
    }

    /// Whether the site lists a recipe.
    fn has_cookbook(&self) -> Result<bool, SiteError> {
        Ok(!self.store.list(RECIPES, None, 1)?.is_empty())
    }

    fn categories(&self) -> Result<Vec<Category>, SiteError> {
        let mut categories: Vec<Category> = self
            .store
            .list(CATEGORIES, None, usize::MAX)?
            .into_iter()
            .filter_map(|(_, v)| serde_json::from_slice(&v).ok())
            .collect();
        categories.sort_by_key(|c| c.order);
        Ok(categories)
    }

    /// The listed recipes, newest first.
    fn recipes(&self) -> Result<Vec<Listed>, SiteError> {
        let mut entries: Vec<Listed> = self
            .store
            .list(RECIPES, None, usize::MAX)?
            .into_iter()
            .filter_map(|(_, v)| serde_json::from_slice(&v).ok())
            .collect();
        entries.sort_by(|a, b| b.updated_ms.cmp(&a.updated_ms).then_with(|| a.slug.cmp(&b.slug)));
        Ok(entries)
    }

    /// The cookbook's showcase, or a search in it; not found when the site
    /// lists no recipe.
    pub fn cookbook_html(&self, query: Option<&str>) -> Result<String, SiteError> {
        let entries = self.recipes()?;
        if entries.is_empty() {
            return Err(SiteError::NotFound);
        }
        let settings = self.settings()?;
        let uploaded = self.uploaded()?;
        Ok(cookbook::showcase(
            &self.name,
            &settings,
            &self.categories()?,
            &entries,
            &Query::parse(query),
            &self.style_version()?,
            &|id| uploaded.iter().any(|u| u == id),
        ))
    }

    /// One category of the cookbook.
    pub fn category_html(&self, slug: &str) -> Result<String, SiteError> {
        if !page_slug(slug) {
            return Err(SiteError::NotFound);
        }
        let settings = self.settings()?;
        let uploaded = self.uploaded()?;
        cookbook::category_page(
            &self.name,
            &settings,
            &self.categories()?,
            &self.recipes()?,
            slug,
            &self.style_version()?,
            &|id| uploaded.iter().any(|u| u == id),
        )
        .ok_or(SiteError::NotFound)
    }

    fn bytes(&self) -> Result<u64, SiteError> {
        Ok(self.store.get(BYTES)?.and_then(|b| b.try_into().ok()).map(u64::from_be_bytes).unwrap_or(0))
    }

    fn settings(&self) -> Result<SiteSettings, SiteError> {
        let json = self.store.get(SETTINGS)?.ok_or(SiteError::NotFound)?;
        serde_json::from_slice(&json).map_err(|_| SiteError::Unavailable)
    }

    fn style_version(&self) -> Result<String, SiteError> {
        Ok(self.store.get(STYLE)?.and_then(|b| b.try_into().ok()).map(u64::from_be_bytes).unwrap_or(0).to_string())
    }

    fn uploaded(&self) -> Result<Vec<String>, SiteError> {
        Ok(self.store.list(MEDIA, None, usize::MAX)?.into_iter().map(|(k, _)| k[MEDIA.len()..].to_owned()).collect())
    }

    /// The listed pages, newest first; with what each says first only for
    /// the feed, which needs it.
    fn entries(&self, summaries: bool) -> Result<Vec<Entry>, SiteError> {
        let mut entries = Vec::new();
        for (key, value) in self.store.list(PAGES, None, usize::MAX)? {
            let Ok(stored) = serde_json::from_slice::<Stored>(&value) else { continue };
            if stored.page.listed {
                entries.push(Entry {
                    slug: key[PAGES.len()..].to_owned(),
                    summary: if summaries { render::excerpt(&stored.page) } else { String::new() },
                    title: stored.page.title,
                    updated_ms: stored.updated_ms,
                });
            }
        }
        entries.sort_by(|a, b| b.updated_ms.cmp(&a.updated_ms).then_with(|| a.slug.cmp(&b.slug)));
        Ok(entries)
    }

    pub fn home_html(&self) -> Result<String, SiteError> {
        Ok(render::home(&self.name, &self.settings()?, &self.entries(false)?, &self.style_version()?))
    }

    /// A page; for a recipe, `query` may ask for other servings (`p=`).
    pub fn page_html(&self, slug: &str, query: Option<&str>) -> Result<String, SiteError> {
        if !page_slug(slug) {
            return Err(SiteError::NotFound);
        }
        let settings = self.settings()?;
        let json = self.store.get(&format!("{PAGES}{slug}"))?.ok_or(SiteError::NotFound)?;
        let stored: Stored = serde_json::from_slice(&json).map_err(|_| SiteError::Unavailable)?;
        let uploaded = self.uploaded()?;
        if let Some(recipe) = &stored.page.recipe {
            let others = if stored.page.listed { self.recipes()? } else { Vec::new() };
            return Ok(cookbook::recipe_page(
                &self.name,
                slug,
                &settings,
                &stored.page,
                recipe,
                &self.categories()?,
                &others,
                Query::parse(query).servings,
                &self.style_version()?,
                &|id| uploaded.iter().any(|u| u == id),
            ));
        }
        let contents =
            if matches!(stored.page.layout, crate::page::Layout::Book) { self.entries(false)? } else { Vec::new() };
        Ok(render::page(&self.name, slug, &settings, &stored.page, &contents, &self.style_version()?, &|id| {
            uploaded.iter().any(|u| u == id)
        }))
    }

    /// The site's Atom feed: its newest listed pages.
    pub fn feed_xml(&self) -> Result<String, SiteError> {
        Ok(render::feed(&self.name, &self.settings()?, &self.entries(true)?))
    }

    pub fn style_css(&self) -> Result<String, SiteError> {
        let settings = self.settings()?;
        Ok(render::css(&settings) + &cookbook::css(&settings, self.categories()?.len()))
    }

    /// The type of an uploaded file, for serving it.
    pub fn media_type(&self, id: &str) -> Result<MediaType, SiteError> {
        if !media_id(id) {
            return Err(SiteError::NotFound);
        }
        let value = self.store.get(&format!("{MEDIA}{id}"))?.ok_or(SiteError::NotFound)?;
        let text = String::from_utf8(value).map_err(|_| SiteError::Unavailable)?;
        text.split('|').next().and_then(MediaType::parse).ok_or(SiteError::Unavailable)
    }
}

fn media_size(value: &[u8]) -> u64 {
    std::str::from_utf8(value).ok().and_then(|t| t.split('|').nth(1)).and_then(|s| s.parse().ok()).unwrap_or(0)
}
