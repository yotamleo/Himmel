#!/usr/bin/env python3
"""Unit tests for the thin-body scrape backend chain + Firecrawl ledger
(HIMMEL-4335). Hermetic: urllib.request.urlopen is stubbed, the ledger path
is always a scratch file (HIMMEL_FIRECRAWL_LEDGER) — no network, no key, no
credits, never the real ledger.

Run via tests/test-scrape-backends.sh (or directly with any python3).
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "tools" / "harvest-clip-body-batch.py"
spec = importlib.util.spec_from_file_location("harvest_batch", TOOL)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-10-04"

SCRATCH = Path(tempfile.mkdtemp(dir=os.environ.get("HIMMEL_TEST_TMP") or None))
LEDGER = SCRATCH / "ledger.jsonl"
os.environ["HIMMEL_FIRECRAWL_LEDGER"] = str(LEDGER)

passed = failed = 0


def check(desc, cond):
    global passed, failed
    if cond:
        print(f"  PASS  {desc}")
        passed += 1
    else:
        print(f"  FAIL  {desc}")
        failed += 1


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


SEEN = []


def stub_urlopen(responses):
    """Install a urlopen stub that pops canned bodies (or raises) per call."""
    def fake(req, timeout=None):
        SEEN.append(req)
        item = responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return Resp(item if isinstance(item, bytes) else item.encode("utf-8"))
    urllib.request.urlopen = fake


def ledger_lines():
    if not LEDGER.exists():
        return []
    return [json.loads(l) for l in LEDGER.read_text().splitlines() if l.strip()]


def fc_lines():
    return [r for r in ledger_lines() if r.get("source") == "firecrawl"]


def reset():
    SEEN.clear()
    if LEDGER.exists():
        LEDGER.unlink()


URL = "https://example.com/post?token=SECRET123&x=1"
BODY_MARK = "PAGEBODY-DO-NOT-LOG"

# --- ledger: firecrawl scrape appends one line, credits from response -------
reset()
stub_urlopen([json.dumps({"success": True, "data": {"markdown": f"# T\n\n{BODY_MARK}",
                                                   "metadata": {"creditsUsed": 3}}})])
fc = mod.FirecrawlClient("KEY-abc123", budget=5)
fc.scrape(URL)
lines = ledger_lines()
check("ledger: one line per firecrawl scrape", len(lines) == 1)
row = lines[0] if lines else {}
check("ledger: call_site/endpoint recorded", row.get("call_site") == "harvest-clip-body-batch" and row.get("endpoint") == "/v2/scrape")
check("ledger: credits read from response creditsUsed", row.get("credits") == 3)
check("ledger: ts present", bool(row.get("ts")))
check("ledger: registry min_envelope v/ts/host/source/kind present",
      all(row.get(k) not in (None, "") for k in ("v", "ts", "host", "source", "kind")))
raw = LEDGER.read_text() if LEDGER.exists() else ""
check("ledger: no key, query string, token or page body", all(s not in raw for s in ("KEY-abc123", "SECRET123", "token=", BODY_MARK)))

# documented cost (1) when the response carries no credits field
reset()
stub_urlopen([json.dumps({"success": True, "data": {"markdown": "# T\n\nbody"}})])
mod.FirecrawlClient("k", budget=5).scrape(URL)
check("ledger: documented cost 1 when response has no credits", (ledger_lines() or [{}])[0].get("credits") == 1)

# a transport failure spends nothing but is still attributable
reset()
stub_urlopen([OSError("boom")])
try:
    mod.FirecrawlClient("k", budget=5).scrape(URL)
except OSError:
    pass
row = (ledger_lines() or [{}])[0]
check("ledger: failed call logged with credits 0", row.get("credits") == 0 and row.get("ok") is False)

# --- jina reader ------------------------------------------------------------
reset()
stub_urlopen(["Title: Hello\n\nURL Source: https://example.com/post\n\nMarkdown Content:\n# Hello\n\nreal body text\n"])
md = mod.JinaReaderClient().scrape("https://example.com/post")
check("jina: GET https://r.jina.ai/<url>", SEEN and SEEN[0].full_url == "https://r.jina.ai/https://example.com/post" and SEEN[0].get_method() == "GET")
check("jina: sends no Authorization header", not SEEN[0].has_header("Authorization"))
check("jina: preamble stripped, markdown kept", md.startswith("# Hello") and "URL Source" not in md)
check("jina: spends no firecrawl ledger line", fc_lines() == [])
jl = ledger_lines()
check("jina: one jina-reader ledger line, 0 credits, endpoint /reader, no target url",
      len(jl) == 1 and jl[0]["source"] == "jina-reader" and jl[0]["credits"] == 0
      and jl[0]["endpoint"] == "/reader" and "example.com" not in LEDGER.read_text())
stub_urlopen(["Title: x\n\nMarkdown Content:\n   \n"])
try:
    mod.JinaReaderClient().scrape("https://example.com/post")
    check("jina: empty markdown raises", False)
except RuntimeError:
    check("jina: empty markdown raises", True)

# HIMMEL-4351 item 4: a 200 whose preamble reports the target's own error is
# an error page, not content — raise instead of writing it into the clip.
reset()
stub_urlopen(["Title: Just a moment\n\nURL Source: https://example.com/post\n\nWarning: Target URL returned error 403: Forbidden\n\nMarkdown Content:\nEnable JavaScript and cookies to continue\n"])
try:
    mod.JinaReaderClient().scrape("https://example.com/post")
    check("jina: 200 carrying a target-error warning raises", False)
except RuntimeError:
    check("jina: 200 carrying a target-error warning raises", True)
check("jina: that fetch is still ledgered (the call happened)", len(ledger_lines()) == 1)

# HIMMEL-4351 item 2: a 200 whose body does not parse as JSON still spent the
# call — ledger it at the documented cost, ok=false, not as a free transport error.
reset()
stub_urlopen(["<html>not json</html>"])
try:
    mod.FirecrawlClient("k", budget=5).scrape(URL)
except Exception:
    pass
row = (ledger_lines() or [{}])[0]
check("ledger: transport ok + parse failure counts the credit, ok=false",
      row.get("credits") == mod.FirecrawlClient.SCRAPE_COST and row.get("ok") is False)

# --- local-headless slot: Scrapling stealth fetcher (HIMMEL-4344) -----------
class FakePage:
    def __init__(self, status=200, html="<h1>Real</h1><p>body</p>", url=None):
        self.status = status
        self.html = html
        if url is not None:
            self.url = url


class FetchRecorder:
    """Stands in for scrapling's StealthyFetcher.fetch + the markdown step."""
    def __init__(self, page=None, exc=None):
        self.calls = []
        self.page = page or FakePage()
        self.exc = exc

    def fetch(self, url, **kw):
        self.calls.append((url, kw))
        if self.exc:
            raise self.exc
        return self.page

    def to_markdown(self, page):
        return "# Real\n\nbody\n" if page.html else ""


