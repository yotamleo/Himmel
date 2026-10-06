#!/usr/bin/env python3
"""x-scrapling-media.py - cookieless X status media lookup (HIMMEL-4677).

Sibling of ig-scrapling-media.py. Fetches a public x.com status page with
Scrapling's stealth fetcher (NO cookies), records every video.twimg.com URL the
page loads, and pulls the status's own media out of its <article> (a quoted
post's nested <article> is excluded). Prints one JSON object:

  {"status": "ok", "items": [{"kind": "video"|"image", "url": str, "hls": bool}]}
  {"status": "login_wall"|"removed"|"no_media"|"error", "detail": str}

A video is a direct https://video.twimg.com/...mp4 when the page carries one;
a streamed (blob:) video resolves to its HLS master playlist from the captured
network URLs, matched by the media id in its poster (hls: true).

Exit: 0 ok, 3 scrapling not installed, 4 login_wall/no_media, 5 removed,
6 fetch error. Runs under the scrapling venv python (requirements-scrapling.txt);
x-media-fetch.py calls it as a subprocess and downloads the items itself.

`--from-html FILE [--net-log FILE]` skips the fetch and extracts from a recorded
page plus its recorded video.twimg.com URLs, one per line (tests).
"""
import argparse
import html as htmllib
import importlib.util
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

TIMEOUT_MS = 60000
VIDEO_HOST = "video.twimg.com"
ARTICLE_OPEN = re.compile(r"<article\b")
# Media tags in document order: a <video ...> (with its poster/src) or an <img>.
MEDIA_TAG = re.compile(r"<video\b[^>]*>(?:.*?</video>)?|<img\b[^>]*>", re.S)
ATTR = re.compile(r'\b(src|poster)="([^"]*)"')
SOURCE_SRC = re.compile(r'<source\b[^>]*\bsrc="([^"]*)"')
IMAGE_RE = re.compile(r"^https://pbs\.twimg\.com/media/([A-Za-z0-9_-]+)(?:\?(.*))?$")
POSTER_ID = re.compile(r"/(?:amplify_video_thumb|ext_tw_video_thumb)/(\d+)/")


def _https_host(u, host):
    p = urlparse(u or "")
    return p.scheme == "https" and (p.hostname or "").lower() == host


def main_article(page_html, status_id):
    """The status's own <article> up to its first nested <article> (a quoted
    post) or its close, whichever comes first. None when no article names it.
    The article is identified by its own permalink, which may also sit AFTER
    the quoted post (a focal tweet's timestamp): that tail is searched too."""
    own = re.compile(rf"/status/{status_id}(?![0-9])")
    for m in ARTICLE_OPEN.finditer(page_html):
        start = m.end()
        close = page_html.find("</article>", start)
        if close < 0:
            continue
        nested = ARTICLE_OPEN.search(page_html, start, close)
        region = page_html[start:nested.start() if nested else close]
        if own.search(region):
            return region
        if nested:
            tail_start = close + len("</article>")
            nxt = ARTICLE_OPEN.search(page_html, tail_start)
            if own.search(page_html, tail_start, nxt.start() if nxt else len(page_html)):
                return region
    return None


def _image(src):
    """pbs.twimg.com/media/<id> as a large JPEG: x-media-fetch.py stores every
    image item as NN.jpg, and pbs serves any media id in format=jpg."""
    m = IMAGE_RE.match(src)
    return f"https://pbs.twimg.com/media/{m.group(1)}?format=jpg&name=large" if m else None


def _hls_master(media_id, net_urls):
    pat = re.compile(rf"^https://video\.twimg\.com/(?:amplify_video|ext_tw_video)/{media_id}/pl/[A-Za-z0-9_-]+\.m3u8(?:\?.*)?$")
    for u in net_urls:
        if pat.match(u):
            return u
    return None


def extract_media(page_html, status_id, net_urls):
    region = main_article(page_html, status_id)
    if region is None:
        return {"status": "no_media", "detail": "no article for this status"}
    items = []
    for tag in MEDIA_TAG.finditer(region):
        t = tag.group(0)
        attrs = {k: htmllib.unescape(v) for k, v in ATTR.findall(t.split(">", 1)[0])}
        if t.startswith("<img"):
            u = _image(attrs.get("src", ""))
            if u:
                items.append({"kind": "image", "url": u, "hls": False})
            continue
        src = attrs.get("src") or ""
        if not src:
            s = SOURCE_SRC.search(t)
            src = htmllib.unescape(s.group(1)) if s else ""
        if _https_host(src, VIDEO_HOST) and urlparse(src).path.endswith(".mp4"):
            items.append({"kind": "video", "url": src, "hls": False})
            continue
        pid = POSTER_ID.search(attrs.get("poster", ""))
        master = _hls_master(pid.group(1), net_urls) if pid else None
        if not master:
            return {"status": "error", "detail": "video without a direct mp4 or a captured HLS playlist"}
        items.append({"kind": "video", "url": master, "hls": True})
    if not items:
        return {"status": "no_media", "detail": "status article carries no media"}
    return {"status": "ok", "items": items}


def classify_page(final_url, status):
    path = urlparse(final_url or "").path
    if path.startswith(("/i/flow/login", "/login", "/account/access")):
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
    """(html, final_url, status, net_urls). ImportError when scrapling is missing."""
    from scrapling.fetchers import StealthyFetcher
    batch = _batch_module()
    state = {"armed": False}
    net = []

    def setup(pg):
        batch._block_private_requests(pg, state)
        pg.on("response", lambda r: net.append(r.url) if _https_host(r.url, VIDEO_HOST) else None)

    page = StealthyFetcher.fetch(
        url, headless=True, network_idle=True, timeout=TIMEOUT_MS,
        page_setup=setup, additional_args={"service_workers": "block"})
    if not state["armed"]:
        raise RuntimeError("private-host guard did not install")
    final = str(getattr(page, "url", "") or url)
    if batch._is_private_host((urlparse(final).hostname or "").lower()):
        raise RuntimeError("redirected to a private host")
    page_html = getattr(page, "html_content", None) or ""
    return page_html, final, getattr(page, "status", 200), net


EXIT = {"ok": 0, "login_wall": 4, "no_media": 4, "removed": 5, "error": 6}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--status-id", required=True)
    ap.add_argument("--from-html", type=Path)
    ap.add_argument("--net-log", type=Path)
    ap.add_argument("--final-url", default=None)
    args = ap.parse_args(argv)
    if not args.status_id.isdigit():
        ap.error("--status-id must be numeric")
    if args.from_html:
        page_html, final, status = args.from_html.read_text(encoding="utf-8"), args.final_url, 200
        net = args.net_log.read_text(encoding="utf-8").split() if args.net_log else []
    else:
        if not args.url:
            ap.error("--url or --from-html is required")
        try:
            page_html, final, status, net = fetch(args.url)
        except ImportError:
            print(json.dumps({"status": "error", "detail": "scrapling not installed"}))
            return 3
        except Exception as e:
            print(json.dumps({"status": "error", "detail": f"{type(e).__name__}: {str(e)[:120]}"}))
            return 6
    out = classify_page(final, status) or extract_media(page_html, args.status_id, net)
    print(json.dumps(out))
    return EXIT[out["status"]]


if __name__ == "__main__":
    sys.exit(main())
