//! The API of serv.pub's sites: routes, the proof of work of a claim, and a
//! site's object serving signed writes and public reads.

#[path = "../../crates/sync/tests/support/mod.rs"]
mod support;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use crypto::StrictEd25519;
use modusnote_server::api::{ApiError, Route, route};
use modusnote_server::serve::{
    self, Blake2b, INTERNAL_COOKBOOK, INTERNAL_FEED, INTERNAL_HOME, INTERNAL_MEDIA, INTERNAL_STYLE, Incoming, SiteDone,
};
use publish::{MediaType, Site};
use serde_json::json;
use support::*;
use sync::{MemoryStore, PowPurpose, pow_satisfied};

const PIC: &str = "AAAAAAAAAAAAAAAA";

fn send<'a>(signed: &'a Call, body: &'a [u8], blob_size: Option<&'a str>) -> Incoming<'a> {
    let (path, query) = match signed.path.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (signed.path.as_str(), None),
    };
    Incoming {
        method: &signed.method,
        path,
        query,
        authorization: signed.header.as_deref(),
        body,
        blob_size,
        upgrade: None,
        protocols: None,
        now_ms: NOW,
    }
}

fn read(path: &str) -> Incoming<'_> {
    Incoming {
        method: "GET",
        path,
        query: None,
        authorization: None,
        body: b"",
        blob_size: None,
        upgrade: None,
        protocols: None,
        now_ms: NOW,
    }
}

fn settings() -> serde_json::Value {
    json!({"title": "Quaderno", "about": "", "lang": "it", "body": 18, "home": "collection", "indexable": false,
        "theme": {"dark": true, "background": "#090C15", "surface": "#13192B", "text": "#F8FAFC",
            "secondary": "#8F9CAE", "accent": "#EBB448", "second_accent": "#7FB2F0"}})
}

/// A starting point for the proof of work, never a literal: CodeQL takes any
/// constant array that reaches a nonce for a hard-coded secret.
fn seed() -> [u8; 16] {
    crypto::blake2b_256(b"servpub test pow")[..16].try_into().unwrap()
}

fn claim_body(nonce: &[u8; 16], day: u32) -> Vec<u8> {
    json!({"settings": settings(), "pow": {"day": day, "nonce": STANDARD.encode(nonce)}}).to_string().into_bytes()
}

#[test]
fn site_routes() {
    let r = |m: &str, p: &str, q: Option<&str>| route(m, p, q);
    assert_eq!(r("POST", "/api/s/quaderno", None), Ok(Route::ClaimSite("quaderno".into())));
    assert_eq!(r("PUT", "/api/s/quaderno", None), Ok(Route::PutSettings("quaderno".into())));
    assert_eq!(r("DELETE", "/api/s/quaderno", None), Ok(Route::DeleteSite("quaderno".into())));
    assert_eq!(r("PUT", "/api/s/quaderno/p/il-faro", None), Ok(Route::PutPage("quaderno".into(), "il-faro".into())));
    assert_eq!(
        r("DELETE", "/api/s/quaderno/p/il-faro", None),
        Ok(Route::DeletePage("quaderno".into(), "il-faro".into()))
    );
    assert_eq!(
        r("PUT", &format!("/api/s/quaderno/m/{PIC}"), Some("type=webp")),
        Ok(Route::PutMedia("quaderno".into(), PIC.into(), "webp".into()))
    );
    assert_eq!(
        r("DELETE", &format!("/api/s/quaderno/m/{PIC}"), None),
        Ok(Route::DeleteMedia("quaderno".into(), PIC.into()))
    );
    // Names, slugs, ids and types by the rules; nothing else.
    for bad in ["/api/s/ab", "/api/s/api", "/api/s/Quaderno", "/api/s/quaderno/p/Il_Faro", "/api/s/quaderno/x/y"] {
        assert_eq!(r("PUT", bad, None), Err(ApiError::NotFound), "{bad}");
    }
    assert_eq!(r("PUT", &format!("/api/s/quaderno/m/{PIC}"), Some("type=svg")), Err(ApiError::NotFound));
    assert_eq!(r("PUT", &format!("/api/s/quaderno/m/{PIC}"), None), Err(ApiError::NotFound));
    assert_eq!(r("PUT", "/api/s/quaderno", Some("x=1")), Err(ApiError::NotFound));
    assert_eq!(r("GET", "/api/s/quaderno/p/il-faro", None), Err(ApiError::MethodNotAllowed));
    let claim = Route::ClaimSite("quaderno".into());
    assert!(claim.writes() && claim.takes_json() && claim.site() == Some("quaderno"));
    assert!(!Route::PutMedia("q".into(), PIC.into(), "png".into()).takes_json(), "streamed, not JSON");
}

#[test]
fn claiming_costs_a_proof_of_work_for_that_name() {
    const BITS: u32 = 8;
    let day = (NOW / 86_400_000) as u32;
    let mut nonce = seed();
    while !pow_satisfied(&Blake2b, PowPurpose::Site, b"quaderno", day, &nonce, BITS) {
        nonce[0] = nonce[0].wrapping_add(1);
        nonce[1] = nonce[1].wrapping_add(u8::from(nonce[0] == 0));
    }
    let claim = Route::ClaimSite("quaderno".into());
    assert_eq!(serve::admit(&claim, &claim_body(&nonce, day), &Blake2b, NOW, BITS), Ok(()));
    let other = Route::ClaimSite("altro-nome".into());
    assert_eq!(serve::admit(&other, &claim_body(&nonce, day), &Blake2b, NOW, BITS), Err(ApiError::Work));
    assert_eq!(serve::admit(&claim, &claim_body(&nonce, day - 2), &Blake2b, NOW, BITS), Err(ApiError::Work));
}