def install_local(rec):
    mod.LocalHeadlessClient._load = staticmethod(lambda: (rec.fetch, rec.to_markdown))


def uninstall_local():
    def missing():
        raise ImportError("no scrapling")
    mod.LocalHeadlessClient._load = staticmethod(missing)


COOKIES = SCRATCH / "cookies"
COOKIES.mkdir()
(COOKIES / "site.txt").write_text(
    "# Netscape HTTP Cookie File\n"
    ".example.com\tTRUE\t/\tTRUE\t9999999999\tsess\tlive1\n"
    ".example.com\tTRUE\t/\tTRUE\t1000000000\told\tdead\n"
    "#HttpOnly_.example.com\tTRUE\t/\tTRUE\t0\ttok\tlive2\n"
    ".example.com\tTRUE\t/\tTRUE\tgarbage\tbadexp\tstale\n"
    ".other.org\tTRUE\t/\tTRUE\t9999999999\tnope\tleak\n",
    encoding="utf-8", newline="\n")

rec = FetchRecorder()
install_local(rec)
c = mod.LocalHeadlessClient(cookie_dir=COOKIES)
md = c.scrape("https://www.example.com/a")
check("local-headless: returns markdown, no longer raises NotImplemented", "# Real" in md)
names_sent = sorted(x["name"] for x in rec.calls[0][1].get("cookies") or [])
check("local-headless: jar cookies for the host pass through (live + HttpOnly, not expired, not other domain)",
      names_sent == ["sess", "tok"])
sent = {x["name"]: x for x in rec.calls[0][1].get("cookies") or []}
check("local-headless: #HttpOnly_ cookies keep httpOnly, plain ones do not",
      sent["tok"].get("httpOnly") is True and not sent["sess"].get("httpOnly"))
check("local-headless: persistent cookies keep their expiry, session cookies are -1",
      sent["sess"].get("expires") == 9999999999 and sent["tok"].get("expires") == -1)
check("local-headless: a cookie with a malformed expiry is skipped, not revived as a session cookie",
      "badexp" not in sent)
check("local-headless: headless stealth fetch, bounded timeout",
      rec.calls[0][1].get("headless") is True and 0 < rec.calls[0][1].get("timeout", 0) <= 120000)
rec.calls.clear()
c.scrape("https://unrelated.net/")
check("local-headless: no cookie sent to a host the jar does not cover", not rec.calls[0][1].get("cookies"))
check("local-headless: missing cookie dir is no constraint",
      mod.LocalHeadlessClient(cookie_dir=SCRATCH / "nope").scrape("https://example.com/") != "")

for label, r, expect in (("HTTP 403", FetchRecorder(page=FakePage(status=403)), "HTTP 403"),
                         ("empty markdown", FetchRecorder(page=FakePage(html="")), "empty markdown"),
                         ("fetch error", FetchRecorder(exc=RuntimeError("boom")), "boom"),
                         ("redirect to a private host",
                          FetchRecorder(page=FakePage(url="http://nas.internal/admin")), "private host")):
    install_local(r)
    try:
        mod.LocalHeadlessClient(cookie_dir=COOKIES).scrape("https://example.com/")
        check(f"local-headless: {label} raises (chain falls through)", False)
    except mod.BackendNotImplemented:
        check(f"local-headless: {label} raises (chain falls through)", False)
    except Exception as e:
        check(f"local-headless: {label} raises (chain falls through)", expect in str(e))

# --- per-request private-host enforcement (HIMMEL-4477) ---------------------
class FakeRoute:
    def __init__(self, url):
        self.request = type("Req", (), {"url": url})()
        self.verdict = None

    def abort(self, *a, **k):
        self.verdict = "abort"

    def continue_(self, *a, **k):
        self.verdict = "continue"


class FakeCDP:
    """Stands in for a raw CDP session: records sends, fires Fetch.requestPaused."""
    def __init__(self):
        self.sent, self.handlers = [], {}

    def on(self, ev, fn):
        self.handlers[ev] = fn

    def send(self, method, params=None):
        self.sent.append((method, params or {}))

    def pause(self, url):
        self.sent.clear()
        self.handlers["Fetch.requestPaused"]({"requestId": "r1", "request": {"url": url}})
        return self.sent[-1][0]


class FakeBrowserPage:
    """Stands in for the Playwright page Scrapling hands to page_setup."""
    class _Ctx:
        def __init__(self, page):
            self.page = page

        def new_cdp_session(self, _page):
            self.page.cdp = FakeCDP()
            return self.page.cdp

    def __init__(self):
        self.routes = []
        self.ws_routes = []
        self.cdp = None
        self.context = FakeBrowserPage._Ctx(self)

    def route(self, pattern, handler):
        self.routes.append((pattern, handler))

    def route_web_socket(self, pattern, handler):
        self.ws_routes.append((pattern, handler))


