//! A site's use cases with real signatures, as the app will sign them.

use crypto::{StrictEd25519, blake2b_256};
use ed25519_dalek::{Signer, SigningKey};
use publish::{MediaType, Site, SiteError, SiteLimits};
use sync::{Denied, MemoryStore, Request};

const NOW: u64 = 1_792_700_000_000;
const PIC: &str = "AAAAAAAAAAAAAAAA";

struct Call {
    method: String,
    path: String,
    header: String,
    digest: [u8; 32],
    now: u64,
}

impl Call {
    fn request(&self) -> Request<'_> {
        Request {
            method: &self.method,
            path: &self.path,
            authorization: Some(&self.header),
            body_digest: self.digest,
            now_ms: self.now,
        }
    }
}

static NONCE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

fn b64(bytes: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

fn call(by: &SigningKey, method: &str, path: &str, body: &[u8], now: u64) -> Call {
    let digest = blake2b_256(body);
    let mut nonce = [0u8; 16];
    nonce[0] = NONCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    nonce[1] = 0x5e;
    let key = by.verifying_key().to_bytes();
    let signable = ledger::signable_request(method, path, now, &nonce, &digest).unwrap();
    let signature = by.sign(&signable).to_bytes();
    Call {
        method: method.into(),
        path: path.into(),
        header: format!("MN1 {}.{now}.{}.{}", b64(&key), b64(&nonce), b64(&signature)),
        digest,
        now,
    }
}

fn settings(title: &str) -> Vec<u8> {
    format!(
        r##"{{"title":"{title}","about":"","lang":"it","body":18,"home":"collection","indexable":false,
        "theme":{{"dark":true,"background":"#090C15","surface":"#13192B","text":"#F8FAFC","secondary":"#8F9CAE",
        "accent":"#EBB448","second_accent":"#7FB2F0"}}}}"##
    )
    .into_bytes()
}

fn page(title: &str, text: &str) -> Vec<u8> {
    serde_json::json!({
        "title": title, "layout": "essay", "listed": true,
        "blocks": [{"kind": "markdown", "label": "", "text": text}]
    })
    .to_string()
    .into_bytes()
}

fn owner() -> SigningKey {
    SigningKey::from_bytes(&[7; 32])
}

fn stranger() -> SigningKey {
    SigningKey::from_bytes(&[9; 32])
}

fn claimed() -> Site<MemoryStore, StrictEd25519> {
    let mut site = Site::new("quaderno", MemoryStore::default(), StrictEd25519);
    let body = settings("Quaderno");
    assert_eq!(site.claim(&call(&owner(), "POST", "/api/s/quaderno", &body, NOW).request(), &body), Ok(true));
    site
}

fn put(
    site: &mut Site<MemoryStore, StrictEd25519>,
    by: &SigningKey,
    slug: &str,
    body: &[u8],
) -> Result<bool, SiteError> {
    let path = format!("/api/s/quaderno/p/{slug}");
    site.put_page(&call(by, "PUT", &path, body, NOW).request(), slug, body)
}

#[test]
fn the_first_key_takes_the_name_and_keeps_it() {
    let mut site = claimed();
    let body = settings("Quaderno");
    assert_eq!(site.claim(&call(&owner(), "POST", "/api/s/quaderno", &body, NOW).request(), &body), Ok(false));
    assert_eq!(
        site.claim(&call(&stranger(), "POST", "/api/s/quaderno", &body, NOW).request(), &body),
        Err(SiteError::Taken)
    );
    assert!(site.home_html().unwrap().contains("<h1>Quaderno</h1>"));
}

#[test]
fn only_the_owner_writes() {
    let mut site = claimed();
    let body = page("Il faro", "testo");
    assert_eq!(put(&mut site, &stranger(), "il-faro", &body), Err(SiteError::Denied(Denied::Forbidden)));
    assert_eq!(put(&mut site, &owner(), "il-faro", &body), Ok(true));
    assert_eq!(put(&mut site, &owner(), "il-faro", &body), Ok(false), "replaced");
    let s = settings("Altro");
    assert_eq!(
        site.put_settings(&call(&stranger(), "PUT", "/api/s/quaderno", &s, NOW).request(), &s),
        Err(SiteError::Denied(Denied::Forbidden))
    );
    assert_eq!(
        site.delete(&call(&stranger(), "DELETE", "/api/s/quaderno", b"", NOW).request()),
        Err(SiteError::Denied(Denied::Forbidden))
    );
}

#[test]
fn a_signature_over_another_body_or_time_fails() {
    let mut site = claimed();
    let body = page("Il faro", "testo");
    let signed = call(&owner(), "PUT", "/api/s/quaderno/p/il-faro", b"something else", NOW);
    assert_eq!(
        site.put_page(&Request { body_digest: blake2b_256(&body), ..signed.request() }, "il-faro", &body),
        Err(SiteError::Denied(Denied::Unauthenticated))
    );
    let late = call(&owner(), "PUT", "/api/s/quaderno/p/il-faro", &body, NOW - 600_000);
    assert_eq!(
        site.put_page(&Request { now_ms: NOW, ..late.request() }, "il-faro", &body),
        Err(SiteError::Denied(Denied::Clock))
    );
}

