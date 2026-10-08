#!/usr/bin/env python3
"""cr_ledger_eval.py - review-panel numbers from the CR ledger (HIMMEL-4482).

Pure over the ledger: no model call, no network, no writes. It reads the
append-only cr-critic-scores.jsonl that /pr-check writes, folds each finding's
amend records into its effective verdict (the same fold cr-scores.sh does),
and reports:

  * per critic: findings, agreed (agreed + fixed), disproved, deferred,
    unadjudicated, precision = agreed / (agreed + disproved), with a 95%
    bootstrap interval resampled by PR (branch), since findings on one PR are
    not independent;
  * the same split by severity, the deferral classes (fu_class) and the
    re-raise rate (a fingerprint raised again at a later head of its branch);
  * --sample N: a seeded sample of disproved findings, as JSONL, for hand
    coding (local only: it carries the finding and verdict text);
  * --coded FILE: checks a committed coded sample against the ledger and
    tallies its taxonomy classes, with intervals.

A critic is the panel slug plus the model that answered (joined from the
avail/attempt row of the same branch, head and slug), so a model re-pin shows
as a new critic: codex:gpt-6-sol, codex:gpt-6.1-sol. --until cuts both
findings and amends at one timestamp, so a published number re-runs exactly
while the ledger keeps growing.

Usage:
  cr_ledger_eval.py [--ledger P] [--until TS] [--json]
  cr_ledger_eval.py [--ledger P] [--until TS] --sample N [--seed S]
  cr_ledger_eval.py [--ledger P] [--until TS] --coded FILE [--json]
Default ledger: $CR_LEDGER, else <git common dir>/cr-critic-scores.jsonl.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from eval_runs import bootstrap_ci  # noqa: E402

SEP = "\x1f"
# The taxonomy for disproved findings. The coding rule for each class is in
# docs/evals/review-panel.md; a coded sample naming any other class is refused.
CLASSES = (
    "no-rationale",
    "re-raise",
    "wrong-claim",
    "unreachable",
    "intent-blind",
    "stale-head",
)
SEVERITY = {"crit": "critical", "critical": "critical",
            "imp": "important", "important": "important", "major": "important",
            "sug": "suggestion", "minor": "suggestion", "suggestion": "suggestion"}


def die(msg):
    print("cr_ledger_eval: " + msg, file=sys.stderr)
    sys.exit(2)


def default_ledger():
    env = os.environ.get("CR_LEDGER")
    if env:
        return env
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        die("no --ledger, no CR_LEDGER, and not inside a git checkout")
    return os.path.join(common, "cr-critic-scores.jsonl")


def key(head, fid, artifact, perspective):
    return SEP.join([head or "", fid or "", artifact or "diff", perspective or "off"])


def finding_id(k):
    """Stable public id: no branch, path or text, only a hash of the key."""
    return hashlib.sha256(k.encode()).hexdigest()[:12]


def parse_ts(ts):
    """An ISO-8601 timestamp as an aware UTC datetime, or None if it does not parse."""
    try:
        t = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.replace(tzinfo=datetime.timezone.utc) if t.tzinfo is None else t


def load(path, until):
    if not os.path.isfile(path):
        die("ledger not found: " + path)
    cut = parse_ts(until) if until else None
    if until and cut is None:
        die("--until is not an ISO-8601 timestamp: " + until)
    rows, malformed = [], 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if not isinstance(r, dict):
                malformed += 1
                continue
            # A row whose ts does not parse is kept, as an empty ts always was.
            ts = parse_ts(r.get("ts", "")) if cut else None
            if ts is not None and ts > cut:
                continue
            rows.append(r)
    return rows, malformed


def fold(rows):
    """Findings with their effective verdict and critic label, in ledger order."""
    amends = {}
    responding = {}
    for r in rows:
        if r.get("kind") == "amend" and isinstance(r.get("set"), dict):
            k = key(r.get("target_head"), r.get("finding_id"), r.get("artifact"), r.get("perspective"))
            merged = amends.setdefault(k, {})
            if r.get("reason"):
                merged["reason"] = r["reason"]
            merged.update(r["set"])
        elif r.get("kind") in ("avail", "attempt") and r.get("responding_model"):
            responding[(r.get("branch"), r.get("head"), r.get("model"), r.get("artifact") or "diff")] = r["responding_model"]
    out = []
    for r in rows:
        if r.get("kind") != "finding":
            continue
        k = key(r.get("head"), r.get("finding_id"), r.get("artifact"), r.get("perspective"))
        eff = dict(r)
        eff.update(amends.get(k, {}))
        v = eff.get("verdict")
        v = v.strip() if isinstance(v, str) else ""
        bucket = {"agreed": "agreed", "fixed": "agreed", "disproved": "disproved",
                  "deferred": "deferred"}.get(v, "unadjudicated")
        slug = r.get("model") or "unlabelled"
        rm = responding.get((r.get("branch"), r.get("head"), r.get("model"), r.get("artifact") or "diff"))
        out.append({
            "id": finding_id(k),
            "critic": slug + ":" + rm if rm else slug,
            "branch": r.get("branch") or "",
            "head": r.get("head") or "",
            "ts": r.get("ts") or "",
            "severity": SEVERITY.get(str(r.get("severity") or "").lower(), "unlabelled"),
            "bucket": bucket,
            "fu_class": eff.get("fu_class") or "",
            "fingerprint": r.get("fingerprint") or "",
            "reason": eff.get("reason") or "",
            "text": r.get("text") or "",
        })
    return out


def ratio_ci(findings, num, den):
    """Interval for sum(num)/sum(den), resampling whole PRs (branches)."""
    per = collections.defaultdict(lambda: [0, 0])
    for f in findings:
        if f["bucket"] in den:
            per[f["branch"]][1] += 1
            if f["bucket"] in num:
                per[f["branch"]][0] += 1
    items = [tuple(v) for v in per.values() if v[1]]
    if len(items) < 2:
        return None

    def stat(res):
        d = sum(x[1] for x in res)
        return sum(x[0] for x in res) / d if d else None
    ci = bootstrap_ci(items, stat=stat, b=2000, seed=0)
    return None if ci is None else {"lo": round(ci["lo"], 4), "hi": round(ci["hi"], 4)}


def split(findings):
    c = collections.Counter(f["bucket"] for f in findings)
    a, d = c["agreed"], c["disproved"]
    return {
        "n": len(findings),
        "prs": len({f["branch"] for f in findings}),
        "agreed": a, "disproved": d, "deferred": c["deferred"], "unadjudicated": c["unadjudicated"],
        "precision": round(a / (a + d), 4) if a + d else None,
        "precision_ci": ratio_ci(findings, {"agreed"}, {"agreed", "disproved"}),
        "disproved_share": round(d / len(findings), 4) if findings else None,
        "first": min((f["ts"] for f in findings), default=""),
        "last": max((f["ts"] for f in findings), default=""),
    }


def reraise(findings):
    seen = {}
    n = again = 0
    for f in sorted(findings, key=lambda f: f["ts"]):
        if not f["fingerprint"]:
            continue
        n += 1
        k = (f["branch"], f["fingerprint"])
        if k in seen and seen[k] != f["head"]:
            again += 1
        seen.setdefault(k, f["head"])
    return {"fingerprinted": n, "reraised": again,
            "rate": round(again / n, 4) if n else None}


def report(findings, malformed, until):
    by = collections.defaultdict(list)
    sev = collections.defaultdict(list)
    for f in findings:
        by[f["critic"]].append(f)
        sev[f["severity"]].append(f)
    deferred = collections.Counter(f["fu_class"] or "unclassed" for f in findings if f["bucket"] == "deferred")
    return {
        "until": until or None,
        "findings": len(findings),
        "malformed": malformed,
        "overall": split(findings),
        "critics": {c: split(fs) for c, fs in by.items()},
        "severity": {s: split(fs) for s, fs in sev.items()},
        # A re-pin can shift the severity mix, so compare critics within a severity.
        "critic_severity": {c: {s: split([f for f in fs if f["severity"] == s])
                                for s in sorted({f["severity"] for f in fs})}
                            for c, fs in by.items()},
        "deferred_class": dict(deferred),
        "reraise": reraise(findings),
    }


def coded(findings, path):
    disproved = {f["id"]: f for f in findings if f["bucket"] == "disproved"}
    if not os.path.isfile(path):
        die("coded sample not found: " + path)
    rows, seen = [], set()
    with open(path, encoding="utf-8") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        if header[:3] != ["id", "critic", "class"]:
            die("coded sample header must start id<TAB>critic<TAB>class")
        for n, line in enumerate(fh, 2):
            if not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                die("%s:%d: fewer than three columns" % (path, n))
            fid, critic, cls = cols[:3]
            if fid in seen:
                die("%s:%d: duplicate finding id %s" % (path, n, fid))
            seen.add(fid)
            if fid not in disproved:
                die("%s:%d: %s is not a disproved finding in this ledger cut" % (path, n, fid))
            if disproved[fid]["critic"] != critic:
                die("%s:%d: %s is %s in the ledger, not %s" % (path, n, fid, disproved[fid]["critic"], critic))
            if cls not in CLASSES:
                die("%s:%d: undeclared class %r (declared: %s)" % (path, n, cls, ", ".join(CLASSES)))
            rows.append(dict(disproved[fid], cls=cls))
    counts = collections.Counter(r["cls"] for r in rows)
    out = {"n": len(rows), "prs": len({r["branch"] for r in rows}), "counts": dict(counts), "share": {}, "ci": {}}
    for cls in CLASSES:
        out["share"][cls] = round(counts[cls] / len(rows), 4) if rows else None
        tagged = [dict(r, bucket="hit" if r["cls"] == cls else "miss") for r in rows]
        out["ci"][cls] = ratio_ci(tagged, {"hit"}, {"hit", "miss"})
    return out


def pct(x):
    return "n/a" if x is None else "%.1f%%" % (100 * x)


def ci_s(ci):
    return "" if not ci else "[%.1f, %.1f]" % (100 * ci["lo"], 100 * ci["hi"])


def print_table(rep, tax):
    print("CR ledger cut: until=%s  findings=%d  malformed-lines=%d"
          % (rep["until"] or "(none)", rep["findings"], rep["malformed"]))
    hdr = "%-26s %6s %5s %6s %6s %6s %6s %9s %-14s %s"
    print(hdr % ("critic", "n", "prs", "agreed", "disprv", "defer", "unadj", "precision", "95% CI (PR)", "span"))

    def row(name, s):
        print(hdr % (name, s["n"], s["prs"], s["agreed"], s["disproved"], s["deferred"], s["unadjudicated"],
                     pct(s["precision"]), ci_s(s["precision_ci"]), s["first"][:10] + ".." + s["last"][:10]))
    for name, s in sorted(rep["critics"].items(), key=lambda kv: kv[1]["first"]):
        row(name, s)
    row("ALL", rep["overall"])
    print("\nby severity:")
    for name in ("critical", "important", "suggestion", "unlabelled"):
        if name in rep["severity"]:
            row(name, rep["severity"][name])
    print("\nby critic and severity (critics with 200+ findings):")
    for name, s in sorted(rep["critics"].items(), key=lambda kv: kv[1]["first"]):
        if s["n"] >= 200:
            for sv in ("critical", "important", "suggestion"):
                if sv in rep["critic_severity"][name]:
                    row(name + " " + sv[:4], rep["critic_severity"][name][sv])
    print("\ndeferred by class:",", ".join("%s=%d" % kv for kv in sorted(rep["deferred_class"].items())))
    rr = rep["reraise"]
    print("re-raise: %d of %d fingerprinted findings (%s) repeat a fingerprint already raised at an earlier head of the same PR"
          % (rr["reraised"], rr["fingerprinted"], pct(rr["rate"])))
    if tax:
        print("\ncoded sample of disproved findings: n=%d over %d PRs" % (tax["n"], tax["prs"]))
        for cls in CLASSES:
            print("  %-13s %3d  %6s  %s" % (cls, tax["counts"].get(cls, 0), pct(tax["share"][cls]), ci_s(tax["ci"][cls])))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Review-panel numbers from the CR ledger (no model call).")
    ap.add_argument("--ledger")
    ap.add_argument("--until", help="ISO-8601 UTC cutoff applied to findings and amends, e.g. 2026-10-06T20:00:00Z")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--sample", type=int, help="print N seeded disproved findings as JSONL, for hand coding")
    ap.add_argument("--seed", type=int, default=4482)
    ap.add_argument("--coded", help="coded sample TSV (id, critic, class, note) to check and tally")
    a = ap.parse_args(argv)
    if a.sample is not None and a.sample < 0:
        die("--sample must be a non-negative count, not %d" % a.sample)
    rows, malformed = load(a.ledger or default_ledger(), a.until)
    findings = fold(rows)
    if a.sample is not None:
        pool = sorted((f for f in findings if f["bucket"] == "disproved"), key=lambda f: f["id"])
        pick = random.Random(a.seed).sample(pool, min(a.sample, len(pool)))
        for f in sorted(pick, key=lambda f: f["ts"]):
            print(json.dumps({k: f[k] for k in ("id", "critic", "severity", "ts", "reason", "text")}, ensure_ascii=False))
        return 0
    rep = report(findings, malformed, a.until)
    tax = coded(findings, a.coded) if a.coded else None
    if tax:
        rep["taxonomy"] = tax
    if a.json:
        print(json.dumps(rep, indent=2, sort_keys=True))
    else:
        print_table(rep, tax)
    return 0


if __name__ == "__main__":
    sys.exit(main())
