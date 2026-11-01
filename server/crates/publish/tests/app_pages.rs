//! Pages as the app writes them: `fixtures/app_recipe.json` is what the
//! Dart `PageComposer` makes of a recipe note, checked byte for byte by the
//! app's own tests (packages/publishing/test/recipe_layout_test.dart), so
//! the two sides of the wire cannot drift apart unnoticed.

use publish::page::{Layout, Page};

const APP_RECIPE: &[u8] = include_bytes!("fixtures/app_recipe.json");

#[test]
fn the_apps_recipe_is_a_valid_page() {
    let page = Page::parse(APP_RECIPE).expect("the app's page");
    assert_eq!(page.layout, Layout::Recipe);
    let recipe = page.recipe.as_ref().expect("a recipe");
    assert_eq!(recipe.category, "Secondi");
    assert_eq!(recipe.servings, Some(4));
    assert_eq!((recipe.prep, recipe.cook, recipe.rest), (Some(40), Some(45), Some(0)));
    assert_eq!(recipe.total(), Some(85));
    assert_eq!(recipe.methods, ["Forno", "Fornelli"]);
    assert_eq!(recipe.difficulty, Some(2));
    assert_eq!(recipe.cover.len(), 2);
    assert_eq!(recipe.steps.len(), 2);
    assert_eq!(page.blocks.len(), 2);
}

#[test]
fn the_apps_amounts_scale_with_their_units() {
    let page = Page::parse(APP_RECIPE).unwrap();
    let recipe = page.recipe.unwrap();
    let lines: Vec<String> = recipe.ingredients.iter().map(|i| i.scaled(4, 8).line("it")).collect();
    assert_eq!(lines, ["3 kg Melanzane", "4 cucchiai, abbondanti Olio", "6 Uova", "q.b. Sale"]);
    let one: Vec<String> = recipe.ingredients.iter().map(|i| i.scaled(4, 2).line("it")).collect();
    assert_eq!(one[1], "1 cucchiaio, abbondanti Olio");
}
