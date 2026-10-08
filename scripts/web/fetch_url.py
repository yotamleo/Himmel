#!/usr/bin/env python3
"""fetch_url.py - body of scripts/web/fetch-url.sh (HIMMEL-4908).

Fetch a pasted link as text. Hosts listed in walled-hosts.conf (x.com,
instagram.com ... - login-walled, WebFetch gets HTTP 402) go through Scrapling's
stealth fetcher with NO cookies and never a Chrome profile; every other host is
a plain HTTP GET rendered to text.

Exit: 0 ok, 2 usage, 3 scrapling needed but not installed (install hint on
stderr), 4 fetch failed (status on stderr).

`--from-html FILE` skips the fetch and parses a recorded page (tests).
Run under `python -I` from the scrapling venv (fetch-url.sh does this).
"""
import argparse
import html as htmllib
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
TIMEOUT_S = 30
TIMEOUT_MS = 60000
INSTALL_HINT = ("scrapling is not installed: python3 -m venv ~/.himmel/scrapling-venv && "
                "~/.himmel/scrapling-venv/bin/pip install -r "
                "marketplace/plugins/obsidian-triage/tools/requirements-scrapling.txt "
                "&& ~/.himmel/scrapling-venv/bin/scrapling install")
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "source", "track", "wbr"}
SKIP = {"script", "style", "noscript", "template", "svg"}


def walled_hosts():
    try:
        return (HERE / "walled-hosts.conf").read_text(encoding="utf-8").splitlines()[0].split()
    except (OSError, IndexError):
        return []


def host_of(url):
    return (urlparse(url).hostname or "").lower()


def is_walled(url):
    h = host_of(url)
    return any(h == w or h.endswith("." + w) for w in walled_hosts())


HANDLE = re.compile(r"^@\w{1,15}$")
STAMP = re.compile(r"^(?:\d+[smhdw]|[A-Z][a-z]{2} \d{1,2}(?:, \d{4})?)$")
FULL_STAMP = re.compile(r"\d{1,2}:\d\d [AP]M · [A-Z][a-z]{2} \d{1,2}, \d{4}")


