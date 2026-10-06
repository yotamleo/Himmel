#!/usr/bin/env python3
"""scripts/eval/lib/eval_runs.py - the eval-runs ledger writer (HIMMEL-4647).

One append-only JSONL ledger for every himmel eval, so a run is stored,
trended and compared across commits (scripts/eval/eval-compare reads it).
Registered in scripts/observability/ledgers.json as `eval-runs`.

  Path: $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl.

ROW SCHEMA (v 1) -- one JSON object per eval RUN (not per case):
  v           1                                 schema version
  ts          "2026-10-06T19:00:00Z"            UTC, when the row was written
  host        hostname
  source      repo-relative writer of the row ("scripts/eval/lane-quality/run.sh")
  kind        "eval-run"
  run_id      unique per run; an eval's own run id when it has one
  eval        "lane-quality" | "qmd-quality" | "guard-corpus" | "scrape-bench" | ...
  status      "ok" | "partial" | "inconclusive"; only "ok" rows are baselines
  gitsha      HEAD of the code under test (null outside a checkout)
  git_dirty   true when that checkout had uncommitted changes (null if unknown)
  config      the inputs that change what a score MEANS (model, modes, corpus hash);
              never a git sha, so the same config across commits is one series
  confighash  first 16 hex of sha256 over config as canonical JSON (sorted keys)
  model       model under test, or null
  lane        lane under test, or null
  n           cases scored (queries, tasks, rows, urls)
  reps        repeats per case (1 until HIMMEL-4648 adds --reps)
  metrics     {name: number|null}, run-level, flat; null = not measured this run
  ci          {name: {"lo": x, "hi": y}} for metrics with an interval, else {}
  ci_level    e.g. 0.95, or null when ci is empty
  ci_method   e.g. "bootstrap", "wilson", or null
  cases       {case_id: {name: number|bool|null}} per-case scores for a paired
              compare (HIMMEL-4650), or null when the eval does not record them
  artifact    path to the run's own output (dir or file), or null
  meta        free descriptive fields NOT hashed into confighash (index path,
              base/head specs, backfill provenance)

Forward use without migration: HIMMEL-4648 fills reps, ci, ci_level, ci_method
and adds calibration numbers as metrics; HIMMEL-4650 reads cases (or the
artifact) for a per-query paired test; HIMMEL-4652 exports metrics and ci as
Prometheus series labelled by eval, model, lane and confighash.

Usage:
  eval_runs.py append --eval E --source S --config-json J --metrics-json M
                      [--n N] [--reps R] [--model M] [--lane L] [--status S]
                      [--run-id ID] [--ci-json J] [--ci-level X] [--ci-method M]
                      [--cases-json J] [--artifact P] [--meta-json J]
                      [--repo DIR] [--ledger PATH]
  eval_runs.py qmd-quality <out-dir> --golden G --modes M [--scope S]
                      [--candidate-limit C] [--embed-model E] [--rerank-model R]
                      [--index I] [--status S] [--meta-json J] [--ledger PATH]
  eval_runs.py lane-quality <run-dir> --run-id ID [--judge-model M]
                      [--status S] [--ledger PATH]
  eval_runs.py validate <ledger>
Exit: 0 written/valid, 1 invalid rows (validate), 2 refused input.
Python callers import it: append_row(row) / make_row(...) / append_safe(...).
Stdlib only; no network.
"""
import argparse
import hashlib
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import uuid
from datetime import datetime, timezone

SCHEMA_VERSION = 1
LEDGER_ENV = "HIMMEL_EVAL_RUNS_LEDGER"
STATUSES = ("ok", "partial", "inconclusive")
REQUIRED = ("v", "ts", "host", "source", "kind", "run_id", "eval", "status", "gitsha",
            "git_dirty", "config", "confighash", "model", "lane", "n", "reps", "metrics",
            "ci", "ci_level", "ci_method", "cases", "artifact", "meta")


def ledger_path(path=None):
    return path or os.environ.get(LEDGER_ENV) or os.path.expanduser("~/.himmel/eval-runs.jsonl")


def config_hash(config):
    canon = json.dumps(config, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_state(repo=None):
    """(sha, dirty) of the checkout holding `repo` (default: this file's)."""
    repo = repo or os.path.dirname(os.path.abspath(__file__))
    try:
        sha = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True,
                             text=True, timeout=10)
        if sha.returncode != 0:
            return None, None
        st = subprocess.run(["git", "-C", repo, "status", "--porcelain", "--untracked-files=no"],
                            capture_output=True, text=True, timeout=30)
        return sha.stdout.strip(), (bool(st.stdout.strip()) if st.returncode == 0 else None)
    except (OSError, subprocess.SubprocessError):
        return None, None


