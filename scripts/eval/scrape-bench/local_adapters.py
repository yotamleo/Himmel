#!/usr/bin/env python3
"""Local, zero-credit provider adapters for the bench (HIMMEL-4362 round 2).
Run through the bench's command provider:

  bench.py --provider cmd --name scrapling-static --cmd 'python3 local_adapters.py scrapling-static {url}'

Modes: scrapling-static, scrapling-stealth, lightpanda, camofox. Each prints
markdown to stdout. On failure it exits 1 and writes one stderr line
`http=<code>` (an HTTP status >= 400) or `err=<ClassName>`, which the bench
records in the row's error field. Binaries come from env (SCRAPLING_BIN,
LIGHTPANDA_BIN, CAMOFOX_URL); nothing here reads a key, cookie or proxy.
Stdlib only."""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

TIMEOUT = 100


def scrapling_status(stderr):
    """Last `Fetched (NNN)` status Scrapling logged, or None."""
    found = re.findall(r"Fetched \((\d{3})\)", stderr or "")
    return int(found[-1]) if found else None


def lightpanda_result(raw):
    """(markdown, http_status, error) from `lightpanda fetch --json --dump markdown`."""
    d = json.loads(raw)
    return d.get("content") or "", d.get("http_status"), d.get("error")


def fail(http=None, err=None):
    sys.stderr.write("http=%d\n" % http if http else "err=%s\n" % (err or "Error"))
    return 1


def scrapling(mode, url):
    sub = "get" if mode == "scrapling-static" else "stealthy-fetch"
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "page.md")
        p = subprocess.run([os.environ.get("SCRAPLING_BIN", "scrapling"), "extract", sub, url, out],
                           capture_output=True, text=True, timeout=TIMEOUT)
        status = scrapling_status(p.stderr + p.stdout)
        if status and status >= 400:
            return fail(http=status)
        if p.returncode != 0 or not os.path.exists(out):
            return fail(err="ScraplingExit%d" % p.returncode)
        with open(out, encoding="utf-8", errors="replace") as fh:
            print(fh.read())
    return 0


def lightpanda(url):
    p = subprocess.run([os.environ.get("LIGHTPANDA_BIN", "lightpanda"), "fetch", url,
                        "--dump", "markdown", "--json"], capture_output=True, text=True, timeout=TIMEOUT)
    try:
        md, status, error = lightpanda_result(p.stdout)
    except ValueError:
        return fail(err="LightpandaExit%d" % p.returncode)
    if status and status >= 400:
        return fail(http=status)
    if error:
        return fail(err="LightpandaNav")
    print(md)
    return 0


def camofox(url):
    base = os.environ.get("CAMOFOX_URL", "http://127.0.0.1:9377")
    user = {"userId": "bench", "sessionKey": "bench"}

    def call(method, path, body=None):
        req = urllib.request.Request(
            base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))

    tab = None
    try:
        made = call("POST", "/tabs", dict(user, url=url))
        tab = made.get("tabId") or made.get("id")
        snap = call("GET", "/tabs/%s/snapshot?userId=bench" % tab)
        print(snap.get("snapshot") or "")
        return 0
    except urllib.error.HTTPError as e:
        return fail(http=e.code)
    finally:
        if tab:
            try:
                call("DELETE", "/tabs/%s?userId=bench" % tab)
            except Exception:
                pass


def main(mode, url):
    if mode.startswith("scrapling-"):
        return scrapling(mode, url)
    if mode == "lightpanda":
        return lightpanda(url)
    if mode == "camofox":
        return camofox(url)
    return fail(err="UnknownMode")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
