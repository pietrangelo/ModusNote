//! The colours of a cookbook's categories. Each category takes the site's
//! accent turned by the golden angle (137.5°) once more than the category
//! before it, in the order the categories first appeared: the hues of
//! sunflower seeds, always far apart, never repeating, and unchanged when a
//! new category comes. Lightness and chroma are then moved in OKLCH until
//! the accent reads on the site's background and surface (4.5:1) and the
//! text reads on the category's tint (7:1), the contrasts the app promises.

use crate::settings::{OTHER_CONTRAST, TEXT_CONTRAST, Theme, contrast, rgb};

/// The golden angle, in degrees.
pub const GOLDEN_ANGLE: f64 = 137.507_764_050_037_85;

/// One category's colours, as `#RRGGBB`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CategoryColours {
    /// Headings, numbers and links of the category.
    pub accent: String,
    /// Its bands and the ground of its pages' boxes.
    pub tint: String,
}

/// The colours of the category that came `order`-th (from 0) on a site
/// with `theme`.
pub fn category(theme: &Theme, order: usize) -> CategoryColours {
    let background = rgb(&theme.background).unwrap_or([0, 0, 0]);
    let surface = rgb(&theme.surface).unwrap_or(background);
    let text = rgb(&theme.text).unwrap_or([255, 255, 255]);
    let [l, c, h] = oklch(rgb(&theme.accent).unwrap_or([128, 128, 128]));
    let hue = (h + GOLDEN_ANGLE * order as f64).rem_euclid(360.0);
    let chroma = c.max(0.12);
    // Darker on a light page, lighter on a dark one, until it reads.
    let direction = if theme.dark { 1.0 } else { -1.0 };
    let mut accent = None;
    for step in 0..=100 {
        let lightness = (l + direction * 0.01 * f64::from(step)).clamp(0.0, 1.0);
        let colour = in_gamut(lightness, chroma, hue);
        if contrast(colour, background) >= OTHER_CONTRAST && contrast(colour, surface) >= OTHER_CONTRAST {
            accent = Some(colour);
            break;
        }
    }
    let accent = accent.unwrap_or(text);
    // The tint is the background leaning toward the hue, as long as the
    // text keeps its contrast on it; else the plain background.
    let [bl, _, _] = oklch(background);
    let lean = if theme.dark { 0.04 } else { -0.03 };
    let tint = [0.035, 0.025, 0.015]
        .into_iter()
        .map(|c| in_gamut((bl + lean).clamp(0.0, 1.0), c, hue))
        .find(|t| contrast(text, *t) >= TEXT_CONTRAST && contrast(accent, *t) >= OTHER_CONTRAST)
        .unwrap_or(background);
    CategoryColours { accent: hex(accent), tint: hex(tint) }
}

fn hex([r, g, b]: [u8; 3]) -> String {
    format!("#{r:02X}{g:02X}{b:02X}")
}

fn to_linear(c: u8) -> f64 {
    let c = f64::from(c) / 255.0;
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn from_linear(c: f64) -> f64 {
    if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

/// sRGB to OKLCH (Björn Ottosson's OKLab), hue in degrees.
pub fn oklch(colour: [u8; 3]) -> [f64; 3] {
    let [r, g, b] = colour.map(to_linear);
    let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
    let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
    let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
    let lightness = 0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s;
    let a = 1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s;
    let bb = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s;
    [lightness, a.hypot(bb), bb.atan2(a).to_degrees().rem_euclid(360.0)]
}

/// OKLCH to linear sRGB, unclamped.
fn linear(l: f64, c: f64, h: f64) -> [f64; 3] {
    let (a, b) = (c * h.to_radians().cos(), c * h.to_radians().sin());
    let l_ = (l + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
    let m_ = (l - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
    let s_ = (l - 0.089_484_177_5 * a - 1.291_485_548 * b).powi(3);
    [
        4.076_741_662_1 * l_ - 3.307_711_591_3 * m_ + 0.230_969_929_2 * s_,
        -1.268_438_004_6 * l_ + 2.609_757_401_1 * m_ - 0.341_319_396_5 * s_,
        -0.004_196_086_3 * l_ - 0.703_418_614_7 * m_ + 1.707_614_701 * s_,
    ]
}

/// The colour at `l`, `h` with the most chroma up to `c` that sRGB shows.
fn in_gamut(l: f64, c: f64, h: f64) -> [u8; 3] {
    let mut chroma = c;
    loop {
        let rgb = linear(l, chroma, h);
        if rgb.iter().all(|v| (-1e-4..=1.0 + 1e-4).contains(v)) || chroma <= 0.0 {
            return rgb.map(|v| (from_linear(v.clamp(0.0, 1.0)) * 255.0).round() as u8);
        }
        chroma -= 0.005;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresco(dark: bool) -> Theme {
        if dark {
            Theme {
                dark: true,
                background: "#13161D".into(),
                surface: "#1B1F28".into(),
                text: "#F4F1EA".into(),
                secondary: "#AFA899".into(),
                accent: "#E6905A".into(),
                second_accent: "#C9A0E8".into(),
            }
        } else {
            Theme {
                dark: false,
                background: "#FBF8F1".into(),
                surface: "#FFFFFF".into(),
                text: "#1D1A16".into(),
                secondary: "#5E574C".into(),
                accent: "#A9461B".into(),
                second_accent: "#6B3FA0".into(),
            }
        }
    }

    #[test]
    fn oklch_round_trips() {
        for colour in [[0, 0, 0], [255, 255, 255], [235, 180, 72], [139, 63, 214], [0, 163, 255]] {
            let [l, c, h] = oklch(colour);
            assert_eq!(in_gamut(l, c, h), colour, "{colour:?}");
        }
    }

    #[test]
    fn every_category_reads_on_both_frescos() {
        for dark in [false, true] {
            let theme = fresco(dark);
            let ground = rgb(&theme.background).unwrap();
            let surface = rgb(&theme.surface).unwrap();
            let text = rgb(&theme.text).unwrap();
            for order in 0..21 {
                let c = category(&theme, order);
                let accent = rgb(&c.accent).unwrap();
                let tint = rgb(&c.tint).unwrap();
                assert!(contrast(accent, ground) >= OTHER_CONTRAST, "{dark} {order} {c:?}");
                assert!(contrast(accent, surface) >= OTHER_CONTRAST, "{dark} {order} {c:?}");
                assert!(contrast(accent, tint) >= OTHER_CONTRAST, "{dark} {order} {c:?}");
                assert!(contrast(text, tint) >= TEXT_CONTRAST, "{dark} {order} {c:?}");
            }
        }
    }

    #[test]
    fn hues_turn_by_the_golden_angle_and_stay_apart() {
        let theme = fresco(false);
        let hues: Vec<f64> = (0..8).map(|n| oklch(rgb(&category(&theme, n).accent).unwrap())[2]).collect();
        let base = oklch(rgb(&theme.accent).unwrap())[2];
        assert!((hues[0] - base).abs() < 6.0, "{hues:?}");
        for (i, a) in hues.iter().enumerate() {
            for b in &hues[i + 1..] {
                let apart = (a - b).abs().min(360.0 - (a - b).abs());
                assert!(apart > 12.0, "{hues:?}");
            }
        }
        // A new category never changes the colours of the ones before.
        assert_eq!(category(&theme, 3), category(&theme, 3));
    }
}
