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
                elif getattr(e, "label", None):  # adapter's err=<Class> label, already sanitized
                    row["error"] += ":" + e.label
            row["latency_s"] = round(clock() - t0, 2)
            used = 0 if row["status"] == "skipped-cap" else getattr(provider, "last_credits", 0)
            row["credits_known"] = used is not None  # None = the call may have billed, usage unknown
            row["credits"] = used or 0
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
    record_run(p.name, a, rows)


def record_run(provider_name, a, rows):
    """One eval-runs ledger row per bench run (HIMMEL-4647). Rates are over the
    rows a provider actually tried (ok or error); a capped or needs-auth row
    makes the run partial. A ledger failure warns and never fails the bench."""
    sys.path.insert(0, str(HERE.parent / "lib"))
    import eval_runs
    tried = [r for r in rows if r["status"] in ("ok", "error")]

    def rate(k):
        return sum(1 for r in tried if r[k]) / len(tried) if tried else None
    lat = sorted(r["latency_s"] for r in tried)
    mid = len(lat) // 2
    metrics = {
        "success_rate": rate("success"), "title_match_rate": rate("title_match"),
        "phrase_hit_rate": rate("phrase_hit"),
        "boilerplate_ratio_mean": (sum(r["boilerplate_ratio"] for r in tried) / len(tried)
                                   if tried else None),
        "latency_s_median": (lat[mid] if len(lat) % 2 else (lat[mid - 1] + lat[mid]) / 2) if lat else None,
        "errors": sum(1 for r in rows if r["status"] == "error"),
        "credits": sum(r["credits"] for r in rows),
    }
    cases = {r["id"]: {"success": r["success"], "title_match": r["title_match"],
                       "phrase_hit": r["phrase_hit"], "latency_s": r["latency_s"]} for r in rows}
    config = {"provider": provider_name, "fixture_sha256": eval_runs.file_sha256(a.fixture),
              "categories": sorted(a.category or []), "ids": sorted(a.id or [])}
    row = eval_runs.make_row(
        "scrape-bench", "scripts/eval/scrape-bench/bench.py", config, metrics, n=len(rows),
        status="ok" if len(tried) == len(rows) and rows else "partial",
        cases=cases, artifact=str(Path(a.out).resolve()), repo=str(HERE))
    eval_runs.append_safe(row, who="scrape-bench")


if __name__ == "__main__":
    main()