def verdict_for(setup, url):
    bp = FakeBrowserPage()
    setup(bp)
    fr = FakeRoute(url)
    bp.routes[0][1](fr)
    return fr.verdict


rec = FetchRecorder()
install_local(rec)
mod.LocalHeadlessClient(cookie_dir=COOKIES).scrape("https://example.com/")
setup = rec.calls[0][1].get("page_setup")
check("local-headless: fetch registers a page_setup hook (route installed before navigation)", callable(setup))
if callable(setup):
    bp = FakeBrowserPage()
    setup(bp)
    check("local-headless: one catch-all route covers every request type", [p for p, _ in bp.routes] == ["**/*"])
    for label, u in (("loopback v4", "http://127.0.0.1:8080/x"),
                     ("localhost", "http://localhost/x"),
                     ("RFC1918 192.168", "http://192.168.1.5/x"),  # leak-allow: private-lan-ip test fixture asserting the RFC1918 deny rule
                     ("RFC1918 10.x", "http://10.0.0.9/x"),  # leak-allow: private-lan-ip test fixture asserting the RFC1918 deny rule
                     ("RFC1918 172.16", "http://172.16.4.2/x"),  # leak-allow: private-lan-ip test fixture asserting the RFC1918 deny rule
                     ("link-local metadata", "http://169.254.169.254/latest/meta-data/"),
                     ("loopback v6", "http://[::1]/x"),
                     ("IPv6 ULA", "http://[fd00::1]/x"),
                     ("IPv6 link-local", "http://[fe80::1]/x"),
                     ("IPv4-mapped IPv6", "http://[::ffff:10.0.0.1]/x"),  # leak-allow: private-lan-ip test fixture asserting the RFC1918 deny rule
                     ("decimal-encoded loopback", "http://2130706433/x"),
                     ("hex-encoded loopback", "http://0x7f.1/x"),
                     ("short-form loopback", "http://127.1/x"),
                     ("internal TLD", "http://nas.internal/x"),
                     ("websocket to a private host", "ws://127.0.0.1:9222/devtools"),
                     ("basic-auth userinfo on a private host", "http://user:pw@10.0.0.9/x")):  # leak-allow: private-lan-ip test fixture asserting the RFC1918 deny rule
        check(f"local-headless: request to {label} is aborted", verdict_for(setup, u) == "abort")
    for label, u in (("public subresource", "https://cdn.example.com/a.png"),
                     ("public page", "https://example.com/"),
                     ("public IP literal", "http://93.184.216.34/x"),
                     ("data: URI", "data:image/png;base64,AAAA"),
                     ("about:blank", "about:blank"),
                     ("blob: URL", "blob:https://example.com/1234")):
        check(f"local-headless: {label} still loads", verdict_for(setup, u) == "continue")

    class ExplodingRoute(FakeRoute):
        @property
        def request(self):
            raise RuntimeError("boom")

        @request.setter
        def request(self, v):
            pass
    bp = FakeBrowserPage()
    setup(bp)
    er = ExplodingRoute("http://x/")
    bp.routes[0][1](er)
    check("local-headless: a handler that cannot read the request fails closed (abort)", er.verdict == "abort")

    bp = FakeBrowserPage()
    setup(bp)
    check("local-headless: websocket route registered when Playwright offers it", [p for p, _ in bp.ws_routes] == ["**/*"])

    class FakeWS:
        def __init__(self, url):
            self.url, self.verdict = url, None

        def close(self, *a, **k):
            self.verdict = "close"

        def connect_to_server(self):
            self.verdict = "connect"
    for u, want in (("ws://127.0.0.1:9222/x", "close"), ("wss://cdn.example.com/live", "connect")):
        w = FakeWS(u)
        bp.ws_routes[0][1](w)
        check(f"local-headless: websocket {u} -> {want}", w.verdict == want)

    # redirect hops: page.route never sees them, CDP Fetch.requestPaused does
    bp = FakeBrowserPage()
    setup(bp)
    check("local-headless: CDP Fetch.enable at Request stage covers redirect hops",
          ("Fetch.enable", {"patterns": [{"urlPattern": "*", "requestStage": "Request"}]}) in bp.cdp.sent)
    for u, want in (("http://169.254.169.254/latest/meta-data/", "Fetch.failRequest"),
                    ("http://127.0.0.1:8080/secret", "Fetch.failRequest"),
                    ("https://example.com/next", "Fetch.continueRequest")):
        check(f"local-headless: redirect hop {u} -> {want}", bp.cdp.pause(u) == want)

    class NoWsPage(FakeBrowserPage):
        route_web_socket = property(lambda self: (_ for _ in ()).throw(AttributeError("route_web_socket")))
    try:
        setup(NoWsPage())
        check("local-headless: no websocket routing -> hook raises (fails closed)", False)
    except RuntimeError:
        check("local-headless: no websocket routing -> hook raises (fails closed)", True)

uninstall_local()
try:
    mod.LocalHeadlessClient(cookie_dir=COOKIES).scrape("https://example.com/")
    check("local-headless: scrapling not installed -> BackendNotImplemented", False)
except mod.BackendNotImplemented:
    check("local-headless: scrapling not installed -> BackendNotImplemented", True)

# --- chain: order, silent fall-through, budget ------------------------------
check("chain default order local-headless,jina,firecrawl",
      [b.name for b in mod.build_scrape_chain({"FIRECRAWL_API_KEY": "k"}, 5).backends] == ["local-headless", "jina", "firecrawl"])