def _num(x):
    """A finite number: json.loads accepts NaN and Infinity, and NaN fails
    every comparison, so it would pass any regression gate silently."""
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def make_row(eval_id, source, config, metrics, n=None, model=None, lane=None, status="ok",
             run_id=None, ci=None, ci_level=None, ci_method=None, cases=None, artifact=None,
             meta=None, reps=1, repo=None, gitsha=None):
    now = datetime.now(timezone.utc)
    if gitsha is None:
        gitsha, dirty = git_state(repo)
    else:
        dirty = None
    return {
        "v": SCHEMA_VERSION,
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": socket.gethostname(),
        "source": source,
        "kind": "eval-run",
        "run_id": run_id or "%s-%s-%s" % (now.strftime("%Y%m%dT%H%M%SZ"), eval_id, uuid.uuid4().hex[:6]),
        "eval": eval_id,
        "status": status,
        "gitsha": gitsha,
        "git_dirty": dirty,
        "config": config,
        "confighash": config_hash(config) if isinstance(config, dict) else None,
        "model": model,
        "lane": lane,
        "n": n,
        "reps": reps,
        "metrics": metrics,
        "ci": ci or {},
        "ci_level": ci_level,
        "ci_method": ci_method,
        "cases": cases,
        "artifact": artifact,
        "meta": meta or {},
    }


def validate(row):
    """List of problems; empty = a valid v1 row."""
    if not isinstance(row, dict):
        return ["row is not an object"]
    p = ["missing %s" % k for k in REQUIRED if k not in row]
    if p:
        return p
    if row["v"] != SCHEMA_VERSION:
        p.append("v must be %d" % SCHEMA_VERSION)
    if row["kind"] != "eval-run":
        p.append("kind must be eval-run")
    for k in ("ts", "host", "source", "run_id", "eval"):
        if not isinstance(row[k], str) or not row[k]:
            p.append("%s must be a non-empty string" % k)
    if row["status"] not in STATUSES:
        p.append("status must be one of %s" % ", ".join(STATUSES))
    if not isinstance(row["config"], dict):
        p.append("config must be an object")
    elif row["confighash"] != config_hash(row["config"]):
        p.append("confighash does not match config")
    for k in ("model", "lane", "gitsha", "artifact", "ci_method"):
        if row[k] is not None and not isinstance(row[k], str):
            p.append("%s must be a string or null" % k)
    for k in ("n", "reps"):
        if row[k] is not None and (not isinstance(row[k], int) or isinstance(row[k], bool) or row[k] < 0):
            p.append("%s must be a non-negative integer or null" % k)
    if row["ci_level"] is not None and not (_num(row["ci_level"]) and 0 < row["ci_level"] < 1):
        p.append("ci_level must be in (0, 1) or null")
    m = row["metrics"]
    if not isinstance(m, dict) or not m:
        p.append("metrics must be a non-empty object")
        m = {}
    for k, x in m.items():
        if x is not None and not _num(x):
            p.append("metric %s is not a number or null" % k)
    ci = row["ci"]
    if not isinstance(ci, dict):
        p.append("ci must be an object")
        ci = {}
    for k, b in ci.items():
        if not isinstance(b, dict) or not _num(b.get("lo")) or not _num(b.get("hi")):
            p.append("ci %s needs numeric lo and hi" % k)
        elif b["lo"] > b["hi"]:
            p.append("ci %s has lo > hi" % k)
        if k not in m:
            p.append("ci %s names no metric" % k)
    cases = row["cases"]
    if cases is not None:
        if not isinstance(cases, dict):
            p.append("cases must be an object or null")
        else:
            for cid, cm in cases.items():
                if not isinstance(cm, dict) or any(v is not None and not (_num(v) or isinstance(v, bool))
                                                   for v in cm.values()):
                    p.append("case %s must map names to numbers, booleans or null" % cid)
    if not isinstance(row["meta"], dict):
        p.append("meta must be an object")
    return p


