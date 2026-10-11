#!/usr/bin/env python3
# scripts/eval/autocompact-ab.py - per-leg report for the HIMMEL-5193 autocompact
# A/B (200k control vs 400k audited arm). Local-only: reads leg docs and Claude
# Code session JSONL, runs no inference, sends nothing anywhere.
#
#   autocompact-ab.py [--manifest <fleet.json>]... [--doc <leg doc>]...
#                     [--projects <dir>] [--all] [--json]
#
# Legs come from fleet manifests (legs[].doc, optional legs[].arm) and/or --doc.
# Only WRAPPED legs (the doc's last `- ` bullet starts with WRAPPED) are
# reported unless --all. The arm is the manifest `arm` (the launcher's record);
# a leg without one is `unlabelled` and is left out of the arm summary. The
# brief's `ab-400k` line is not evidence: a 200000 launch can carry it.
# Legs with no matching transcript are `unmeasured` and left out of the means.
#
# Per leg: arm, compactions (count + the token level at each, `preTokens` of the
# compact_boundary row), handoffs (RESUME docs beside the leg doc), input tokens
# split cache_read / cache_create / uncached, price-weighted cost (the same
# weights as scripts/lanes/lib/burn-weights.sh, same LEG_BURN_W_* overrides),
# wall-clock (first to last row timestamp), PR outcome and mean output tokens
# per assistant turn. Assistant rows are deduped by message id: a transcript
# writes one row per content block.
#
# ponytail: PR outcome is read from the doc's Results bullets (READY count, PR
# number, review-round mentions) because CI itself is not in the transcript;
# upgrade path = join the leg-cost ledger `pr` against gh run history once the
# A/B has data worth that.
import argparse, glob, json, os, re, sys
from datetime import datetime

W_CR = float(os.environ.get("LEG_BURN_W_CACHE_READ", "0.1"))
W_CC = float(os.environ.get("LEG_BURN_W_CACHE_CREATE", "1.25"))
W_IN = float(os.environ.get("LEG_BURN_W_INPUT", "1"))
W_OUT = float(os.environ.get("LEG_BURN_W_OUTPUT", "5"))

BULLET = re.compile(r"^- (?:\d{2}:\d{2} )?([A-Z][A-Z-]*)\b")
ARM_LINE = re.compile(r"^> \*\*Context:\*\* ab-(200k|400k) ")
STEM = re.compile(r"^([A-Z]+-\d+)-([NP]\d+)")


def read_doc(path):
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return None
    markers, arm = [], None
    for ln in text.splitlines():
        m = ARM_LINE.match(ln)
        if m and arm is None:
            arm = m.group(1)
        m = BULLET.match(ln)
        if m:
            markers.append((m.group(1), ln))
    return {"text": text, "markers": markers, "arm": arm}


def pr_outcome(markers):
    ready = [ln for k, ln in markers if k == "READY"]
    pr = None
    for ln in ready:
        m = re.search(r"READY\s+#?(\d+)", ln)
        if m:
            pr = m.group(1)
    rounds = sum(1 for _, ln in markers if re.search(r"(pr-check|review|CR) round", ln, re.I))
    if not ready:
        first_try = "n/a"
    elif len(ready) == 1 and not any(k in ("MAIN-RED", "BLOCKED") for k, _ in markers):
        first_try = "yes"
    else:
        first_try = "no"
    return {"pr": pr, "ci_first_try": first_try, "review_rounds": rounds}


def find_transcripts(projects, names):
    found = set()
    needles = [re.compile(r'"customTitle"\s*:\s*"%s"' % re.escape(n)) for n in names if n]
    if not needles:
        return []
    for path in glob.glob(os.path.join(projects, "**", "*.jsonl"), recursive=True):
        try:
            with open(path, errors="replace") as fh:
                data = fh.read()
        except OSError:
            continue
        if any(n.search(data) for n in needles):
            found.add(path)
    return sorted(found)


