#!/usr/bin/env python3
# scripts/eval/autocompact-ab.py - per-leg report for the HIMMEL-5193 autocompact
# A/B (200k control vs 400k audited arm). Local-only: reads leg docs and Claude
# Code session JSONL, runs no inference, sends nothing anywhere.
#
#   autocompact-ab.py [--manifest <fleet.json>]... [--doc <leg doc>]...
#                     [--projects <dir>] [--all] [--json]
#
# Legs come from fleet manifests (legs[].doc, optional legs[].arm) and/or --doc.
# One row per TICKET-N<k> (scripts/lib/leg-identity.sh): a RESUME successor,
# listed or found beside its parent, folds into the parent's row, and the leg is
# wrapped when the LAST doc in the chain ends in WRAPPED. Only wrapped legs are
# reported unless --all, and --all rows are marked open and never averaged. The
# arm is the manifest `arm` (the launcher's record); a leg without one is
# `unlabelled`, and a chain whose listed docs carry different arms, or that
# holds a doc nobody listed, is `unproven`; both are left out of the summary. The
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
import argparse, glob, json, os, re, subprocess, sys
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
    calls, comps, stamps, seen_b = {}, [], [], set()
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
                # a resumed transcript carries its parent's history: the same
                # boundary (uuid, else timestamp + level) is one compaction
                bkey = row.get("uuid") or (row.get("timestamp"), meta.get("preTokens"))
                if bkey in seen_b:
                    continue
                seen_b.add(bkey)
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


LEG_IDENTITY = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "lib", "leg-identity.sh")


_IDENTITY_CACHE = {}


def identity(doc):
    """(label, base, session names) from scripts/lib/leg-identity.sh, the one
    derivation of a leg's identity; never a local regex. Warns on stderr when
    the call fails or the doc name is not a leg doc (the stem is its own leg)."""
    if doc in _IDENTITY_CACHE:
        return _IDENTITY_CACHE[doc]
    stem = os.path.basename(doc)
    stem = stem[:-3] if stem.endswith(".md") else stem
    res, why = None, None
    try:
        p = subprocess.run(
            ["bash", "-c", 'source "$1"; leg_identity "$2"; leg_base "$2"', "_", LEG_IDENTITY, doc],
            capture_output=True, text=True, timeout=30)
        out = p.stdout.split("\n")
        label, _, names = out[0].partition("\t")
        base = out[1] if len(out) > 1 and out[1] else label
        if p.returncode == 0 and label:
            res = (label, base, [n for n in names.split(",") if n])
            if label == stem:
                why = "not a leg doc name, grouped by its own stem"
        else:
            why = "call failed (rc=%d)" % p.returncode
    except (OSError, subprocess.SubprocessError) as e:
        why = "call failed (%s)" % e
    if why:
        print("autocompact-ab: leg-identity: %s: %s" % (stem, why), file=sys.stderr)
    _IDENTITY_CACHE[doc] = res or (stem, stem, [stem])
    return _IDENTITY_CACHE[doc]


def chain_key(doc, base):
    """One leg = TICKET-N<k>: the ticket key of the stem plus leg_base."""
    stem = os.path.basename(doc)
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*-\d+)-", stem)
    return (m.group(1) if m else "", base)


def resume_siblings(doc):
    """RESUME docs beside `doc` that continue the same TICKET-N<k> leg."""
    m = STEM.match(os.path.basename(doc))
    if not m:
        return []
    lead = "%s-%s" % (m.group(1), m.group(2))
    pat = os.path.join(os.path.dirname(doc), "%s*RESUME*.md" % lead)
    # the glob has no boundary after the label (N902 also matches N9020)
    return [r for r in glob.glob(pat)
            if not os.path.basename(r)[len(lead):len(lead) + 1].isdigit()]


def parent_docs(doc):
    """Docs beside `doc` that ARE the leg itself (leg-identity label == base),
    whatever their naming: a listed RESUME successor does not follow the parent's
    -RESUME glob, so its parent brief is found here, never by a local regex."""
    m = STEM.match(os.path.basename(doc))
    if not m:
        return []
    lead = "%s-%s" % (m.group(1), m.group(2))
    pat = os.path.join(os.path.dirname(doc), "%s*.md" % lead)
    out = []
    for p in glob.glob(pat):
        if os.path.basename(p)[len(lead):len(lead) + 1].isdigit():
            continue
        label, base, _ = identity(p)
        if label == base:
            out.append(p)
    return out