check("chain: no firecrawl key drops firecrawl, keeps jina",
      [b.name for b in mod.build_scrape_chain({}, 5).backends] == ["local-headless", "jina"])
check("chain: env selects a single backend",
      [b.name for b in mod.build_scrape_chain({"HARVEST_SCRAPE_BACKEND": "jina"}, 5).backends] == ["jina"])
try:
    mod.build_scrape_chain({"HARVEST_SCRAPE_BACKEND": "bogus"}, 5)
    check("chain: unknown backend name rejected", False)
except ValueError:
    check("chain: unknown backend name rejected", True)

reset()
stub_urlopen(["Markdown Content:\n# From jina\n\nbody\n"])
chain = mod.build_scrape_chain({"FIRECRAWL_API_KEY": "k"}, 5)
md = chain.scrape("https://example.com/post")
check("chain: not-implemented local-headless falls through silently to jina", "From jina" in md and chain.last_backend == "jina")
check("chain: jina success never touches firecrawl", fc_lines() == [] and len(SEEN) == 1)

reset()
stub_urlopen([OSError("jina down"), json.dumps({"success": True, "data": {"markdown": "# From fc\n\nbody"}})])
chain = mod.build_scrape_chain({"FIRECRAWL_API_KEY": "k"}, 5)
md = chain.scrape("https://example.com/post")
check("chain: jina failure falls to firecrawl", "From fc" in md and chain.last_backend == "firecrawl")
check("chain: firecrawl hop is ledgered", len(fc_lines()) == 1)

reset()
stub_urlopen([OSError("jina down")])
chain = mod.build_scrape_chain({}, 5)
try:
    chain.scrape("https://example.com/post")
    check("chain: all backends failed raises", False)
except Exception:
    check("chain: all backends failed raises", True)

# firecrawl's own cap holds even when the run cap allows more
reset()
stub_urlopen([OSError("j"), json.dumps({"success": True, "data": {"markdown": "ok\n\nbody"}}),
              OSError("j")])
chain = mod.build_scrape_chain({"FIRECRAWL_API_KEY": "k", "HARVEST_SCRAPE_BACKEND": "jina,firecrawl"}, 1)
chain.scrape("https://example.com/a")
try:
    chain.scrape("https://example.com/b")
except Exception:
    pass
check("chain: firecrawl capped at its budget (second run call spends nothing)", len(fc_lines()) == 1)

# repeated backend names mint one client (one firecrawl budget)
check("chain: duplicate backend names collapse",
      [b.name for b in mod.build_scrape_chain({"FIRECRAWL_API_KEY": "k", "HARVEST_SCRAPE_BACKEND": "firecrawl,firecrawl"}, 5).backends] == ["firecrawl"])

# wrong-shaped but valid JSON is ledgered once and raises cleanly
reset()
stub_urlopen([json.dumps({"success": True, "data": "not-an-object"})])
try:
    mod.FirecrawlClient("k", budget=5).scrape(URL)
    check("firecrawl: wrong-shape response raises", False)
except RuntimeError:
    check("firecrawl: wrong-shape response raises", True)
check("firecrawl: wrong-shape response ledgered exactly once", len(fc_lines()) == 1)

# --- process_clip: gate + marker with the chain -----------------------------
THIN = "---\ntype: article\nsource: https://example.com/post\n---\nshort.\n"


def make_clip(text):
    p = Path(tempfile.mkdtemp(dir=str(SCRATCH))) / "clip.md"
    p.write_text(text, encoding="utf-8", newline="\n")
    return p


class FakeChain:
    def __init__(self):
        self.remaining = 5
        self.calls = []
        self.last_backend = "jina"

    def scrape(self, url):
        self.calls.append(url)
        return "# Real\n\nclean body\n"


p = make_clip(THIN)
fk = FakeChain()
glyph, msg, _ = mod.process_clip(p, False, fk, mod.UrlRules())
check("process_clip: thin eligible clip harvested via the serving backend",
      glyph == "v" and "harvest_skill: jina" in p.read_text() and "via jina" in msg)

p = make_clip("---\ntype: article\nsource: http://wiki.corp.internal/x\n---\nshort.\n")
fk = FakeChain()
mod.process_clip(p, False, fk, mod.UrlRules())
check("process_clip: G-1 privacy gate holds on the chain (private host not sent)", fk.calls == [])
p = make_clip("---\ntype: article\nsource: https://x.com/a/status/1\n---\nshort.\n")
fk = FakeChain()
mod.process_clip(p, False, fk, mod.UrlRules())
check("process_clip: skip-host list holds on the chain", fk.calls == [])

# the real chain with the local-headless slot live: gate + skip-host run first
rec = FetchRecorder()
install_local(rec)
real = mod.ScrapeChain([mod.LocalHeadlessClient(cookie_dir=COOKIES)], 5)
p = make_clip(THIN)
glyph, msg, _ = mod.process_clip(p, False, real, mod.UrlRules())
check("process_clip: local-headless serves a thin clip", glyph == "v" and "harvest_skill: local-headless" in p.read_text())
for label, src in (("private host", "http://wiki.corp.internal/x"), ("skip-host", "https://x.com/a/status/1")):
    rec.calls.clear()
    mod.process_clip(make_clip(f"---\ntype: article\nsource: {src}\n---\nshort.\n"), False, real, mod.UrlRules())
    check(f"process_clip: {label} never reaches local-headless", rec.calls == [])
rec.calls.clear()
mod.process_clip(make_clip(THIN), False, real, mod.UrlRules(deny=[("example.com/**", mod._glob_to_regex(mod._norm_target("example.com/**", True)[0]))]))
check("process_clip: .harvest-deny never reaches local-headless", rec.calls == [])
uninstall_local()

# --- HIMMEL-4361: registry, per-site routing, kill switch, caps -------------
import contextlib

