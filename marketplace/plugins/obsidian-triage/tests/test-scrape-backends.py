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

# --- local-headless slot: named, not implemented ----------------------------
try:
    mod.LocalHeadlessClient().scrape("https://example.com/")
    check("local-headless: not implemented", False)
except mod.BackendNotImplemented:
    check("local-headless: not implemented", True)

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

# no key: jina alone, silently
err = io.StringIO()
with contextlib.redirect_stderr(err):
    c = mod.build_scrape_chain({}, 5)
check("no key: jina-only chain, nothing on stderr",
      [b.name for b in c.backends] == ["local-headless", "jina"] and err.getvalue() == "")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
