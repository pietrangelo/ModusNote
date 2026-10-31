//! The Workers runtime of serv.pub: the site's object for pages and
//! stylesheets, R2 for files, a read allowance per address.

use js_sys::Reflect;
use wasm_bindgen::JsCast;
use worker::{Context, Env, ObjectNamespace, Request, Response, ResponseBody, Result, Stub, event};

use crate::{FRONT, MEDIA_CACHE, NO_CACHE, NOT_FOUND, PAGE_CACHE, PublicRoute, ROBOTS, headers, route};

const SITES: &str = "SITES";
const BLOBS: &str = "BLOBS";
const JURISDICTION: &str = "eu";

fn with_headers(mut response: Response, content_type: &str, cache: &str) -> Result<Response> {
    let target = response.headers_mut();
    for (name, value) in headers(content_type, cache) {
        target.set(name, &value)?;
    }
    Ok(response)
}

fn text(status: u16, body: &str, content_type: &str, cache: &str) -> Result<Response> {
    with_headers(Response::ok(body)?.with_status(status), content_type, cache)
}

fn not_found() -> Result<Response> {
    text(404, NOT_FOUND, "text/html; charset=utf-8", NO_CACHE)
}

/// The site's object, in the EU like every object; `OBJECT_PLACEMENT =
/// "local"` only for `wrangler dev`.
fn stub(env: &Env, name: &str) -> Result<Stub> {
    let namespace = env.durable_object(SITES)?;
    if env.var("OBJECT_PLACEMENT").is_ok_and(|v| v.to_string() == "local") {
        return namespace.get_by_name(name);
    }
    let jurisdiction = Reflect::get(namespace.as_ref(), &"jurisdiction".into())?;
    let restricted =
        jurisdiction.unchecked_into::<js_sys::Function>().call1(namespace.as_ref(), &JURISDICTION.into())?;
    restricted.unchecked_into::<ObjectNamespace>().get_by_name(name)
}

/// A public read from the site's object: its text, or None when there is
/// no such site, page or file.
async fn read(env: &Env, site: &str, path: &str) -> Result<Option<String>> {
    let mut reply = stub(env, site)?.fetch_with_str(&format!("https://object{path}")).await?;
    match reply.status_code() {
        200 => Ok(Some(reply.text().await?)),
        404 => Ok(None),
        _ => Err(worker::Error::RustError("site unavailable".into())),
    }
}

async fn rate_limited(env: &Env, req: &Request) -> bool {
    let Ok(limiter) = env.rate_limiter("READ_LIMITER") else { return false };
    let address = req.headers().get("CF-Connecting-IP").ok().flatten().unwrap_or_default();
    limiter.limit(address).await.is_ok_and(|outcome| !outcome.success)
}

async fn serve(req: &Request, env: &Env) -> Result<Response> {
    let url = req.url()?;
    let route = route(req.method().as_ref(), url.path());
    if route != PublicRoute::NotFound && rate_limited(env, req).await {
        return text(429, "", "text/plain", NO_CACHE);
    }
    let html = "text/html; charset=utf-8";
    match route {
        PublicRoute::Front => text(200, FRONT, html, PAGE_CACHE),
        PublicRoute::Robots => text(200, ROBOTS, "text/plain; charset=utf-8", PAGE_CACHE),
        PublicRoute::Slash(site) => {
            let mut response = text(301, "", "text/plain", PAGE_CACHE)?;
            response.headers_mut().set("Location", &format!("/{site}/"))?;
            Ok(response)
        }
        PublicRoute::Home(site) => match read(env, &site, "/internal/home").await? {
            Some(body) => text(200, &body, html, PAGE_CACHE),
            None => not_found(),
        },
        PublicRoute::Style(site) => match read(env, &site, "/internal/style").await? {
            Some(body) => text(200, &body, "text/css; charset=utf-8", PAGE_CACHE),
            None => not_found(),
        },
        PublicRoute::Page(site, slug) => match read(env, &site, &format!("/internal/page/{slug}")).await? {
            Some(body) => text(200, &body, html, PAGE_CACHE),
            None => not_found(),
        },
        PublicRoute::Media(site, id) => {
            let Some(kind) = read(env, &site, &format!("/internal/media/{id}")).await? else { return not_found() };
            let Some(kind) = publish::MediaType::parse(&kind) else { return not_found() };
            let Some(object) = env.bucket(BLOBS)?.get(format!("pub/{site}/{id}")).execute().await? else {
                return not_found();
            };
            let size = object.size();
            let Some(body) = object.body() else { return not_found() };
            let body: ResponseBody = body.response_body()?;
            let mut response = with_headers(Response::from_body(body)?, kind.content_type(), MEDIA_CACHE)?;
            response.headers_mut().set("Content-Length", &size.to_string())?;
            Ok(response)
        }
        PublicRoute::NotFound => not_found(),
    }
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    match serve(&req, &env).await {
        Ok(response) => Ok(response),
        Err(_) => text(503, "", "text/plain", NO_CACHE),
    }
}
