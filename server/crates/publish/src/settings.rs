//! What a site chooses about itself: its title, a few words about it, its
//! colours and type size, how its home looks, and whether search engines
//! may index it. The colours come from the app (`SitePalette`, derived with
//! φ in OKLCH); the server does not derive them again, it checks that they
//! still meet the contrast the app promises, so no request can publish an
//! unreadable page.

use serde::{Deserialize, Serialize};

use crate::text::{safe_line, safe_text};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SiteSettings {
    pub title: String,
    #[serde(default)]
    pub about: String,
    pub lang: String,
    pub theme: Theme,
    pub body: u8,
    pub home: HomeLayout,
    #[serde(default)]
    pub indexable: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Theme {
    pub dark: bool,
    pub background: String,
    pub surface: String,
    pub text: String,
    pub secondary: String,
    pub accent: String,
    pub second_accent: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HomeLayout {
    /// Golden-rectangle cards.
    Collection,
    /// One column of titles.
    Essay,
}

/// What a site's settings may not be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
    Title,
    About,
    Lang,
    Colour,
    Contrast,
    Body,
}

pub const MAX_TITLE: usize = 89;
pub const MAX_ABOUT: usize = 2584;
pub const BODY_SIZES: [u8; 3] = [16, 18, 20];
pub const TEXT_CONTRAST: f64 = 7.0;
pub const OTHER_CONTRAST: f64 = 4.5;

impl SiteSettings {
    pub fn parse(json: &[u8]) -> Result<Self, Invalid> {
        let settings: Self = serde_json::from_slice(json).map_err(|_| Invalid::Title)?;
        settings.check()?;
        Ok(settings)
    }

    pub fn check(&self) -> Result<(), Invalid> {
        if self.title.trim().is_empty() || !safe_line(&self.title, MAX_TITLE) {
            return Err(Invalid::Title);
        }
        if !safe_text(&self.about, MAX_ABOUT) {
            return Err(Invalid::About);
        }
        if self.lang.len() != 2 || !self.lang.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err(Invalid::Lang);
        }
        if !BODY_SIZES.contains(&self.body) {
            return Err(Invalid::Body);
        }
        self.theme.check()
    }
}

impl Theme {
    pub fn check(&self) -> Result<(), Invalid> {
        let grounds = [rgb(&self.background)?, rgb(&self.surface)?];
        let needs = [
            (&self.text, TEXT_CONTRAST),
            (&self.secondary, OTHER_CONTRAST),
            (&self.accent, OTHER_CONTRAST),
            (&self.second_accent, OTHER_CONTRAST),
        ];
        for (colour, ratio) in needs {
            let colour = rgb(colour)?;
            if grounds.iter().any(|ground| contrast(colour, *ground) < ratio) {
                return Err(Invalid::Contrast);
            }
        }
        // A dark theme's text is lighter than its background, a light one's darker.
        if (luminance(rgb(&self.text)?) > luminance(grounds[0])) != self.dark {
            return Err(Invalid::Contrast);
        }
        Ok(())
    }
}

/// `#RRGGBB` in uppercase, exactly as the app writes it (and so as it can
/// go into a stylesheet unescaped).
pub fn rgb(hex: &str) -> Result<[u8; 3], Invalid> {
    let digits = hex.strip_prefix('#').ok_or(Invalid::Colour)?;
    if digits.len() != 6 || !digits.bytes().all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)) {
        return Err(Invalid::Colour);
    }
    let value = u32::from_str_radix(digits, 16).map_err(|_| Invalid::Colour)?;
    Ok([(value >> 16) as u8, (value >> 8) as u8, value as u8])
}

/// WCAG 2 relative luminance.
pub fn luminance(colour: [u8; 3]) -> f64 {
    let linear = |c: u8| {
        let s = f64::from(c) / 255.0;
        if s <= 0.04045 { s / 12.92 } else { ((s + 0.055) / 1.055).powf(2.4) }
    };
    0.2126 * linear(colour[0]) + 0.7152 * linear(colour[1]) + 0.0722 * linear(colour[2])
}

/// WCAG 2 contrast ratio, from 1 to 21.
pub fn contrast(a: [u8; 3], b: [u8; 3]) -> f64 {
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

#[cfg(test)]
pub(crate) fn sample() -> SiteSettings {
    SiteSettings {
        title: "Quaderno di Pietro".into(),
        about: "Racconti e canzoni.".into(),
        lang: "it".into(),
        theme: Theme {
            dark: true,
            background: "#090C15".into(),
            surface: "#13192B".into(),
            text: "#F8FAFC".into(),
            secondary: "#8F9CAE".into(),
            accent: "#EBB448".into(),
            second_accent: "#7FB2F0".into(),
        },
        body: 18,
        home: HomeLayout::Collection,
        indexable: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_modus_theme_passes() {
        assert_eq!(sample().check(), Ok(()));
        let json = serde_json::to_vec(&sample()).unwrap();
        assert_eq!(SiteSettings::parse(&json), Ok(sample()));
    }

    #[test]
    fn contrast_is_wcag() {
        assert!((contrast([0, 0, 0], [255, 255, 255]) - 21.0).abs() < 1e-9);
        assert!((contrast([0x77; 3], [255; 3]) - 4.48).abs() < 0.01);
    }

    #[test]
    fn unreadable_colours_are_refused() {
        let mut s = sample();
        s.theme.secondary = "#3A4150".into();
        assert_eq!(s.check(), Err(Invalid::Contrast));
        let mut s = sample();
        s.theme.text = "#C0C0C0".into(); // 4.5:1 is not enough for body text
        s.theme.text = "#9AA0A8".into();
        assert_eq!(s.check(), Err(Invalid::Contrast));
        let mut s = sample();
        s.theme.dark = false;
        assert_eq!(s.check(), Err(Invalid::Contrast));
    }

    #[test]
    fn colours_must_be_plain_uppercase_hex() {
        for bad in ["090C15", "#090c15", "#090C1", "#090C15;", "red", "#090C15 !important"] {
            let mut s = sample();
            s.theme.background = bad.into();
            assert_eq!(s.check(), Err(Invalid::Colour), "{bad}");
        }
    }

    #[test]
    fn other_fields() {
        let mut s = sample();
        s.title = "  ".into();
        assert_eq!(s.check(), Err(Invalid::Title));
        let mut s = sample();
        s.title = "a\u{202E}b".into();
        assert_eq!(s.check(), Err(Invalid::Title));
        let mut s = sample();
        s.lang = "ita".into();
        assert_eq!(s.check(), Err(Invalid::Lang));
        let mut s = sample();
        s.body = 17;
        assert_eq!(s.check(), Err(Invalid::Body));
        let mut s = sample();
        s.about = "a".repeat(MAX_ABOUT + 1);
        assert_eq!(s.check(), Err(Invalid::About));
        assert_eq!(SiteSettings::parse(br#"{"title":"x","extra":1}"#), Err(Invalid::Title));
    }
}
