#!/usr/bin/env python3
"""ig-scrapling-media.py - cookieless Instagram post media lookup (HIMMEL-4675).

Fetches a public post/reel page with Scrapling's stealth fetcher (NO cookies)
and pulls the post's media URLs and caption out of the page's embedded
`<script type="application/json">` blocks. Prints one JSON object:

  {"status": "ok", "caption": str|null, "items": [{"kind": "video"|"image", "url": str}]}
  {"status": "login_wall"|"removed"|"no_media"|"error", "detail": str}

Exit: 0 ok, 3 scrapling not installed, 4 login_wall/no_media, 5 removed,
6 fetch error. Runs under the scrapling venv python (requirements-scrapling.txt);
ig-media-fetch.py calls it as a subprocess and downloads the items itself.

`--from-html FILE` skips the fetch and extracts from a recorded page (tests).
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

TIMEOUT_MS = 60000
# Media must come from Instagram's CDN, over https; anything else is dropped.
CDN_SUFFIXES = (".cdninstagram.com", ".fbcdn.net")
JSON_SCRIPT = re.compile(r'<script type="application/json"[^>]*>(.*?)</script>', re.S)


def _cdn_url(u):
    if not isinstance(u, str):
        return None
    p = urlparse(u)
    host = (p.hostname or "").lower()
    if p.scheme == "https" and host.endswith(CDN_SUFFIXES):
        return u
    return None


def _best_image(node):
    cands = ((node.get("image_versions2") or {}).get("candidates")) or []
    # Widest candidate first; carousel children often carry no width, so the
    # page's own order (largest first) is the tie-break.
    ranked = sorted(enumerate(cands), key=lambda ic: (-(ic[1].get("width") or 0), ic[0]))
    for _, c in ranked:
        u = _cdn_url(c.get("url"))
        if u:
            return u
    return None


def _item(node):
    if node.get("video_versions"):
        for v in node["video_versions"]:
            u = _cdn_url(v.get("url"))
            if u:
                return {"kind": "video", "url": u}
        return None
    u = _best_image(node)
    return {"kind": "image", "url": u} if u else None


def _find_media_node(obj, shortcode):
    """The first dict with code == shortcode that carries media. A same-code
    node without media (a link preview, a related-post stub) is skipped."""
    stack = [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            if o.get("code") == shortcode and any(
                    k in o for k in ("video_versions", "image_versions2", "carousel_media")):
                return o
            stack.extend(reversed(list(o.values())))
        elif isinstance(o, list):
            stack.extend(reversed(o))
    return None


def extract_media(html, shortcode):
    node = None
    for block in JSON_SCRIPT.findall(html):
        try:
            data = json.loads(block)
        except ValueError:
            continue
        node = _find_media_node(data, shortcode)
        if node:
            break
    if node is None:
        return {"status": "no_media", "detail": "no media node for this shortcode"}
    children = node.get("carousel_media") or [node]
    items = [it for it in (_item(c) for c in children) if it]
    if not items:
        return {"status": "no_media", "detail": "media node has no CDN media URL"}
    cap = node.get("caption")
    caption = cap.get("text") if isinstance(cap, dict) else None
    return {"status": "ok", "caption": caption or None, "items": items}


def classify_page(final_url, status):
    path = urlparse(final_url or "").path
    if path.startswith(("/accounts/login", "/challenge")):
        return {"status": "login_wall", "detail": path}
    if status == 404:
        return {"status": "removed", "detail": "HTTP 404"}
    if status and status >= 400:
        return {"status": "error", "detail": f"HTTP {status}"}
    return None


def _batch_module():
    """harvest-clip-body-batch.py, for its private-host request guard."""
    path = Path(__file__).with_name("harvest-clip-body-batch.py")
    spec = importlib.util.spec_from_file_location("harvest_clip_body_batch", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fetch(url):
    """(html, final_url, status). ImportError when scrapling is missing."""
    from scrapling.fetchers import StealthyFetcher
    batch = _batch_module()
    state = {"armed": False}
    page = StealthyFetcher.fetch(
        url, headless=True, network_idle=True, timeout=TIMEOUT_MS,
        page_setup=lambda pg: batch._block_private_requests(pg, state),
        additional_args={"service_workers": "block"})
    if not state["armed"]:
        raise RuntimeError("private-host guard did not install")
    final = str(getattr(page, "url", "") or url)
    if batch._is_private_host((urlparse(final).hostname or "").lower()):
        raise RuntimeError("redirected to a private host")
    html = getattr(page, "html_content", None) or ""
    return html, final, getattr(page, "status", 200)


EXIT = {"ok": 0, "login_wall": 4, "no_media": 4, "removed": 5, "error": 6}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--shortcode", required=True)
    ap.add_argument("--from-html", type=Path)
    ap.add_argument("--final-url", default=None)
    args = ap.parse_args(argv)
    if args.from_html:
        html, final, status = args.from_html.read_text(encoding="utf-8"), args.final_url, 200
    else:
        if not args.url:
            ap.error("--url or --from-html is required")
        try:
            html, final, status = fetch(args.url)
        except ImportError:
            print(json.dumps({"status": "error", "detail": "scrapling not installed"}))
            return 3
        except Exception as e:
            print(json.dumps({"status": "error", "detail": f"{type(e).__name__}: {str(e)[:120]}"}))
            return 6
    out = classify_page(final, status) or extract_media(html, args.shortcode)
    print(json.dumps(out))
    return EXIT[out["status"]]


if __name__ == "__main__":
    sys.exit(main())
