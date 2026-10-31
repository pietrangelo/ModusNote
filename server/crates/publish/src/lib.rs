//! # Publish
//!
//! Public pages on serv.pub, the publishing platform of Modus Notes. A note
//! the person chooses to publish leaves the vault as a snapshot in clear:
//! this is the one place where the server sees content, by the person's
//! explicit choice, and only what `PublicationPolicy` (Dart) let out.
//!
//! - [`SiteSettings`] and [`Page`]: the wire formats, checked strictly
//!   (unknown fields refused, safe text, web-only links, contrast held).
//! - [`render`]: Markdown to HTML without raw HTML or scripts, pages and
//!   stylesheets built on φ.
//! - [`Site`]: one site's use cases on the [`sync::Store`] port, writes
//!   signed by the site's own key.

pub mod names;
pub mod page;
pub mod render;
pub mod settings;
mod site;
mod text;

pub use page::{Block, Layout, Page};
pub use settings::{Font, HomeLayout, SiteSettings, Theme};
pub use site::{MediaType, Site, SiteError, SiteLimits};
pub use text::escape;