def append_row(row, path=None):
    """Validate and append one row; raises ValueError on an invalid row."""
    problems = validate(row)
    if problems:
        raise ValueError("; ".join(problems))
    path = ledger_path(path)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    line = (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    # One O_APPEND write per row, so concurrent writers never interleave a line.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)
    return path


def append_safe(row, path=None, who="eval-runs"):
    """append_row for an eval's own exit path: a ledger failure warns, never
    changes the eval's result."""
    try:
        p = append_row(row, path)
        print("%s: eval-runs row %s -> %s" % (who, row.get("run_id"), p), file=sys.stderr)
        return p
    except (OSError, ValueError) as e:
        print("%s: WARNING eval-runs row not written: %s" % (who, e), file=sys.stderr)
        return None


def read_rows(path=None):
    """Valid rows in file order; malformed lines are skipped (counted on stderr)."""
    path = ledger_path(path)
    rows, bad = [], 0
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        return []
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                bad += 1
                continue
            if validate(r):
                bad += 1
                continue
            rows.append(r)
    if bad:
        print("eval-runs: skipped %d malformed row(s) in %s" % (bad, path), file=sys.stderr)
    return rows


# --- adapters: an eval's own output -> one row ---------------------------------

def _tsv(path):
    with open(path, encoding="utf-8") as fh:
        lines = [l.rstrip("\n").split("\t") for l in fh if l.strip()]
    if not lines:
        return []
    head = lines[0]
    return [dict(zip(head, l)) for l in lines[1:]]


def _f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def qmd_quality_row(out_dir, golden, modes, scope="all", candidate_limit=40, embed_model=None,
                    rerank_model=None, index=None, status="ok", meta=None):
    """Row from a qmd-quality --out dir (scores.tsv + latency.tsv). Run-level
    metrics are the ALL rows; per-collection rows stay in the artifact."""
    scores = _tsv(os.path.join(out_dir, "scores.tsv"))
    if not scores:
        raise ValueError("no scored rows in %s/scores.tsv" % out_dir)
    lat_path = os.path.join(out_dir, "latency.tsv")
    lat = _tsv(lat_path) if os.path.exists(lat_path) else []
    metrics, n = {}, None
    for r in scores:
        if r.get("collection") != "ALL":
            continue
        m = r["mode"]
        metrics[m + ".hit1"] = _f(r.get("hit@1"))
        metrics[m + ".hit5"] = _f(r.get("hit@5"))
        metrics[m + ".mrr"] = _f(r.get("mrr"))
        metrics[m + ".missing"] = _f(r.get("missing"))
        n = int(r["n"]) if r.get("n", "").isdigit() else n
    for r in lat:
        metrics[r["mode"] + ".median_ms"] = _f(r.get("median_ms"))
        metrics[r["mode"] + ".p90_ms"] = _f(r.get("p90_ms"))
    config = {
        "modes": ",".join(sorted(x for x in modes.split(",") if x)),
        "scope": scope,
        "candidate_limit": int(candidate_limit),
        "embed_model": embed_model or None,
        "rerank_model": rerank_model or None,
        "golden_sha256": file_sha256(golden),
    }
    m = dict(meta or {})
    if index:
        m["index"] = index
    return make_row("qmd-quality", "scripts/eval/qmd-quality/qmd-quality.sh", config, metrics, n=n,
                    model=embed_model or None, status=status, artifact=os.path.abspath(out_dir), meta=m)


LQ_CRITERIA = ("correctness", "scope_discipline", "test_quality", "honesty")


def lane_quality_row(run_dir, run_id, judge_model=None, status="ok"):
    """Row from a lane-quality run dir (runs.jsonl, one row per task)."""
    path = os.path.join(run_dir, "runs.jsonl")
    with open(path, encoding="utf-8") as fh:
        tasks = [json.loads(l) for l in fh if l.strip()]
    if not tasks:
        raise ValueError("no task rows in %s" % path)
    first = tasks[0]

    def mean(xs):
        xs = [x for x in xs if _num(x)]
        return statistics.fmean(xs) if xs else None

    def total(key):
        xs = [t.get(key) for t in tasks]
        return None if any(not _num(x) for x in xs) else sum(xs)

    acc_t = sum(t.get("accept_total") or 0 for t in tasks)
    metrics = {
        "accept_rate": (sum(t.get("accept_passed") or 0 for t in tasks) / acc_t) if acc_t else None,
        "accept_ok_rate": mean([1.0 if t.get("accept_ok") else 0.0 for t in tasks]),
        "scope_ok_rate": mean([1.0 if t.get("scope_ok") else 0.0 for t in tasks]),
        "judge_missing": float(sum(1 for t in tasks if not isinstance(t.get("judge"), dict))),
        "cost_usd": total("cost_usd"),
        "wall_s": total("wall_s"),
        "tool_calls": total("tool_calls"),
        "hook_denials": total("hook_denials"),
        "permission_denials": total("permission_denials"),
        "peeked": float(sum(1 for t in tasks if t.get("peeked") is True)),
    }
    for c in LQ_CRITERIA:
        metrics["judge_" + c] = mean([(t.get("judge") or {}).get(c) for t in tasks])
    cases = {}
    for t in tasks:
        j = t.get("judge") if isinstance(t.get("judge"), dict) else {}
        c = {"accept_frac": (t["accept_passed"] / t["accept_total"]) if t.get("accept_total") else None,
             "accept_ok": bool(t.get("accept_ok")), "scope_ok": bool(t.get("scope_ok"))}
        for k in LQ_CRITERIA:
            c["judge_" + k] = j.get(k) if _num(j.get(k)) else None
        cases[t["task"]] = c
    config = {
        "lane": first.get("lane"),
        "model": first.get("model"),
        "effort": first.get("effort") or None,
        "judge_model": judge_model or None,
        "tasks": sorted(t["task"] for t in tasks),
        "base_sha": first.get("base_sha"),
    }
    return make_row("lane-quality", "scripts/eval/lane-quality/run.sh", config, metrics, n=len(tasks),
                    model=first.get("model"), lane=first.get("lane"), status=status, run_id=run_id,
                    cases=cases, artifact=os.path.abspath(path))


# --- CLI ----------------------------------------------------------------------

def _json_arg(ap, name, text, kind=dict):
    if text is None:
        return None
    try:
        v = json.loads(text)
    except json.JSONDecodeError as e:
        ap.error("%s is not JSON: %s" % (name, e))
    if not isinstance(v, kind):
        ap.error("%s must be a JSON %s" % (name, kind.__name__))
    return v


def main(argv=None):
    ap = argparse.ArgumentParser(prog="eval_runs.py", description="eval-runs ledger writer (HIMMEL-4647)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("append")
    a.add_argument("--eval", required=True)
    a.add_argument("--source", required=True)
    a.add_argument("--config-json", required=True)
    a.add_argument("--metrics-json", required=True)
    a.add_argument("--n", type=int)
    a.add_argument("--reps", type=int, default=1)
    a.add_argument("--model")
    a.add_argument("--lane")
    a.add_argument("--status", default="ok")
    a.add_argument("--run-id")
    a.add_argument("--ci-json")
    a.add_argument("--ci-level", type=float)
    a.add_argument("--ci-method")
    a.add_argument("--cases-json")
    a.add_argument("--artifact")
    a.add_argument("--meta-json")
    a.add_argument("--repo")
    a.add_argument("--ledger")
    q = sub.add_parser("qmd-quality")
    q.add_argument("out_dir")
    q.add_argument("--golden", required=True)
    q.add_argument("--modes", required=True)
    q.add_argument("--scope", default="all")
    q.add_argument("--candidate-limit", type=int, default=40)
    q.add_argument("--embed-model")
    q.add_argument("--rerank-model")
    q.add_argument("--index")
    q.add_argument("--status", default="ok")
    q.add_argument("--meta-json")
    q.add_argument("--ledger")
    lq = sub.add_parser("lane-quality")
    lq.add_argument("run_dir")
    lq.add_argument("--run-id", required=True)
    lq.add_argument("--judge-model")
    lq.add_argument("--status", default="ok")
    lq.add_argument("--ledger")
    v = sub.add_parser("validate")
    v.add_argument("ledger")
    args = ap.parse_args(argv)

    if args.cmd == "validate":
        bad = 0
        with open(args.ledger, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                try:
                    probs = validate(json.loads(line))
                except json.JSONDecodeError as e:
                    probs = ["not JSON: %s" % e]
                if probs:
                    bad += 1
                    print("line %d: %s" % (i, "; ".join(probs)))
        print("eval-runs validate: %s" % ("FAIL, %d bad row(s)" % bad if bad else "OK"))
        return 1 if bad else 0

    try:
        if args.cmd == "append":
            if args.eval is not None and not args.eval:
                raise ValueError("eval must be a non-empty string")
            row = make_row(args.eval, args.source, _json_arg(ap, "--config-json", args.config_json),
                           _json_arg(ap, "--metrics-json", args.metrics_json), n=args.n, model=args.model,
                           lane=args.lane, status=args.status, run_id=args.run_id,
                           ci=_json_arg(ap, "--ci-json", args.ci_json), ci_level=args.ci_level,
                           ci_method=args.ci_method, cases=_json_arg(ap, "--cases-json", args.cases_json),
                           artifact=args.artifact, meta=_json_arg(ap, "--meta-json", args.meta_json),
                           reps=args.reps, repo=args.repo)
        elif args.cmd == "qmd-quality":
            row = qmd_quality_row(args.out_dir, args.golden, args.modes, args.scope, args.candidate_limit,
                                  args.embed_model, args.rerank_model, args.index, args.status,
                                  _json_arg(ap, "--meta-json", args.meta_json))
        else:
            row = lane_quality_row(args.run_dir, args.run_id, args.judge_model, args.status)
        path = append_row(row, args.ledger)
    except (OSError, ValueError) as e:
        print("eval_runs: refused: %s" % e, file=sys.stderr)
        return 2
    print("eval_runs: %s %s -> %s" % (row["eval"], row["run_id"], path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
