//! A recipe on a page: what the app's `recipe` note says, structured so the
//! server can scale its amounts for other servings, list it in the site's
//! cookbook and describe it to search engines. Labels of units come from
//! the app in the reader's language; everything here is checked as
//! strictly as the rest of a page.

use serde::{Deserialize, Serialize};

use crate::names::media_id;
use crate::page::{Invalid, web_url};
use crate::text::{safe_line, safe_text};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Recipe {
    /// The person's own category («Primi», «Pane»), or empty.
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub description: String,
    /// The presentation photos, the first one is the cover.
    #[serde(default)]
    pub cover: Vec<Picture>,
    #[serde(default)]
    pub servings: Option<u16>,
    /// Minutes.
    #[serde(default)]
    pub prep: Option<u32>,
    #[serde(default)]
    pub cook: Option<u32>,
    #[serde(default)]
    pub rest: Option<u32>,
    /// Ways of cooking, already in the reader's language («Forno»).
    #[serde(default)]
    pub methods: Vec<String>,
    /// 1 easy, 2 medium, 3 hard.
    #[serde(default)]
    pub difficulty: Option<u8>,
    #[serde(default)]
    pub ingredients: Vec<Ingredient>,
    #[serde(default)]
    pub steps: Vec<Step>,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Picture {
    pub media: String,
    #[serde(default)]
    pub caption: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ingredient {
    pub name: String,
    #[serde(default)]
    pub amount: Option<f64>,
    #[serde(default)]
    pub unit: Option<Unit>,
    /// The unit's name for one and for any other amount («cucchiaio»,
    /// «cucchiai»); empty for things counted.
    #[serde(default)]
    pub one: String,
    #[serde(default)]
    pub other: String,
    /// Words beside or instead of the amount («q.b.», «abbondante»).
    #[serde(default)]
    pub quantity: String,
    /// Where to buy it: `https` only.
    #[serde(default)]
    pub link: Option<String>,
}

/// The app's `IngredientUnit`: what decides how a scaled amount rounds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Unit {
    Gram,
    Kilogram,
    Millilitre,
    Centilitre,
    Decilitre,
    Litre,
    Teaspoon,
    Tablespoon,
    Cup,
    Piece,
    Slice,
    Clove,
    Pinch,
    Ounce,
    Pound,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Step {
    /// Markdown, rendered like a note's.
    pub text: String,
    #[serde(default)]
    pub pictures: Vec<Picture>,
}

/// The app's limits (`IngredientsFieldType`, `StepsFieldType`, recipe v1).
pub const MAX_CATEGORY: usize = 89;
pub const MAX_DESCRIPTION: usize = 2584;
pub const MAX_COVER: usize = 13;
pub const MAX_SERVINGS: u16 = 100;
pub const MAX_MINUTES: u32 = 10_080;
pub const MAX_METHODS: usize = 13;
pub const MAX_INGREDIENTS: usize = 233;
pub const MAX_NAME: usize = 200;
pub const MAX_UNIT: usize = 34;
pub const MAX_QUANTITY: usize = 80;
pub const MAX_AMOUNT: f64 = 1e6;
pub const MAX_STEPS: usize = 89;
pub const MAX_STEP: usize = 10_000;
pub const MAX_STEP_PICTURES: usize = 8;
pub const MAX_PICTURES: usize = 89;
pub const MAX_TAGS: usize = 89;
pub const MAX_TAG: usize = 89;

impl Recipe {
    pub fn check(&self) -> Result<(), Invalid> {
        let line = |s: &str, max: usize| if safe_line(s, max) { Ok(()) } else { Err(Invalid::Item) };
        line(&self.category, MAX_CATEGORY)?;
        if !safe_text(&self.description, MAX_DESCRIPTION) {
            return Err(Invalid::Text);
        }
        if self.cover.len() > MAX_COVER {
            return Err(Invalid::Item);
        }
        self.cover.iter().try_for_each(Picture::check)?;
        if self.servings.is_some_and(|n| n == 0 || n > MAX_SERVINGS) {
            return Err(Invalid::Item);
        }
        if [self.prep, self.cook, self.rest].iter().flatten().any(|m| *m > MAX_MINUTES) {
            return Err(Invalid::Item);
        }
        if self.methods.len() > MAX_METHODS || self.methods.iter().any(|m| m.trim().is_empty()) {
            return Err(Invalid::Item);
        }
        self.methods.iter().try_for_each(|m| line(m, MAX_CATEGORY))?;
        if self.difficulty.is_some_and(|d| !(1..=3).contains(&d)) {
            return Err(Invalid::Item);
        }
        if self.ingredients.len() > MAX_INGREDIENTS {
            return Err(Invalid::Item);
        }
        self.ingredients.iter().try_for_each(Ingredient::check)?;
        if self.steps.len() > MAX_STEPS {
            return Err(Invalid::Item);
        }
        self.steps.iter().try_for_each(Step::check)?;
        if self.steps.iter().map(|s| s.pictures.len()).sum::<usize>() > MAX_PICTURES {
            return Err(Invalid::Item);
        }
        if self.tags.len() > MAX_TAGS || self.tags.iter().any(|t| t.trim().is_empty()) {
            return Err(Invalid::Item);
        }
        self.tags.iter().try_for_each(|t| line(t, MAX_TAG))
    }

    /// Every file the recipe shows, in order: cover, then each step's
    /// pictures and the pictures its text names.
    pub fn media(&self) -> Vec<String> {
        let mut out: Vec<String> = self.cover.iter().map(|p| p.media.clone()).collect();
        for step in &self.steps {
            out.extend(step.pictures.iter().map(|p| p.media.clone()));
            out.extend(crate::render::images_in(&step.text));
        }
        out
    }

    /// Preparation, cooking and rest together; None when none is given.
    pub fn total(&self) -> Option<u32> {
        let times: Vec<u32> = [self.prep, self.cook, self.rest].into_iter().flatten().collect();
        (!times.is_empty()).then(|| times.iter().sum())
    }
}

impl Picture {
    fn check(&self) -> Result<(), Invalid> {
        if !media_id(&self.media) {
            return Err(Invalid::Media);
        }
        if safe_line(&self.caption, crate::page::MAX_SHORT) { Ok(()) } else { Err(Invalid::Item) }
    }
}

impl Ingredient {
    fn check(&self) -> Result<(), Invalid> {
        if self.name.trim().is_empty() || !safe_line(&self.name, MAX_NAME) {
            return Err(Invalid::Item);
        }
        if let Some(amount) = self.amount
            && !(amount.is_finite() && amount > 0.0 && amount <= MAX_AMOUNT)
        {
            return Err(Invalid::Item);
        }
        if self.unit.is_some() && self.amount.is_none() {
            return Err(Invalid::Item);
        }
        if !safe_line(&self.one, MAX_UNIT) || !safe_line(&self.other, MAX_UNIT) {
            return Err(Invalid::Item);
        }
        if !safe_line(&self.quantity, MAX_QUANTITY) {
            return Err(Invalid::Item);
        }
        match &self.link {
            Some(url) if !(url.starts_with("https://") && web_url(url)) => Err(Invalid::Url),
            _ => Ok(()),
        }
    }

    /// The same ingredient for `to` servings instead of `from`.
    pub fn scaled(&self, from: u16, to: u16) -> Self {
        match self.amount {
            Some(amount) if from != to && from > 0 && to > 0 => {
                Self { amount: Some(measurable(amount * f64::from(to) / f64::from(from), self.unit)), ..self.clone() }
            }
            _ => self.clone(),
        }
    }

    /// How much, as the app writes it: «250 g», «2», «1,5 cucchiai, rasi»,
    /// «q.b.»; empty when it says nothing.
    pub fn how_much(&self, lang: &str) -> String {
        let measured = match self.amount {
            Some(amount) => {
                let unit = if amount == 1.0 { &self.one } else { &self.other };
                let number = number(amount, lang);
                if unit.is_empty() { number } else { format!("{number} {unit}") }
            }
            None => String::new(),
        };
        [measured.as_str(), self.quantity.trim()]
            .iter()
            .filter(|p| !p.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// One line: how much, then the name.
    pub fn line(&self, lang: &str) -> String {
        let how = self.how_much(lang);
        if how.is_empty() { self.name.trim().to_owned() } else { format!("{how} {}", self.name.trim()) }
    }
}

impl Step {
    fn check(&self) -> Result<(), Invalid> {
        if self.text.trim().is_empty() && self.pictures.is_empty() {
            return Err(Invalid::Item);
        }
        if !safe_text(&self.text, MAX_STEP) || self.pictures.len() > MAX_STEP_PICTURES {
            return Err(Invalid::Text);
        }
        self.pictures.iter().try_for_each(Picture::check)
    }
}

/// What a cook can measure, as the app's `Recipe.scale` rounds: things
/// counted by halves, spoons and cups by quarters, weights and volumes by
/// tenths under 10, by one up to 100 and by five above; never less than
/// the smallest step.
pub fn measurable(amount: f64, unit: Option<Unit>) -> f64 {
    let step = match unit {
        None | Some(Unit::Piece | Unit::Slice | Unit::Clove | Unit::Pinch) => 0.5,
        Some(Unit::Teaspoon | Unit::Tablespoon | Unit::Cup) => 0.25,
        _ if amount < 10.0 => 0.1,
        _ if amount < 100.0 => 1.0,
        _ => 5.0,
    };
    // Dart's round() takes halves away from zero, as Rust's does.
    let steps = (amount / step).round().max(1.0);
    (steps * step * 100.0).round() / 100.0
}

/// `value` with at most two decimals, none when whole, and the decimal
/// sign of `lang` (a comma in Italian and most of Europe).
pub fn number(value: f64, lang: &str) -> String {
    let text = format!("{:.2}", (value * 100.0).round() / 100.0);
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if matches!(lang, "en" | "ja" | "zh" | "ko" | "he" | "th") { text.to_owned() } else { text.replace('.', ",") }
}

/// `text` lowercased and without accents, for search and addresses: «Crème
/// brûlée» is «creme brulee».
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars().flat_map(char::to_lowercase) {
        let plain = match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
            'æ' => "ae",
            'ç' | 'ć' | 'č' => "c",
            'ď' | 'đ' => "d",
            'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => "e",
            'ğ' => "g",
            'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
            'ł' | 'ľ' => "l",
            'ñ' | 'ń' | 'ň' => "n",
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
            'œ' => "oe",
            'ř' => "r",
            'ś' | 'š' | 'ş' => "s",
            'ß' => "ss",
            'ť' | 'ţ' => "t",
            'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
            'ý' | 'ÿ' => "y",
            'ź' | 'ż' | 'ž' => "z",
            '\u{0300}'..='\u{036F}' => "",
            _ => {
                out.push(c);
                continue;
            }
        };
        out.push_str(plain);
    }
    out
}

/// A category's address in the cookbook: its name folded to ASCII letters
/// and digits joined by hyphens, at most 55 characters; «categoria» when
/// nothing is left of it.
pub fn category_slug(name: &str) -> String {
    let folded = fold(name);
    let mut slug = String::new();
    for word in folded.split(|c: char| !c.is_ascii_alphanumeric()).filter(|w| !w.is_empty()) {
        if slug.len() + word.len() + 1 > 55 {
            break;
        }
        if !slug.is_empty() {
            slug.push('-');
        }
        slug.push_str(word);
    }
    if slug.is_empty() { "categoria".to_owned() } else { slug }
}

/// `minutes` as «45 min», «2 h», «1 h 15 min».
pub fn duration(minutes: u32) -> String {
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

/// `minutes` as an ISO 8601 duration, for schema.org: `PT1H15M`.
pub fn iso_duration(minutes: u32) -> String {
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("PT{m}M"),
        (h, 0) => format!("PT{h}H"),
        (h, m) => format!("PT{h}H{m}M"),
    }
}

#[cfg(test)]
pub(crate) fn sample() -> Recipe {
    Recipe {
        category: "Verdure".into(),
        description: "Strati di melanzane, pomodoro e basilico.".into(),
        cover: vec![Picture { media: "CCCCCCCCCCCCCCCC".into(), caption: String::new() }],
        servings: Some(6),
        prep: Some(40),
        cook: Some(45),
        rest: Some(15),
        methods: vec!["Forno".into(), "Fornello".into()],
        difficulty: Some(2),
        ingredients: vec![
            Ingredient {
                name: "Melanzane".into(),
                amount: Some(1.5),
                unit: Some(Unit::Kilogram),
                one: "kg".into(),
                other: "kg".into(),
                quantity: String::new(),
                link: None,
            },
            Ingredient {
                name: "Passata".into(),
                amount: Some(700.0),
                unit: Some(Unit::Millilitre),
                one: "ml".into(),
                other: "ml".into(),
                quantity: String::new(),
                link: Some("https://esempio.it/passata".into()),
            },
            Ingredient {
                name: "Olio".into(),
                amount: Some(1.0),
                unit: Some(Unit::Tablespoon),
                one: "cucchiaio".into(),
                other: "cucchiai".into(),
                quantity: "abbondante".into(),
                link: None,
            },
            Ingredient {
                name: "Uova".into(),
                amount: Some(3.0),
                unit: None,
                one: String::new(),
                other: String::new(),
                quantity: String::new(),
                link: None,
            },
            Ingredient {
                name: "Sale".into(),
                amount: None,
                unit: None,
                one: String::new(),
                other: String::new(),
                quantity: "q.b.".into(),
                link: None,
            },
        ],
        steps: vec![
            Step {
                text: "Taglia le melanzane e lasciale scolare **30 minuti**.".into(),
                pictures: vec![Picture { media: "DDDDDDDDDDDDDDDD".into(), caption: "Fette".into() }],
            },
            Step { text: "Inforna a 180 °C per 45 minuti.".into(), pictures: vec![] },
        ],
        tags: vec!["estate".into()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sample_recipe_passes_and_lists_its_files() {
        assert_eq!(sample().check(), Ok(()));
        assert_eq!(sample().media(), ["CCCCCCCCCCCCCCCC", "DDDDDDDDDDDDDDDD"]);
        assert_eq!(sample().total(), Some(100));
        assert_eq!(Recipe::default().total(), None);
    }

    #[test]
    fn hostile_recipes_are_refused() {
        let with = |f: &dyn Fn(&mut Recipe)| {
            let mut r = sample();
            f(&mut r);
            r.check()
        };
        let ingredient = |f: &dyn Fn(&mut Ingredient)| with(&|r| f(&mut r.ingredients[0]));
        assert_eq!(with(&|r| r.category = "a\u{202E}b".into()), Err(Invalid::Item));
        assert_eq!(with(&|r| r.servings = Some(0)), Err(Invalid::Item));
        assert_eq!(with(&|r| r.servings = Some(101)), Err(Invalid::Item));
        assert_eq!(with(&|r| r.cook = Some(MAX_MINUTES + 1)), Err(Invalid::Item));
        assert_eq!(with(&|r| r.difficulty = Some(4)), Err(Invalid::Item));
        assert_eq!(with(&|r| r.methods.push(" ".into())), Err(Invalid::Item));
        assert_eq!(with(&|r| r.cover[0].media = "../x".into()), Err(Invalid::Media));
        assert_eq!(with(&|r| r.steps[0].pictures[0].media = "x".into()), Err(Invalid::Media));
        assert_eq!(with(&|r| r.steps.push(Step { text: " ".into(), pictures: vec![] })), Err(Invalid::Item));
        assert_eq!(with(&|r| r.steps[0].text = "a\rb".into()), Err(Invalid::Text));
        assert_eq!(with(&|r| r.ingredients = vec![sample().ingredients[0].clone(); 234]), Err(Invalid::Item));
        for bad in [f64::NAN, f64::INFINITY, 0.0, -1.0, 1e7] {
            assert_eq!(ingredient(&|i| i.amount = Some(bad)), Err(Invalid::Item), "{bad}");
        }
        assert_eq!(ingredient(&|i| i.amount = None), Err(Invalid::Item), "a unit without an amount");
        assert_eq!(ingredient(&|i| i.name = String::new()), Err(Invalid::Item));
        assert_eq!(ingredient(&|i| i.one = "<".repeat(35)), Err(Invalid::Item));
        for url in ["http://esempio.it", "javascript:alert(1)", "https://u@evil", "https://x.org/\"a"] {
            assert_eq!(ingredient(&|i| i.link = Some(url.into())), Err(Invalid::Url), "{url}");
        }
        let many = vec![Picture { media: "DDDDDDDDDDDDDDDD".into(), caption: String::new() }; 8];
        assert_eq!(
            with(&|r| r.steps = vec![Step { text: "x".into(), pictures: many.clone() }; 12]),
            Err(Invalid::Item)
        );
    }

    #[test]
    fn amounts_scale_and_round_as_the_app_does() {
        assert_eq!(measurable(2.3000000000000003, Some(Unit::Gram)), 2.3);
        assert_eq!(measurable(63.4, Some(Unit::Gram)), 63.0);
        assert_eq!(measurable(466.67, Some(Unit::Gram)), 465.0);
        assert_eq!(measurable(1.33, Some(Unit::Tablespoon)), 1.25);
        assert_eq!(measurable(0.1, Some(Unit::Teaspoon)), 0.25);
        assert_eq!(measurable(1.33, None), 1.5);
        assert_eq!(measurable(0.2, Some(Unit::Clove)), 0.5);
        let r = sample();
        let at = |i: usize, to| r.ingredients[i].scaled(6, to).amount;
        assert_eq!(at(0, 7), Some(1.8));
        assert_eq!(at(1, 7), Some(815.0));
        assert_eq!(at(3, 4), Some(2.0));
        assert_eq!(at(4, 9), None);
        assert_eq!(r.ingredients[1].scaled(6, 6), r.ingredients[1]);
    }

    #[test]
    fn lines_read_as_in_the_app() {
        let r = sample();
        assert_eq!(r.ingredients[0].line("it"), "1,5 kg Melanzane");
        assert_eq!(r.ingredients[0].line("en"), "1.5 kg Melanzane");
        assert_eq!(r.ingredients[2].line("it"), "1 cucchiaio, abbondante Olio");
        assert_eq!(r.ingredients[2].scaled(6, 12).line("it"), "2 cucchiai, abbondante Olio");
        assert_eq!(r.ingredients[3].line("it"), "3 Uova");
        assert_eq!(r.ingredients[4].line("it"), "q.b. Sale");
        assert_eq!(number(1500.0, "it"), "1500");
        assert_eq!(number(0.25, "it"), "0,25");
    }

    #[test]
    fn folding_and_category_addresses() {
        assert_eq!(fold("Crème Brûlée"), "creme brulee");
        assert_eq!(fold("PERCHÉ"), "perche");
        assert_eq!(category_slug("Pane e lievitati"), "pane-e-lievitati");
        assert_eq!(category_slug("  Dolci & torte!! "), "dolci-torte");
        assert_eq!(category_slug("🍝🍝"), "categoria");
        assert!(category_slug(&"parola ".repeat(20)).len() <= 55);
        assert!(crate::names::page_slug(&category_slug("Antipasti, salse e sughi")));
    }

    #[test]
    fn durations() {
        assert_eq!(duration(45), "45 min");
        assert_eq!(duration(120), "2 h");
        assert_eq!(duration(75), "1 h 15 min");
        assert_eq!(iso_duration(75), "PT1H15M");
        assert_eq!(iso_duration(0), "PT0M");
    }
}
