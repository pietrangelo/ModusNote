"""serv.pub end to end: a site claimed and written through the modusnote
Worker's /api/s/ (signed by the site's own key), then read through the
servpub Worker (server/pages) as any visitor would. Run by `run.sh` against
two `wrangler dev` sessions sharing the same local Durable Objects and R2.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402

API = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
PAGES = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8788"
e2e.BASE = API
call, expect, b64 = e2e.call, e2e.expect, e2e.b64

PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082"
)
THEME = {"dark": True, "background": "#090C15", "surface": "#13192B", "text": "#F8FAFC",
         "secondary": "#8F9CAE", "accent": "#EBB448", "second_accent": "#7FB2F0"}


def settings(title, indexable=False):
    return {"title": title, "about": "Racconti *brevi*.", "lang": "it", "body": 18,
            "home": "collection", "indexable": indexable, "theme": THEME}


def visit(path, headers=None):
    request = urllib.request.Request(PAGES + path, method="GET", headers=headers or {})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request) as response:
            return response.status, response.read().decode(errors="replace"), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace"), dict(error.headers)


# The smallest file the server takes as an MP4: a file type box, then
# padding standing for the movie (the app cleans and checks real ones).
MP4 = bytes.fromhex("00000018667479706d703432000000006d703432697369736f6d") + bytes(1000)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def seen(outcome, status, what):
    if outcome[0] != status:
        raise SystemExit(f"FAIL {what}: expected {status}, got {outcome[0]} {outcome[1][:300]!r}")
    print(f"ok   {what}")
    return outcome


def main():
    bits = expect(call("GET", "/api/info"), 200, "info")["pow"]
    owner, stranger = e2e.Device(), e2e.Device()
    name = "e2e-" + os.urandom(4).hex()
    s = f"/api/s/{name}"
    pic = os.urandom(12).hex()
    clip = os.urandom(12).hex()

    expect(call("POST", s, owner, {"settings": settings("Quaderno"), "pow": {"day": 0, "nonce": b64(bytes(16))}}),
           403, "claiming without work")
    claim = {"settings": settings("Quaderno"), "pow": e2e.pow_nonce(3, name.encode(), bits)}
    expect(call("POST", s, owner, claim), 201, "claiming a free name")
    claim = {"settings": settings("Mio"), "pow": e2e.pow_nonce(3, name.encode(), bits)}
    expect(call("POST", s, stranger, claim), 409, "the name is taken for anyone else")

    page = {"title": "Il <faro>", "layout": "golden_section", "listed": True, "blocks": [
        {"kind": "markdown", "label": "", "text": f"La luce *gira*. <script>alert(1)</script>\n\n![faro](image:{pic})"},
        {"kind": "text", "label": "Luogo", "text": "Capo Testa"},
    ]}
    expect(call("PUT", f"{s}/p/il-faro", owner, page), 422, "a page before its picture is uploaded")
    expect(call("PUT", f"{s}/m/{pic}?type=png", owner, raw=b"<svg onload=alert(1)>", signed_body=b""),
           422, "a file that is not what it says")
    expect(call("PUT", f"{s}/m/{pic}?type=png", stranger, raw=PNG, signed_body=b""), 403, "a stranger's file")
    expect(call("PUT", f"{s}/m/{pic}?type=png", owner, raw=PNG, signed_body=b""), 201, "the owner's picture")
    expect(call("PUT", f"{s}/p/il-faro", stranger, page), 403, "a stranger's page")
    expect(call("PUT", f"{s}/p/il-faro", owner, page), 201, "the owner's page")

    status, html, headers = seen(visit(f"/{name}/il-faro"), 200, "the page on serv.pub")
    assert "<h1>Il &lt;faro&gt;</h1>" in html, html
    assert "&lt;script&gt;" in html and "<script" not in html.lower(), html
    assert f'<img src="/{name}/m/{pic}"' in html, html
    assert "<aside>" in html and "Capo Testa" in html, html
    assert 'content="noindex, nofollow"' in html, "not indexable unless the site says so"
    assert headers["Content-Security-Policy"].startswith("default-src 'none'"), headers
    assert headers["X-Content-Type-Options"] == "nosniff", headers
    status, home, _ = seen(visit(f"/{name}/"), 200, "the site's home")
    assert f'href="/{name}/il-faro"' in home and "<em>brevi</em>" in home, home
    seen(visit(f"/{name}"), 301, "the home without its slash")
    status, css, headers = seen(visit(f"/{name}/style.css"), 200, "the stylesheet")
    assert "--h1:76px" in css and "61.8fr 38.2fr" in css and headers["Content-Type"].startswith("text/css"), css
    status, _, headers = seen(visit(f"/{name}/m/{pic}"), 200, "the picture")
    assert headers["Content-Type"] == "image/png" and headers["X-Content-Type-Options"] == "nosniff", headers
    status, feed, headers = seen(visit(f"/{name}/feed.xml"), 200, "the feed")
    assert headers["Content-Type"].startswith("application/atom+xml"), headers
    assert f"/{name}/il-faro</id>" in feed, feed
    status, font, headers = seen(visit("/fonts/literata.woff2"), 200, "a font")
    assert headers["Content-Type"] == "font/woff2" and headers["X-Content-Type-Options"] == "nosniff", headers
    assert font.startswith("wOF2"), font[:8]
    seen(visit("/fonts/LICENCES.txt"), 404, "only the fonts of the assets")
    seen(visit("/index.html"), 404, "nothing of the vault's client on serv.pub")
    seen(visit("/api/info"), 404, "and no API")
    seen(visit(f"/{name}/nessuna"), 404, "a page that does not exist")

    seen(visit(f"/{name}/ricette"), 404, "no cookbook without recipes")
    recipe = {"title": "Pane di <semola>", "layout": "recipe", "listed": True, "blocks": [], "recipe": {
        "category": "Pane e lievitati", "description": "Crosta sottile.", "servings": 4, "prep": 30, "cook": 45,
        "cover": [{"media": pic, "caption": "Il pane"}], "methods": ["Forno"], "difficulty": 2,
        "ingredients": [{"name": "Semola", "amount": 500, "unit": "gram", "one": "g", "other": "g",
                         "link": "https://esempio.it/semola"},
                        {"name": "Sale", "quantity": "q.b."}],
        "steps": [{"text": "Impasta e lascia riposare **2 ore**.", "video": clip}, {"text": "Inforna."}]}}
    expect(call("PUT", f"{s}/m/{clip}?type=mp4", owner, raw=PNG, signed_body=b""), 422, "a picture is not a video")
    expect(call("PUT", f"{s}/m/{clip}?type=mp4", owner, raw=MP4, signed_body=b""), 201, "a step's video")
    expect(call("PUT", f"{s}/p/ricette", owner, recipe), 404, "no page at the cookbook's address")
    expect(call("PUT", f"{s}/p/pane", owner, recipe), 201, "a recipe")
    status, html, headers = seen(visit(f"/{name}/pane"), 200, "the recipe's page")
    assert "<h1>Pane di &lt;semola&gt;</h1>" in html and "<span>4 porzioni</span>" in html, html
    assert 'rel="nofollow ugc sponsored noopener noreferrer">su esempio.it</a>' in html, html
    assert "<script" not in html.lower(), "no structured data on a site that is not indexable"
    assert f'<video class="clip" controls playsinline preload="metadata" src="/{name}/m/{clip}"></video>' in html, html
    status, body, headers = seen(visit(f"/{name}/m/{clip}"), 200, "the video")
    assert headers["Content-Type"] == "video/mp4" and headers["Accept-Ranges"] == "bytes", headers
    status, body, headers = seen(visit(f"/{name}/m/{clip}", {"Range": "bytes=4-11"}), 206, "a part of it")
    assert body == "ftypmp42" and headers["Content-Range"] == f"bytes 4-11/{len(MP4)}", (body, headers)
    seen(visit(f"/{name}/m/{clip}", {"Range": "bytes=99999-"}), 416, "past its end")
    status, html, _ = seen(visit(f"/{name}/pane?p=8"), 200, "the recipe for 8")
    assert '<span class="qty">1000 g</span>' in html and "noindex" in html, html
    status, html, headers = seen(visit(f"/{name}/ricette"), 200, "the cookbook")
    assert 'class="band c0"' in html and f'href="/{name}/ricette/pane-e-lievitati"' in html, html
    assert "form-action 'self'" in headers["Content-Security-Policy"], headers
    status, html, _ = seen(visit(f"/{name}/ricette?q=SEMOLA&t=120"), 200, "a search")
    assert f'href="/{name}/pane"' in html and "1 ricetta" in html, html
    status, html, _ = seen(visit(f"/{name}/ricette?q=%3Cscript%3E"), 200, "a search for markup")
    assert "<script>" not in html and "Nessuna ricetta trovata" in html, html
    seen(visit(f"/{name}/ricette/pane-e-lievitati"), 200, "a category")
    seen(visit(f"/{name}/ricette/nessuna"), 404, "a category without recipes")
    status, css, _ = seen(visit(f"/{name}/style.css"), 200, "the stylesheet with the category's colours")
    assert ".c0{--cat:#" in css, css

    expect(call("DELETE", f"{s}/p/il-faro", owner), 200, "the owner takes a page down")
    seen(visit(f"/{name}/il-faro"), 404, "the page is gone")
    expect(call("DELETE", s, stranger), 403, "a stranger cannot take the site down")
    expect(call("DELETE", s, owner), 200, "the owner takes the site down")
    seen(visit(f"/{name}/"), 404, "the site is gone")
    seen(visit(f"/{name}/m/{pic}"), 404, "and its files")
    print("serv.pub all good")


if __name__ == "__main__":
    main()