FC_OK = json.dumps({"success": True, "data": {"markdown": "# From fc\n\nbody"}})


def fc_credits(n):
    return json.dumps({"success": True, "data": {"markdown": "# From fc\n\nbody",
                                                 "metadata": {"creditsUsed": n}}})


def vault_with(routing_text):
    v = Path(tempfile.mkdtemp(dir=str(SCRATCH)))
    (v / ".harvest-backends").write_text(routing_text, encoding="utf-8")
    return v


def names(chain, url):
    return [b.name for b in chain.backends_for(url)]


KEYED = {"FIRECRAWL_API_KEY": "k"}

# registry: one table, every lookup resolves through it
reg = mod.BACKEND_REGISTRY
check("registry: local-headless, jina, firecrawl registered", set(reg) == {"local-headless", "jina", "firecrawl"})
check("registry: rows carry needs_key, cap and egress_host",
      all(hasattr(r, a) for r in reg.values() for a in ("cls", "needs_key", "cap", "egress_host")))
check("registry: only firecrawl needs a key and has a cap",
      [n for n, r in reg.items() if r.needs_key] == ["firecrawl"] and [n for n, r in reg.items() if r.cap] == ["firecrawl"])
check("registry: DEFAULT_SCRAPE_BACKENDS is the registry's order", tuple(reg) == mod.DEFAULT_SCRAPE_BACKENDS)
try:
    mod.build_scrape_chain({"HARVEST_SCRAPE_BACKEND": "bogus"}, 5)
    check("registry: unknown env name error names the valid set", False)
except ValueError as e:
    check("registry: unknown env name error names the valid set", "bogus" in str(e) and "jina" in str(e) and "firecrawl" in str(e))

# (a) per-site routing
v = vault_with(
    "# comment\n"
    "example.com/** skip=jina\n"
    "docs.example.org/** only=jina  # trailing comment\n"
    "**.example.net/** skip=jina\n"
    "first.test/** only=firecrawl\n"
    "first.test/** only=jina\n")
routes = mod.load_backend_routes(v)
chain = mod.build_scrape_chain(KEYED, 5)
chain.routes = routes
check("routing: skip= removes a backend for a matching URL", names(chain, "https://example.com/a") == ["local-headless", "firecrawl"])
check("routing: non-matching URL keeps the global order", names(chain, "https://other.com/a") == ["local-headless", "jina", "firecrawl"])
check("routing: only= restricts to the named backend", names(chain, "https://docs.example.org/a") == ["jina"])
check("routing: first matching line wins", names(chain, "https://first.test/a") == ["firecrawl"])
check("routing: no routing file is no constraint",
      names(mod.build_scrape_chain(KEYED, 5), "https://example.com/a") == ["local-headless", "jina", "firecrawl"])
check("routing: globs normalise like .harvest-deny (case, trailing dot, dot-segments)",
      names(chain, "https://EXAMPLE.com./x/../a") == ["local-headless", "firecrawl"])
_c = mod.build_scrape_chain({}, 5)
_c.routes = mod.load_backend_routes(vault_with("x.test/** only=firecrawl\n"))
check("routing: only= never re-adds a backend the key gate dropped", names(_c, "https://x.test/") == [])

# routing file fails closed
for label, text in (("unknown backend name", "example.com/** skip=bogus\n"),
                    ("malformed line", "example.com/**\n"),
                    ("neither skip nor only", "example.com/** prefer=jina\n"),
                    ("empty name list", "example.com/** only=\n")):
    r = mod.load_backend_routes(vault_with(text))
    reset()
    stub_urlopen(["Markdown Content:\n# x\n\nbody\n"])
    c = mod.build_scrape_chain(KEYED, 5)
    c.routes = r
    try:
        c.scrape("https://other.com/a")
        sent = True
    except Exception:
        sent = bool(SEEN)
    check(f"routing: {label} fails closed (nothing sent, even for a non-matching URL)", r.error and not sent)
dv = Path(tempfile.mkdtemp(dir=str(SCRATCH)))
(dv / ".harvest-backends").mkdir()
r = mod.load_backend_routes(dv)
reset()
stub_urlopen(["Markdown Content:\n# x\n\nbody\n"])
c = mod.build_scrape_chain(KEYED, 5)
c.routes = r
try:
    c.scrape("https://other.com/a")
except Exception:
    pass
check("routing: unreadable file fails closed (nothing sent)", r.error and not SEEN)

# deny and odd-host precedence over routing
RULES = mod.UrlRules(deny=[("example.com/**", mod._glob_to_regex(mod._norm_target("example.com/**", True)[0]))])
reset()
stub_urlopen(["Markdown Content:\n# x\n\nbody\n"])
c = mod.build_scrape_chain(KEYED, 5)
c.routes = mod.load_backend_routes(vault_with("example.com/** only=jina\n"))
p = make_clip(THIN)
glyph, msg, _ = mod.process_clip(p, False, c, RULES)
check("precedence: .harvest-deny wins over an only= line (no backend called)", glyph == "o" and not SEEN)
reset()
stub_urlopen(["Markdown Content:\n# x\n\nbody\n"])
c = mod.build_scrape_chain(KEYED, 5)
c.routes = mod.load_backend_routes(vault_with("**/** only=jina\n"))
p = make_clip("---\ntype: article\nsource: https://ex%41mple.com/post\n---\nshort.\n")
glyph, msg, _ = mod.process_clip(p, False, c, mod.UrlRules())
check("precedence: odd-host refusal wins over an only= line (no backend called)", glyph == "o" and not SEEN)

