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
glyph, msg, _ = mod.process_clip(p, False, fk)
check("process_clip: thin eligible clip harvested via the serving backend",
      glyph == "v" and "harvest_skill: jina" in p.read_text() and "via jina" in msg)

p = make_clip("---\ntype: article\nsource: http://wiki.corp.internal/x\n---\nshort.\n")
fk = FakeChain()
mod.process_clip(p, False, fk)
check("process_clip: G-1 privacy gate holds on the chain (private host not sent)", fk.calls == [])
p = make_clip("---\ntype: article\nsource: https://x.com/a/status/1\n---\nshort.\n")
fk = FakeChain()
mod.process_clip(p, False, fk)
check("process_clip: skip-host list holds on the chain", fk.calls == [])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
