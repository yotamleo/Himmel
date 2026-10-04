"""Scrape-provider adapters for the HIMMEL-4362 benchmark. A provider is an
object with `name`, `calls`, `last_credits` and `scrape(url) -> markdown`
(raises on failure). Stdlib only. Never logs a key, a URL or a body."""
import datetime
import json
import os
import shlex
import socket
import subprocess
import urllib.request
from pathlib import Path


class NeedsAuth(Exception):
    """The channel wants cookies or a login; the bench marks the row needs-auth."""


class CapReached(Exception):
    """The provider's call cap is spent; the bench marks the row skipped-cap."""


class Provider:
    name = "base"

    def __init__(self):
        self.calls = 0
        self.last_credits = 0

    def scrape(self, url):
        raise NotImplementedError


class JinaProvider(Provider):
    """Request shape of JinaReaderClient (harvest-clip-body-batch.py): GET
    r.jina.ai/<url>, keep the text after 'Markdown Content:'. Keyless."""
    name = "jina"
    BASE = "https://r.jina.ai/"

    def __init__(self, timeout=45):
        super().__init__()
        self.timeout = timeout

    def scrape(self, url):
        self.calls += 1
        req = urllib.request.Request(self.BASE + url, method="GET", headers={"Accept": "text/plain"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
        marker = "Markdown Content:"
        idx = text.find(marker)
        return text[idx + len(marker):].strip() if idx >= 0 else text.strip()


def ledger_path():
    override = os.environ.get("HIMMEL_FIRECRAWL_LEDGER", "").strip()
    if override:
        return Path(override)
    return Path(os.environ.get("HOME") or Path.home()) / ".himmel" / "state" / "firecrawl-ledger.jsonl"


def ledger_append(credits, ok):
    """Same row schema as harvest-clip-body-batch.py; never key, URL or body."""
    row = {"v": 1, "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "host": socket.gethostname(), "source": "firecrawl", "kind": "call",
           "call_site": "scrape-bench", "endpoint": "/v2/scrape", "credits": credits, "ok": ok}
    try:
        lp = ledger_path()
        lp.parent.mkdir(parents=True, exist_ok=True)
        with open(lp, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass


class FirecrawlProvider(Provider):
    """POST /v2/scrape. The key comes ONLY from FIRECRAWL_API_KEY in this
    process's env. Every attempt that reaches the API counts against max_calls
    (no retries here, so one URL is one call)."""
    name = "firecrawl"
    BASE = "https://api.firecrawl.dev"

    def __init__(self, max_calls, timeout=60):
        super().__init__()
        self.key = os.environ.get("FIRECRAWL_API_KEY", "").strip()
        if not self.key:
            raise SystemExit("FIRECRAWL_API_KEY is unset or blank in this environment")
        self.max_calls = max_calls
        self.timeout = timeout

    def scrape(self, url):
        self.last_credits = 0
        if self.calls >= self.max_calls:
            raise CapReached()
        self.calls += 1
        req = urllib.request.Request(
            self.BASE + "/v2/scrape",
            data=json.dumps({"url": url, "formats": ["markdown"]}).encode("utf-8"), method="POST",
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except Exception:
            ledger_append(0, False)
            raise
        body = data.get("data") if isinstance(data, dict) else None
        body = body if isinstance(body, dict) else {}
        meta = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
        used = meta.get("creditsUsed")
        ok = isinstance(data, dict) and bool(data.get("success"))
        self.last_credits = used if isinstance(used, int) else 1
        ledger_append(self.last_credits, ok)
        md = body.get("markdown")
        if not ok or not isinstance(md, str) or not md.strip():
            raise RuntimeError("firecrawl no markdown")
        return md


class CommandProvider(Provider):
    """Any engine with a CLI: template like 'agent-reach read {url}' (run in
    the VM's venv). stdout is the markdown. Exit code 77 or a stderr line
    containing 'login required'/'cookie' maps to needs-auth."""

    def __init__(self, name, template, timeout=120):
        super().__init__()
        self.name = name
        self.template = template
        self.timeout = timeout

    def scrape(self, url):
        self.calls += 1
        argv = [a.replace("{url}", url) for a in shlex.split(self.template)]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout)
        err = (p.stderr or "").lower()
        if p.returncode == 77 or "cookie" in err or "login required" in err:
            raise NeedsAuth()
        if p.returncode != 0:
            raise RuntimeError("exit %d" % p.returncode)
        return p.stdout.strip()