#[test]
fn a_write_cannot_be_sent_twice() {
    let mut site = claimed();
    let body = page("Il faro", "testo");
    let once = call(&owner(), "PUT", "/api/s/quaderno/p/il-faro", &body, NOW);
    assert_eq!(site.put_page(&once.request(), "il-faro", &body), Ok(true));
    assert_eq!(site.put_page(&once.request(), "il-faro", &body), Err(SiteError::Denied(Denied::Replayed)));
}

#[test]
fn pages_render_and_only_listed_ones_are_on_the_home() {
    let mut site = claimed();
    put(&mut site, &owner(), "il-faro", &page("Il faro", "La *luce*")).unwrap();
    let draft = serde_json::json!({"title": "Bozza", "layout": "essay", "listed": false,
        "blocks": [{"kind": "markdown", "label": "", "text": "x"}]})
    .to_string();
    put(&mut site, &owner(), "bozza-k3j9", draft.as_bytes()).unwrap();
    let html = site.page_html("il-faro").unwrap();
    assert!(html.contains("<em>luce</em>"));
    let home = site.home_html().unwrap();
    assert!(home.contains("/quaderno/il-faro"));
    assert!(!home.contains("bozza"));
    assert!(site.page_html("bozza-k3j9").unwrap().contains("noindex"));
    assert_eq!(site.page_html("nessuna"), Err(SiteError::NotFound));
    assert!(site.style_css().unwrap().contains("--bg:#090C15"));
}

#[test]
fn a_page_needs_its_files_uploaded_first() {
    let mut site = claimed();
    let body = page("Foto", &format!("![mare](image:{PIC})"));
    assert_eq!(put(&mut site, &owner(), "foto", &body), Err(SiteError::MissingMedia));
    let path = format!("/api/s/quaderno/m/{PIC}?type=jpeg");
    site.admit_media(&call(&owner(), "PUT", &path, b"", NOW).request(), PIC, MediaType::Jpeg, 1000).unwrap();
    assert_eq!(put(&mut site, &owner(), "foto", &body), Ok(true));
    assert!(site.page_html("foto").unwrap().contains(&format!("src=\"/quaderno/m/{PIC}\"")));
    assert_eq!(site.media_type(PIC), Ok(MediaType::Jpeg));
}

#[test]
fn limits_hold() {
    let mut site = claimed().with_limits(SiteLimits { pages: 1, media: 1, media_bytes: 1500, media_file: 1000 });
    put(&mut site, &owner(), "uno", &page("Uno", "x")).unwrap();
    assert_eq!(put(&mut site, &owner(), "due", &page("Due", "x")), Err(SiteError::Full));
    let admit = |site: &mut Site<MemoryStore, StrictEd25519>, id: &str, size: u64| {
        site.admit_media(
            &call(&owner(), "PUT", &format!("/api/s/quaderno/m/{id}?type=png"), b"", NOW).request(),
            id,
            MediaType::Png,
            size,
        )
    };
    assert_eq!(admit(&mut site, PIC, 1001), Err(SiteError::Full), "file too big");
    assert_eq!(admit(&mut site, PIC, 900), Ok(()));
    assert_eq!(admit(&mut site, PIC, 1000), Ok(()), "replacing counts the difference");
    assert_eq!(admit(&mut site, "BBBBBBBBBBBBBBBB", 10), Err(SiteError::Full), "one file only");
}

#[test]
fn bad_bodies_are_refused_before_anything_is_stored() {
    let mut site = claimed();
    assert_eq!(put(&mut site, &owner(), "x", b"{}"), Err(SiteError::Invalid));
    assert_eq!(put(&mut site, &owner(), "Bad_Slug", &page("x", "y")), Err(SiteError::NotFound));
    let mut fresh = Site::new("nuovo", MemoryStore::default(), StrictEd25519);
    let ugly = br#"{"title":"x"}"#;
    assert_eq!(
        fresh.claim(&call(&owner(), "POST", "/api/s/nuovo", ugly, NOW).request(), ugly),
        Err(SiteError::Invalid)
    );
    assert!(fresh.store().is_empty());
}

#[test]
fn taking_the_site_down_frees_the_name() {
    let mut site = claimed();
    put(&mut site, &owner(), "il-faro", &page("Il faro", "x")).unwrap();
    site.delete(&call(&owner(), "DELETE", "/api/s/quaderno", b"", NOW).request()).unwrap();
    assert_eq!(site.home_html(), Err(SiteError::NotFound));
    let body = settings("Di un altro");
    assert_eq!(site.claim(&call(&stranger(), "POST", "/api/s/quaderno", &body, NOW).request(), &body), Ok(true));
}

#[test]
fn media_types_by_their_first_bytes() {
    assert!(MediaType::Jpeg.matches(&[0xFF, 0xD8, 0xFF, 0xE0]));
    assert!(MediaType::Png.matches(b"\x89PNG\r\n\x1a\n...."));
    assert!(MediaType::Webp.matches(b"RIFF\0\0\0\0WEBPVP8 "));
    assert!(MediaType::Ogg.matches(b"OggS\0"));
    assert!(!MediaType::Png.matches(b"<html><script>"));
    assert!(!MediaType::Webp.matches(b"RIFF\0\0\0\0WAVEfmt "));
    assert_eq!(MediaType::parse("svg"), None, "no SVG: it can carry script");
}