# (b) global kill switch
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_DENY": "firecrawl"}, 5)
check("kill switch: HARVEST_SCRAPE_DENY removes the backend", [b.name for b in c.backends] == ["local-headless", "jina"])
c.routes = mod.load_backend_routes(vault_with("example.com/** only=firecrawl\n"))
check("kill switch: beats a routing only= line", names(c, "https://example.com/a") == [])
reset()
try:
    c.scrape("https://example.com/a")
except Exception:
    pass
check("kill switch: a killed backend is never called", not SEEN)
check("kill switch: all removes every backend",
      mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_DENY": "all"}, 5).backends == [])
check("kill switch: beats HARVEST_SCRAPE_BACKEND order",
      [b.name for b in mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl,jina", "HARVEST_SCRAPE_DENY": "firecrawl"}, 5).backends] == ["jina"])
try:
    mod.build_scrape_chain({"HARVEST_SCRAPE_DENY": "bogus"}, 5)
    check("kill switch: unknown name errors naming the valid set", False)
except ValueError as e:
    check("kill switch: unknown name errors naming the valid set", "HARVEST_SCRAPE_DENY" in str(e) and "jina" in str(e))
try:
    mod.build_scrape_chain({"HARVEST_SCRAPE_DENY": "all,bogus"}, 5)
    check("kill switch: `all` does not mask an unknown name", False)
except ValueError:
    check("kill switch: `all` does not mask an unknown name", True)

# (b) per-run call cap: env sets it, the flag wins, default unchanged
check("cap: default is today's value", mod.resolve_firecrawl_budget(None, {}) == mod.FIRECRAWL_DEFAULT_BUDGET == 20)
check("cap: HARVEST_FIRECRAWL_BUDGET sets it", mod.resolve_firecrawl_budget(None, {"HARVEST_FIRECRAWL_BUDGET": "3"}) == 3)
check("cap: --firecrawl-budget flag wins over env", mod.resolve_firecrawl_budget(7, {"HARVEST_FIRECRAWL_BUDGET": "3"}) == 7)
for bad in ("abc", "-1"):
    try:
        mod.resolve_firecrawl_budget(None, {"HARVEST_FIRECRAWL_BUDGET": bad})
        check(f"cap: invalid env {bad!r} errors", False)
    except ValueError:
        check(f"cap: invalid env {bad!r} errors", True)
reset()
stub_urlopen([OSError("j"), FC_OK, OSError("j"), FC_OK])
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "jina,firecrawl"}, mod.resolve_firecrawl_budget(None, {"HARVEST_FIRECRAWL_BUDGET": "1"}))
c.scrape("https://example.com/a")
try:
    c.scrape("https://example.com/b")
except Exception:
    pass
check("cap: a budget of 1 allows exactly one firecrawl call", len(fc_lines()) == 1)

# (b) per-call credit ceiling
reset()
stub_urlopen([OSError("j"), fc_credits(30), OSError("j"), FC_OK])
err = io.StringIO()
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "jina,firecrawl"}, 20)
with contextlib.redirect_stderr(err):
    first = c.scrape("https://example.com/a")
    try:
        c.scrape("https://example.com/b")
    except Exception:
        pass
check("ceiling: the call that tripped it is still returned (cannot be refunded)", "From fc" in first)
check("ceiling: a call over the ceiling stops firecrawl for the rest of the run", len(fc_lines()) == 1)
check("ceiling: the trip is logged to stderr", "firecrawl" in err.getvalue() and "30" in err.getvalue())
reset()
stub_urlopen([OSError("j"), fc_credits(5), OSError("j"), FC_OK])
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "jina,firecrawl"}, 20)
c.scrape("https://example.com/a")
c.scrape("https://example.com/b")
check("ceiling: a call AT the default ceiling (5, a stealth call) does not trip it", len(fc_lines()) == 2)
reset()
stub_urlopen([OSError("j"), fc_credits(3), OSError("j"), FC_OK])
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "jina,firecrawl", "HARVEST_FIRECRAWL_MAX_CREDITS": "2"}, 20)
with contextlib.redirect_stderr(io.StringIO()):
    c.scrape("https://example.com/a")
    try:
        c.scrape("https://example.com/b")
    except Exception:
        pass
check("ceiling: HARVEST_FIRECRAWL_MAX_CREDITS overrides the default", len(fc_lines()) == 1)
try:
    mod.build_scrape_chain({**KEYED, "HARVEST_FIRECRAWL_MAX_CREDITS": "x"}, 5)
    check("ceiling: invalid env errors", False)
except ValueError:
    check("ceiling: invalid env errors", True)

# stealth/proxy only when explicitly enabled
reset()
stub_urlopen([FC_OK])
mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl"}, 5).scrape("https://example.com/a")
sent = json.loads(SEEN[0].data.decode())
check("stealth: default payload carries no proxy/stealth option", set(sent) == {"url", "formats"})
reset()
stub_urlopen([FC_OK])
mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl", "HARVEST_FIRECRAWL_STEALTH": "1"}, 5).scrape("https://example.com/a")
check("stealth: HARVEST_FIRECRAWL_STEALTH=1 sends proxy=stealth", json.loads(SEEN[0].data.decode()).get("proxy") == "stealth")
# HIMMEL-4370 (B): stealth costs 5, so a ceiling below 5 refuses stealth before any call
reset()
stub_urlopen([FC_OK])
try:
    mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl", "HARVEST_FIRECRAWL_STEALTH": "1",
                            "HARVEST_FIRECRAWL_MAX_CREDITS": "4"}, 20)
    refused = False
except ValueError as e:
    refused = "HARVEST_FIRECRAWL_MAX_CREDITS" in str(e) and "stealth" in str(e)
check("stealth: a ceiling below 5 refuses stealth at config time, naming both knobs", refused)
try:
    mod.FirecrawlClient("k", stealth=True, max_credits=4)
    refused = False
except ValueError:
    refused = True
