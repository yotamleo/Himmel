#!/usr/bin/env python3
"""HIMMEL-4362 scrape-provider benchmark runner.

  python3 bench.py --provider jina --out results/jina.jsonl
  FIRECRAWL_API_KEY=... python3 bench.py --provider firecrawl --max-calls 45 --out results/firecrawl.jsonl
  python3 bench.py --provider cmd --name agent-reach --cmd 'agent-reach read {url}' --out ar.jsonl
  python3 render.py results/*.jsonl

Rows carry metrics only, never page bodies. Future engines: add a Provider."""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import providers  # noqa: E402
import score as scoring  # noqa: E402

HERE = Path(__file__).resolve().parent


def run(provider, fixture, out_path, delay=0.0, categories=None, ids=None, sleep=time.sleep, clock=time.monotonic):
    rows = []
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for item in fixture:
            if categories and item["category"] not in categories:
                continue
            if ids and item["id"] not in ids:
                continue
            row = {"provider": provider.name, "id": item["id"], "category": item["category"],
                   "url": item["url"], "status": "ok", "success": False, "title_match": False,
                   "phrase_hit": False, "boilerplate_ratio": 1.0, "length": 0,
                   "latency_s": 0.0, "credits": 0, "error": ""}
            t0 = clock()
            try:
                md = provider.scrape(item["url"])
                row.update(scoring.score(md, item.get("title"), item.get("phrase")))
            except providers.CapReached:
                row["status"] = "skipped-cap"
            except providers.NeedsAuth:
                row["status"] = "needs-auth"
            except Exception as e:  # class name only: a message could echo a URL or key
                row["status"] = "error"
                row["error"] = type(e).__name__
                if isinstance(getattr(e, "code", None), int):  # HTTP status, never the message
                    row["error"] += ":%d" % e.code
            row["latency_s"] = round(clock() - t0, 2)
            row["credits"] = 0 if row["status"] == "skipped-cap" else getattr(provider, "last_credits", 0)
            rows.append(row)
            fh.write(json.dumps(row) + "\n")
            fh.flush()
            if delay:
                sleep(delay)
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", required=True, choices=["jina", "firecrawl", "cmd"])
    ap.add_argument("--fixture", default=str(HERE / "fixtures" / "urls.json"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-calls", type=int, default=45)
    ap.add_argument("--delay", type=float, default=1.0)
    ap.add_argument("--category", action="append")
    ap.add_argument("--id", action="append", help="only these fixture ids (repeatable)")
    ap.add_argument("--name", default="cmd")
    ap.add_argument("--cmd")
    a = ap.parse_args(argv)
    if a.provider == "jina":
        p = providers.JinaProvider()
    elif a.provider == "firecrawl":
        p = providers.FirecrawlProvider(a.max_calls)
    else:
        if not a.cmd:
            ap.error("--cmd is required with --provider cmd")
        p = providers.CommandProvider(a.name, a.cmd)
    fixture = json.loads(Path(a.fixture).read_text(encoding="utf-8"))
    rows = run(p, fixture, a.out, a.delay, a.category, a.id)
    print("%s: %d rows, %d calls, %d credits -> %s" % (
        p.name, len(rows), p.calls, sum(r["credits"] for r in rows), a.out))


if __name__ == "__main__":
    main()