def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def parse_transcripts(paths):
    calls, comps, stamps = {}, [], []
    for path in paths:
        last_ctx = 0
        for line in open(path, errors="replace"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            t = ts(row.get("timestamp"))
            if t is not None:
                stamps.append(t)
            if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
                meta = row.get("compactMetadata") or {}
                comps.append({"trigger": meta.get("trigger"),
                              "tokens": meta.get("preTokens") or last_ctx})
                continue
            msg = row.get("message") or {}
            if row.get("type") != "assistant" or not isinstance(msg, dict):
                continue
            u = msg.get("usage")
            if not isinstance(u, dict):
                continue
            mid = msg.get("id") or "row-%d-%s" % (len(calls), path)
            c = (u.get("input_tokens") or 0, u.get("cache_read_input_tokens") or 0,
                 u.get("cache_creation_input_tokens") or 0, u.get("output_tokens") or 0)
            calls[mid] = c
            last_ctx = c[0] + c[1] + c[2]
    inp = sum(c[0] for c in calls.values())
    cr = sum(c[1] for c in calls.values())
    cc = sum(c[2] for c in calls.values())
    out = sum(c[3] for c in calls.values())
    wall = int(max(stamps) - min(stamps)) if len(stamps) > 1 else 0
    return {"calls": len(calls), "uncached": inp, "cache_read": cr, "cache_create": cc,
            "out": out, "cost_eq": round(inp * W_IN + cr * W_CR + cc * W_CC + out * W_OUT),
            "compactions": comps, "wall_s": wall,
            "mean_out_per_turn": round(out / len(calls), 1) if calls else 0}


def leg_row(doc, manifest_arm, projects):
    d = read_doc(doc)
    if d is None:
        return None
    stem = os.path.basename(doc)
    stem = stem[:-3] if stem.endswith(".md") else stem
    m = STEM.match(stem)
    handoffs, names = 0, [stem]
    if m:
        pat = os.path.join(os.path.dirname(doc), "%s-%s*RESUME*.md" % (m.group(1), m.group(2)))
        # the glob has no boundary after the label (N902 also matches N9020)
        lead = "%s-%s" % (m.group(1), m.group(2))
        resumes = [r for r in glob.glob(pat)
                   if not os.path.basename(r)[len(lead):len(lead) + 1].isdigit()]
        handoffs = len(resumes)
        # a resumed session is titled by its RESUME doc stem
        names += [os.path.basename(r)[:-3] for r in resumes if r.endswith(".md")]
    # the manifest arm is the launcher's record; the brief line alone is not
    # evidence (a 200000 launch can carry it), so it is never a fallback
    arm = manifest_arm or "unlabelled"
    row = {"leg": stem, "arm": arm,
           "wrapped": bool(d["markers"]) and d["markers"][-1][0] == "WRAPPED",
           "handoffs": handoffs}
    row.update(pr_outcome(d["markers"]))
    paths = find_transcripts(projects, names)
    row["transcripts"] = len(paths)
    row.update(parse_transcripts(paths))
    return row


def fmt_tok(n):
    return "%.1fk" % (n / 1000.0)


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def summary(rows):
    out = []
    for arm in ("200k", "400k"):
        every = [r for r in rows if r["arm"] == arm]
        # a leg with no transcript is unmeasured, not zero: left out of the means
        rs = [r for r in every if r["transcripts"] > 0]
        if not every:
            continue
        if not rs:
            out.append({"arm": arm, "legs": 0, "unmeasured": len(every)})
            continue
        ci = [r for r in rs if r["ci_first_try"] != "n/a"]
        out.append({"arm": arm, "legs": len(rs), "unmeasured": len(every) - len(rs),
                    "compactions": round(mean([len(r["compactions"]) for r in rs]), 2),
                    "handoffs": round(mean([r["handoffs"] for r in rs]), 2),
                    "cost_eq": round(mean([r["cost_eq"] for r in rs])),
                    "wall_s": round(mean([r["wall_s"] for r in rs])),
                    "out_per_turn": round(mean([r["mean_out_per_turn"] for r in rs]), 1),
                    "ci_first_try": "%d/%d" % (sum(1 for r in ci if r["ci_first_try"] == "yes"), len(ci)),
                    "review_rounds": round(mean([r["review_rounds"] for r in rs]), 2)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", action="append", default=[])
    ap.add_argument("--doc", action="append", default=[])
    ap.add_argument("--projects", default=os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects"))
    ap.add_argument("--all", action="store_true", help="include legs that have not wrapped")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    legs = []
    for mf in a.manifest:
        try:
            for leg in json.load(open(mf)).get("legs", []):
                legs.append((leg.get("doc"), leg.get("arm")))
        except (OSError, ValueError) as e:
            print("autocompact-ab: unreadable manifest %s: %s" % (mf, e), file=sys.stderr)
            return 1
    legs += [(d, None) for d in a.doc]
    if not legs:
        print("usage: autocompact-ab.py [--manifest <fleet.json>]... [--doc <leg doc>]...", file=sys.stderr)
        return 2

    rows, seen = [], set()
    for doc, arm in legs:
        if not doc or doc in seen:
            continue
        seen.add(doc)
        r = leg_row(doc, arm, a.projects)
        if r is None:
            print("autocompact-ab: unreadable leg doc, skipped: %s" % doc, file=sys.stderr)
        elif r["wrapped"] or a.all:
            rows.append(r)

    summ = summary(rows)
    if a.json:
        print(json.dumps({"legs": rows, "summary": summ}, indent=2))
        return 0

    print("%-52s %-10s %5s %-24s %4s %9s %9s %9s %9s %8s %7s %-5s %3s %6s" % (
        "leg", "arm", "comp", "compaction-levels", "hand", "cache-rd", "cache-cr",
        "uncached", "cost-eq", "wall-min", "out/trn", "ci-1st", "rev", "pr"))
    for r in rows:
        lv = ",".join(fmt_tok(c["tokens"]) for c in r["compactions"]) or "-"
        print("%-52s %-10s %5d %-24s %4d %9s %9s %9s %9s %8.1f %7.0f %-5s %3d %6s" % (
            r["leg"][:52], r["arm"], len(r["compactions"]), lv[:24], r["handoffs"],
            fmt_tok(r["cache_read"]), fmt_tok(r["cache_create"]), fmt_tok(r["uncached"]),
            fmt_tok(r["cost_eq"]), r["wall_s"] / 60.0, r["mean_out_per_turn"],
            r["ci_first_try"], r["review_rounds"], r["pr"] or "-"))
        if r["transcripts"] == 0:
            print("  ^ no transcript found for this leg (customTitle not matched)")
    unl = [r for r in rows if r["arm"] == "unlabelled"]
    if unl:
        print("\n%d unlabelled leg(s) left out of the summary" % len(unl))
    print("\narm summary (means per leg)")
    print("%-5s %5s %6s %6s %10s %9s %8s %7s %4s  (legs without a transcript are excluded)" % (
        "arm", "legs", "comp", "hand", "cost-eq", "wall-min", "out/trn", "ci-1st", "rev"))
    for s in summ:
        if s["legs"] == 0:
            print("%-5s %5d  (no measured leg; %d unmeasured)" % (s["arm"], 0, s["unmeasured"]))
            continue
        print("%-5s %5d %6.2f %6.2f %10s %9.1f %8.0f %7s %4.2f" % (
            s["arm"], s["legs"], s["compactions"], s["handoffs"], fmt_tok(s["cost_eq"]),
            s["wall_s"] / 60.0, s["out_per_turn"], s["ci_first_try"], s["review_rounds"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