check("stealth: a client built with stealth and a ceiling below 5 is refused", refused)
check("stealth: the refusal made no HTTP call and no ledger row", not SEEN and not fc_lines())
reset()
stub_urlopen([FC_OK])
mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl", "HARVEST_FIRECRAWL_STEALTH": "1",
                        "HARVEST_FIRECRAWL_MAX_CREDITS": "5"}, 20).scrape("https://example.com/a")
check("stealth: a ceiling of exactly 5 allows stealth", len(fc_lines()) == 1)

# the parse-failure path books the known cost too, so it must honour the ceiling as well
reset()
stub_urlopen(["<html>not json</html>", FC_OK])
c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "firecrawl", "HARVEST_FIRECRAWL_MAX_CREDITS": "0"}, 20)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    for u in ("https://example.com/a", "https://example.com/b"):
        try:
            c.scrape(u)
        except Exception:
            pass
check("ceiling: a parse failure (cost 1) trips a ceiling of 0", len(fc_lines()) == 1)
# HIMMEL-4368: the same stderr line as the valid-JSON path
check("ceiling: the parse-failure trip prints the same stderr line as the valid-JSON path",
      "harvest-clip-body-batch: firecrawl call cost 1 credits (ceiling 0); firecrawl disabled for the rest of this run"
      in err.getvalue())

# HIMMEL-4370 (A): a present but non-integer creditsUsed counts as over the ceiling
for label, val in (("float 30.0", 30.0), ("string '30'", "30"), ("bool true", True), ("null", None), ("float 2.5", 2.5)):
    reset()
    stub_urlopen([OSError("j"), json.dumps({"success": True, "data": {"markdown": "# From fc\n\nbody",
                                                                    "metadata": {"creditsUsed": val}}}),
                  OSError("j"), FC_OK])
    c = mod.build_scrape_chain({**KEYED, "HARVEST_SCRAPE_BACKEND": "jina,firecrawl"}, 20)
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        c.scrape("https://example.com/a")
        try:
            c.scrape("https://example.com/b")
        except Exception:
            pass
    check(f"ceiling: creditsUsed {label} is over the ceiling (firecrawl stops, line logged)",
          len(fc_lines()) == 1 and "disabled for the rest of this run" in err.getvalue())

# HIMMEL-4370 (C): strict integer env parsing, identical to the JS side (ASCII digits only)
for bad in ("+5", "1_0", "５", "-1", "5.0", "0x5"):
    for key in ("HARVEST_FIRECRAWL_MAX_CREDITS", "HARVEST_FIRECRAWL_BUDGET"):
        try:
            mod._env_int({key: bad}, key, 7)
            ok = False
        except ValueError:
            ok = True
        check(f"env int: {key}={bad!r} is rejected", ok)
check("env int: surrounding whitespace and leading zeros are accepted", mod._env_int({"K": " 007 "}, "K", 1) == 7)
check("env int: unset or blank falls back", mod._env_int({}, "K", 3) == 3 and mod._env_int({"K": "  "}, "K", 3) == 3)

# HIMMEL-4370 (E): the JS side's name list stays in sync with BACKEND_REGISTRY
import re
mjs = (TOOL.parent / "lib" / "follow-web.mjs").read_text(encoding="utf-8")
m = re.search(r"export const SCRAPE_BACKEND_NAMES = \[([^\]]*)\]", mjs)
js_names = re.findall(r'"([^"]+)"', m.group(1)) if m else None
check("sync: SCRAPE_BACKEND_NAMES (follow-web.mjs) equals list(BACKEND_REGISTRY), same order",
      js_names == list(mod.BACKEND_REGISTRY))

# no key: jina alone, silently
err = io.StringIO()
with contextlib.redirect_stderr(err):
    c = mod.build_scrape_chain({}, 5)
check("no key: jina-only chain, nothing on stderr",
      [b.name for b in c.backends] == ["local-headless", "jina"] and err.getvalue() == "")

# --- HIMMEL-4371: firecrawl unavailable (402/429) parks, never loses ---------
import contextlib
import urllib.error

PARKED = SCRATCH / "parked.jsonl"
os.environ["HIMMEL_FIRECRAWL_PARKED"] = str(PARKED)
os.environ["FIRECRAWL_API_KEY"] = "k"
os.environ["HARVEST_SCRAPE_BACKEND"] = "jina,firecrawl"


class Net:
    scrape_calls = 0
    usage_calls = 0
    scrape = "402"  # 402 | 429 | ok
    jina = "fail"  # fail | ok
    remaining = 0
    reset = "2026-11-01T00:00:00Z"
    usage_fail = False


def net_open(req, timeout=None):
    url = req.full_url if hasattr(req, "full_url") else req
    if "r.jina.ai" in url:
        if Net.jina == "ok":
            return Resp(b"Markdown Content:\n# J\n\njina body\n")
        raise OSError("jina down")
    if url.endswith("/v2/team/credit-usage"):
        Net.usage_calls += 1
        if Net.usage_fail:
            raise OSError("usage down")
        return Resp(json.dumps({"success": True, "data": {
            "remainingCredits": Net.remaining, "planCredits": 1000,
            "billingPeriodStart": None, "billingPeriodEnd": Net.reset}}).encode())
    if url.endswith("/v2/scrape"):
        Net.scrape_calls += 1
        if Net.scrape in ("402", "429"):
            body = b'{"success":false,"error":"Insufficient credits to perform this request."}' if Net.scrape == "402" else b'{"success":false,"error":"Rate limit exceeded for your request quota"}'
            raise urllib.error.HTTPError(url, int(Net.scrape), "x", {}, io.BytesIO(body))
        return Resp(json.dumps({"success": True, "data": {"markdown": "# FC\n\nfirecrawl body", "metadata": {"creditsUsed": 1}}}).encode())
    raise AssertionError("unexpected url " + url)