#[test]
fn a_site_object_serves_writes_and_reads() {
    let owner = Device::new(1);
    let stranger = Device::new(2);
    let mut site = Site::new("quaderno", MemoryStore::default(), StrictEd25519);
    let body = claim_body(&seed(), 0);
    let signed = call(&owner, "POST", "/api/s/quaderno", &body);
    assert_eq!(
        serve::site(&mut site, &Blake2b, &send(&signed, &body, None)),
        Ok(SiteDone::Json(201, r#"{"created":true}"#.into()))
    );

    let path = format!("/api/s/quaderno/m/{PIC}?type=png");
    let signed = call(&owner, "PUT", &path, b"");
    assert_eq!(
        serve::site(&mut site, &Blake2b, &send(&signed, b"", Some("1234"))),
        Ok(SiteDone::Json(200, "{}".into()))
    );
    let page = json!({"title": "Il faro", "layout": "golden_section", "listed": true, "blocks": [
        {"kind": "markdown", "label": "", "text": format!("Luce ![faro](image:{PIC})")},
        {"kind": "text", "label": "Luogo", "text": "Capo Testa"}]})
    .to_string()
    .into_bytes();
    let signed = call(&stranger, "PUT", "/api/s/quaderno/p/il-faro", &page);
    assert_eq!(serve::site(&mut site, &Blake2b, &send(&signed, &page, None)), Err(ApiError::Forbidden));
    let signed = call(&owner, "PUT", "/api/s/quaderno/p/il-faro", &page);
    assert_eq!(
        serve::site(&mut site, &Blake2b, &send(&signed, &page, None)),
        Ok(SiteDone::Json(201, r#"{"created":true}"#.into()))
    );

    let Ok(SiteDone::Html(html)) = serve::site(&mut site, &Blake2b, &read("/internal/page/il-faro")) else {
        panic!("a page")
    };
    assert!(html.contains("<aside>") && html.contains("Capo Testa"));
    assert!(html.contains(&format!(r#"<img src="/quaderno/m/{PIC}""#)));
    let Ok(SiteDone::Html(home)) = serve::site(&mut site, &Blake2b, &read(INTERNAL_HOME)) else { panic!("home") };
    assert!(home.contains("/quaderno/il-faro"));
    assert!(matches!(serve::site(&mut site, &Blake2b, &read(INTERNAL_STYLE)), Ok(SiteDone::Css(_))));
    let Ok(SiteDone::Feed(feed)) = serve::site(&mut site, &Blake2b, &read(INTERNAL_FEED)) else { panic!("feed") };
    assert!(feed.contains("<id>https://serv.pub/quaderno/il-faro</id>"));
    assert!(feed.contains("<summary>Luce</summary>"), "{feed}");
    assert!(html.contains(&format!(r#"<meta property="og:image" content="https://serv.pub/quaderno/m/{PIC}">"#)));
    let media = format!("{INTERNAL_MEDIA}{PIC}");
    assert_eq!(serve::site(&mut site, &Blake2b, &read(&media)), Ok(SiteDone::MediaType(MediaType::Png)));
    assert_eq!(serve::site(&mut site, &Blake2b, &read("/internal/page/nessuna")), Err(ApiError::NotFound));
    assert_eq!(serve::site(&mut site, &Blake2b, &read("/internal/other")), Err(ApiError::NotFound));
    assert_eq!(serve::site(&mut site, &Blake2b, &read(INTERNAL_COOKBOOK)), Err(ApiError::NotFound), "no recipes yet");

    let recipe = json!({"title": "Pane", "layout": "recipe", "listed": true, "blocks": [], "recipe": {
        "category": "Lievitati", "servings": 2, "cover": [{"media": PIC}],
        "ingredients": [{"name": "Farina", "amount": 500, "unit": "gram", "one": "g", "other": "g"}],
        "steps": [{"text": "Impasta."}]}})
    .to_string()
    .into_bytes();
    let signed = call(&owner, "PUT", "/api/s/quaderno/p/pane", &recipe);
    assert_eq!(
        serve::site(&mut site, &Blake2b, &send(&signed, &recipe, None)),
        Ok(SiteDone::Json(201, r#"{"created":true}"#.into()))
    );
    let query = |path: &'static str, query: &'static str| Incoming { query: Some(query), ..read(path) };
    let Ok(SiteDone::Html(cookbook)) = serve::site(&mut site, &Blake2b, &query(INTERNAL_COOKBOOK, "q=pane")) else {
        panic!("a search")
    };
    assert!(cookbook.contains("/quaderno/pane") && cookbook.contains("noindex"));
    let Ok(SiteDone::Html(category)) = serve::site(&mut site, &Blake2b, &read("/internal/cookbook/lievitati")) else {
        panic!("a category")
    };
    assert!(category.contains("<h1>Lievitati</h1>"));
    let Ok(SiteDone::Html(pane)) = serve::site(&mut site, &Blake2b, &query("/internal/page/pane", "p=4")) else {
        panic!("a recipe")
    };
    assert!(pane.contains("1000 g"), "{pane}");

    let signed = call(&owner, "DELETE", "/api/s/quaderno", b"");
    assert_eq!(serve::site(&mut site, &Blake2b, &send(&signed, b"", None)), Ok(SiteDone::Json(200, "{}".into())));
    assert_eq!(serve::site(&mut site, &Blake2b, &read(INTERNAL_HOME)), Err(ApiError::NotFound));
}