def chain_rows(members, projects, claimed):
    """members: {doc: {manifest arms}} sharing one TICKET-N<k>; `claimed` is the
    set of transcript paths earlier rows already own. One row per leg."""
    docs = {doc: None for doc in members}
    for doc in list(docs):
        for r in resume_siblings(doc) + parent_docs(doc):
            docs.setdefault(r, None)
    info = {}
    for doc in docs:
        label, base, names = identity(doc)
        info[doc] = (label, base, names)
    # parent first (label == base), then successors by their letters
    order = sorted(docs, key=lambda p: (info[p][0] != info[p][1], info[p][0], p))
    parsed = [(p, read_doc(p)) for p in order]
    parsed = [(p, d) for p, d in parsed if d is not None]
    if not parsed:
        return None
    head = parsed[0][0]
    stem = os.path.basename(head)
    stem = stem[:-3] if stem.endswith(".md") else stem
    markers = [m for _, d in parsed for m in d["markers"]]
    last = parsed[-1][1]["markers"]
    # the manifest arm is the launcher's record; the brief line alone is not
    # evidence (a 200000 launch can carry it), so it is never a fallback. A
    # successor folds into its parent only on an equal manifest arm; a chain
    # whose listed docs disagree (or lack the record) is arm-unproven.
    # (a doc carried with two different arms is a contradiction, not a record)
    arms = set()
    for p, _ in parsed:
        # a chain doc nobody listed (found only by the RESUME glob) carries no
        # launch record: it makes the chain unproven, never inherits an arm
        arms |= (members[p] or {None}) if p in members else {None}
    if len(arms) == 1:
        arm = next(iter(arms)) or "unlabelled"
    else:
        arm = "unproven"
    names, seen_n = [], set()
    for p, _ in parsed:
        n = os.path.basename(p)[:-3] if p.endswith(".md") else os.path.basename(p)
        for x in [n] + info[p][2]:
            if x not in seen_n:
                seen_n.add(x)
                names.append(x)
    row = {"leg": stem, "arm": arm,
           "chain": [os.path.basename(p) for p, _ in parsed],
           "wrapped": bool(last) and last[-1][0] == "WRAPPED",
           "handoffs": len(parsed) - 1}
    row.update(pr_outcome(markers))
    # a session titled for two legs belongs to the first row that claims it
    paths = [p for p in find_transcripts(projects, names) if p not in claimed]
    claimed.update(paths)
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
        # (a transcript with no usable assistant usage row counts as no transcript)
        rs = [r for r in every if r["transcripts"] > 0 and r["calls"] > 0]
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

    # one row per TICKET-N<k>: a listed RESUME successor folds into its parent
    groups, order = {}, []
    for doc, arm in legs:
        if not doc:
            continue
        if not os.path.isfile(doc):
            print("autocompact-ab: unreadable leg doc, skipped: %s" % doc, file=sys.stderr)
            continue
        _, base, _ = identity(doc)
        key = chain_key(doc, base)
        if key not in groups:
            groups[key] = {}
            order.append(key)
        groups[key].setdefault(doc, set())
        if arm:
            groups[key][doc].add(arm)
    rows, claimed = [], set()
    for key in order:
        r = chain_rows(groups[key], a.projects, claimed)
        if r is None:
            print("autocompact-ab: unreadable leg doc, skipped: %s" % key[1], file=sys.stderr)
        elif r["wrapped"] or a.all:
            rows.append(r)

    # open legs (--all) are listed for inspection, never averaged into the arms
    summ = summary([r for r in rows if r["wrapped"]])
    if a.json:
        print(json.dumps({"legs": rows, "summary": summ}, indent=2))
        return 0

    print("%-52s %-8s %-10s %5s %-24s %4s %9s %9s %9s %9s %8s %7s %-5s %3s %6s" % (
        "leg", "state", "arm", "comp", "compaction-levels", "hand", "cache-rd", "cache-cr",
        "uncached", "cost-eq", "wall-min", "out/trn", "ci-1st", "rev", "pr"))
    for r in rows:
        lv = ",".join(fmt_tok(c["tokens"]) for c in r["compactions"]) or "-"
        print("%-52s %-8s %-10s %5d %-24s %4d %9s %9s %9s %9s %8.1f %7.0f %-5s %3d %6s" % (
            r["leg"][:52], "wrapped" if r["wrapped"] else "open", r["arm"], len(r["compactions"]), lv, r["handoffs"],
            fmt_tok(r["cache_read"]), fmt_tok(r["cache_create"]), fmt_tok(r["uncached"]),
            fmt_tok(r["cost_eq"]), r["wall_s"] / 60.0, r["mean_out_per_turn"],
            r["ci_first_try"], r["review_rounds"], r["pr"] or "-"))
        if r["transcripts"] == 0 or r["calls"] == 0:
            print("  ^ no measured transcript for this leg (customTitle not matched or no usage rows)")
    unl = [r for r in rows if r["arm"] in ("unlabelled", "unproven")]
    if unl:
        print("\n%d unlabelled or arm-unproven leg(s) left out of the summary" % len(unl))
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