urllib.request.urlopen = net_open


def parked_rows():
    if not PARKED.exists():
        return []
    return [json.loads(l) for l in PARKED.read_text().splitlines() if l.strip()]


def mkvault(n, deny=None):
    v = Path(tempfile.mkdtemp(dir=str(SCRATCH)))
    (v / "Clippings").mkdir()
    for i in range(n):
        (v / "Clippings" / f"c{i}.md").write_text(
            f"---\ntype: article\nsource: https://example.com/post{i}\n---\nshort.\n", encoding="utf-8", newline="\n")
    if deny:
        (v / ".harvest-deny").write_text(deny, encoding="utf-8")
    return v


def run_main(vault, *extra):
    sys.argv = ["h", str(vault), "--firecrawl-thin", *extra]
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            mod.main()
        except SystemExit:
            pass
    return out.getvalue(), err.getvalue()


# 1. a 402 disables firecrawl after ONE call and parks every item that needed it
v = mkvault(3)
Net.scrape, Net.jina, Net.remaining = "402", "fail", 0
out, err = run_main(v)
rows = parked_rows()
parked = [r for r in rows if r["kind"] == "parked"]
unav = [r for r in rows if r["kind"] == "unavailable"]
check("402: firecrawl is called once, not once per item", Net.scrape_calls == 1)
check("402: one stderr line, not one per item", err.count("firecrawl unavailable") == 1)
check("402: all 3 items parked", len(parked) == 3 and {r["item"] for r in parked} == {"Clippings/c0.md", "Clippings/c1.md", "Clippings/c2.md"})
check("402: one unavailable row, reason exhausted, reset from billingPeriodEnd",
      len(unav) == 1 and unav[0]["reason"] == "exhausted" and unav[0]["reset"] == "2026-11-01T00:00:00Z")
check("402: rows carry the standard envelope",
      all(all(k in r for k in ("v", "ts", "host", "source", "kind")) for r in rows))
check("402: clips stay eligible (no harvested_at, not failed)",
      all("harvested_at" not in (v / "Clippings" / f"c{i}.md").read_text() for i in range(3)) and "FAIL" not in err)
check("402: ledger row for the failed call carries the reason",
      any(l.get("reason") == "exhausted" and l.get("ok") is False for l in ledger_lines()))

# 2. still exhausted: the probe says 0, so ZERO scrape calls and nothing is double-parked
Net.scrape_calls = Net.usage_calls = 0
Net.scrape, Net.remaining = "ok", 0
run_main(v)
check("exhausted run: probe made, 0 scrape calls", Net.usage_calls >= 1 and Net.scrape_calls == 0)
check("exhausted run: items stay parked, not duplicated", len([r for r in parked_rows() if r["kind"] == "parked"]) == 3)
check("exhausted run: nothing resolved", not [r for r in parked_rows() if r["kind"] == "resolved"])

# 3. credit-usage probe fails: fall back to ONE attempt
Net.scrape_calls = Net.usage_calls = 0
Net.usage_fail, Net.scrape = True, "ok"
run_main(v)
check("probe failure: exactly one firecrawl attempt", Net.scrape_calls == 1)
Net.usage_fail = False

# 4. recovery: parked items retried FIRST (limit 1 picks a parked clip), then resolved
v2 = mkvault(2)
Net.scrape, Net.jina, Net.remaining, Net.scrape_calls = "402", "fail", 0, 0
run_main(v2, "--limit", "1")  # c0 parked, c1 untouched
first = [r for r in parked_rows() if r["kind"] == "parked" and r["vault"] == str(v2)]
check("limit 1 parks only the first clip", [r["item"] for r in first] == ["Clippings/c0.md"])
Net.scrape, Net.remaining, Net.scrape_calls = "ok", 500, 0
run_main(v2, "--limit", "1")
check("recovery: the parked clip (c0) is retried before the untouched one",
      "harvested_at" in (v2 / "Clippings" / "c0.md").read_text() and "harvested_at" not in (v2 / "Clippings" / "c1.md").read_text())
check("recovery: parked row resolved + an available row written",
      any(r["kind"] == "resolved" and r["item"] == "Clippings/c0.md" for r in parked_rows())
      and any(r["kind"] == "available" for r in parked_rows()))

# 5. ANY success resolves (jina), a vanished file resolves as gone
v3 = mkvault(2)
Net.scrape, Net.jina, Net.remaining = "402", "fail", 0
run_main(v3)
(v3 / "Clippings" / "c1.md").unlink()
Net.jina = "ok"
run_main(v3)
res = {r["item"]: r for r in parked_rows() if r["kind"] == "resolved" and r["vault"] == str(v3)}
check("jina success resolves the parked clip", res.get("Clippings/c0.md", {}).get("via") == "jina")
check("a parked clip whose file is gone resolves as gone", res.get("Clippings/c1.md", {}).get("via") == "gone")

# 6. 429 parks for the next run but claims no reset date
v4 = mkvault(1)
Net.scrape, Net.jina, Net.remaining = "429", "fail", 100
before = len(parked_rows())
run_main(v4)
new = parked_rows()[before:]
check("429: reason rate-limited, no reset date claimed",
      any(r["kind"] == "unavailable" and r["reason"] == "rate-limited" and not r.get("reset") for r in new))
check("429: item parked", any(r["kind"] == "parked" and r["vault"] == str(v4) for r in new))

# 7. the G-1 gate runs first: a denied URL is never parked
v5 = mkvault(1, deny="https://example.com/**\n")
Net.scrape, Net.jina = "402", "fail"
before = len(parked_rows())
run_main(v5)
check("denied URL is never parked", not [r for r in parked_rows()[before:] if r["kind"] == "parked"])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