class Posts(HTMLParser):
    """Top-level <article>s in order: author, handle, date, text, media. A
    nested <article> (a quoted post) is ignored rather than merged."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.posts = []
        self.stack = []  # (tag, role) for open non-void tags inside the current article
        self.depth = 0
        self.skip = 0
        self.cur = None

    def _open(self):
        self.cur = {"author": "", "handle": "", "date": "", "text": [], "media": []}
        self.stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "article":
            self.depth += 1
            if self.depth == 1:
                self._open()
            return
        if self.depth != 1:
            return
        if tag in VOID:
            self._media(tag, a)
            return
        role = None
        tid = a.get("data-testid")
        cls = a.get("class") or ""
        if tid == "tweetText" or ("whitespace-pre-wrap" in cls and a.get("dir") == "auto"):
            role = "text"
            self.cur["text"].append("")
        elif tid == "User-Name" or "font-bold" in cls:
            role = "user"
        if tag == "time" and a.get("datetime") and not self.cur["date"]:
            self.cur["date"] = a["datetime"]
        if tag == "video":
            self._media(tag, a)
        if tag in SKIP:
            self.skip += 1
        self.stack.append((tag, role))

    def handle_startendtag(self, tag, attrs):
        if self.depth == 1 and tag != "article":
            self._media(tag, dict(attrs))

    def _media(self, tag, a):
        u = ""
        if tag == "img":
            s = a.get("src") or ""
            if s.startswith("https://pbs.twimg.com/media/"):
                u = s
        elif tag in ("video", "source"):
            s = a.get("src") or ""
            if s.startswith("https://video.twimg.com/"):
                u = s
            elif tag == "video" and (a.get("poster") or "").startswith("https://pbs.twimg.com/"):
                u = a["poster"] + "  (video poster)"
        if u and u not in self.cur["media"]:
            self.cur["media"].append(u)

    def handle_endtag(self, tag):
        if tag == "article":
            if self.depth == 1 and self.cur is not None:
                self.posts.append(self.cur)
                self.cur = None
            self.depth = max(0, self.depth - 1)
            return
        if self.depth != 1 or tag in VOID:
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                for t, _ in self.stack[i:]:
                    if t in SKIP:
                        self.skip = max(0, self.skip - 1)
                del self.stack[i:]
                break

    def handle_data(self, data):
        if self.depth != 1 or self.skip or self.cur is None:
            return
        roles = {r for _, r in self.stack if r}
        if "text" in roles:
            self.cur["text"][-1] += data
            return
        d = data.strip()
        if not d:
            return
        if HANDLE.match(d):
            self.cur["handle"] = self.cur["handle"] or d
        elif "user" in roles:
            if not self.cur["author"] and d != "·":
                self.cur["author"] = d
        elif FULL_STAMP.search(d):
            self.cur["date"] = FULL_STAMP.search(d).group(0)
        elif STAMP.match(d) and not self.cur["date"]:
            self.cur["date"] = d


def parse_x(page_html):
    p = Posts()
    p.feed(page_html)
    p.close()
    return p.posts


def render_x(posts):
    out = []
    for i, p in enumerate(posts, 1):
        out.append(f"== post {i}/{len(posts)} ==")
        out.append(f"author: {p['author']}")
        out.append(f"handle: {p['handle']}")
        out.append(f"date: {p['date']}")
        out.append("text:")
        out.append("\n\n".join(t.strip() for t in p["text"] if t.strip()) or "(none)")
        if p["media"]:
            out.append("media:")
            out.extend(f"- {m}" for m in p["media"])
        out.append("")
    return "\n".join(out)


META = re.compile(r'<meta\b[^>]*>', re.S | re.I)
META_ATTR = re.compile(r'\b([\w:-]+)\s*=\s*"([^"]*)"')


def render_meta(page_html):
    """Instagram (and any walled page without <article> posts): the og: tags."""
    keep = ("og:title", "og:description", "og:image", "og:video", "og:url")
    seen, out = set(), []
    for m in META.finditer(page_html):
        a = {k.lower(): htmllib.unescape(v) for k, v in META_ATTR.findall(m.group(0))}
        k = a.get("property") or a.get("name")
        if k in keep and a.get("content") and (k, a["content"]) not in seen:
            seen.add((k, a["content"]))
            out.append(f"{k}: {a['content']}")
    return "\n".join(out)


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip += 1
        elif tag in ("p", "div", "br", "li", "h1", "h2", "h3", "h4", "tr"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip = max(0, self.skip - 1)

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(page_html):
    t = Text()
    t.feed(page_html)
    t.close()
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t]+", " ", "".join(t.parts))).strip()


def render_walled(page_html):
    posts = parse_x(page_html)
    if posts:
        return render_x(posts)
    return render_meta(page_html) or html_to_text(page_html)


def fetch_walled(url):
    """(html, final_url, status). ImportError when scrapling is missing."""
    from scrapling.fetchers import StealthyFetcher
    page = StealthyFetcher.fetch(url, headless=True, network_idle=True, timeout=TIMEOUT_MS)
    return (getattr(page, "html_content", None) or "", str(getattr(page, "url", "") or url),
            getattr(page, "status", 200))


def fetch_plain(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (himmel fetch-url)"})
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
        raw = r.read(8_000_000)
        charset = r.headers.get_content_charset() or "utf-8"
        return raw.decode(charset, "replace"), r.headers.get_content_type()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("url", nargs="?")
    ap.add_argument("--from-html", type=Path)
    args = ap.parse_args(argv)
    if args.from_html:
        print(render_walled(args.from_html.read_text(encoding="utf-8")))
        return 0
    if not args.url or urlparse(args.url).scheme not in ("http", "https"):
        print("usage: fetch-url.sh <http(s) url>", file=sys.stderr)
        return 2
    if is_walled(args.url):
        try:
            page_html, final, status = fetch_walled(args.url)
        except ImportError:
            print(INSTALL_HINT, file=sys.stderr)
            return 3
        except Exception as e:
            print(f"fetch failed: {type(e).__name__}: {str(e)[:160]}", file=sys.stderr)
            return 4
        path = urlparse(final).path
        if path.startswith(("/i/flow/login", "/login", "/account/access")):
            print(f"fetch failed: login wall ({path})", file=sys.stderr)
            return 4
        if status and status >= 400:
            print(f"fetch failed: HTTP {status}", file=sys.stderr)
            return 4
        print(render_walled(page_html))
        return 0
    try:
        body, ctype = fetch_plain(args.url)
    except urllib.error.HTTPError as e:
        print(f"fetch failed: HTTP {e.code}", file=sys.stderr)
        return 4
    except Exception as e:
        print(f"fetch failed: {type(e).__name__}: {str(e)[:160]}", file=sys.stderr)
        return 4
    print(html_to_text(body) if "html" in ctype else body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
