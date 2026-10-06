#!/usr/bin/env python3
"""scripts/eval/review-panel/score.py - score critic-panel output against the
seed key (HIMMEL-4649): recall, precision and false-positive rate per critic,
per class and for the panel as a whole, with n and Wilson 95% intervals; one
row per sweep into the eval-runs ledger (scripts/eval/lib/eval_runs.py).

  score.py lint  [--fixtures DIR] [--key FILE]
  score.py score --outputs DIR [--fixtures DIR] [--key FILE] [--critics a,b]
                 [--only case-01,case-02] [--window N] [--json OUT]
                 [--ledger PATH | --no-ledger] [--meta-json J]

Inputs. fixtures/case-NN.patch are the frozen diffs the panel reviews;
key/seeds.json maps each case to its twin pair, kind (seeded | clean) and
defects ({id, class, file, line}). <outputs>/case-NN.md is the panel's stdout
for that case, <outputs>/case-NN.err its stderr (optional).

Matching (README "Matching rules"). A finding is a `- [<critic>-<n>]: <text>
[<file>:<line>]` bullet under Critical / Important / Suggestions. It hits a
defect when the file matches and |line - seed line| <= window (default 3)
(a LOCATION hit), and its text matches the defect class's keyword pattern
(a CLASS hit). recall counts defects with a location+class hit; recall_loc
counts location hits only (the upper bound, so a brittle keyword list shows
as a gap, not a silent loss); recall_gating counts hits at Critical or
Important, the severities the CR gate blocks on. precision = findings that
hit some defect / all findings. fp_rate = clean twins with >= 1 Critical or
Important finding / clean twins scored.

Exit: 0 scored / lint clean; 1 lint problems; 2 refused input.
Stdlib only; no network, no model call.
"""
import argparse
import hashlib
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

EVAL_ID = "review-panel"
SOURCE = "scripts/eval/review-panel/score.py"
DEFAULT_WINDOW = 3
GATING = ("crit", "imp")

# Class keyword patterns, matched case-insensitively against a finding's text.
# Deliberately broad: location already pins the finding to the seeded lines, so
# the class check only has to tell "the bug" from "some other remark here".
# ponytail: hand-written keywords, tuned on canned text only; recall_loc bounds
# the loss - hand-label the first real sweep's location-only hits and retune.
CLASS_PATTERNS = {
    "logic": r"off[- ]by[- ]one|one (too many|too few|fewer|extra|more|less)|invert|revers|wrong "
             r"(comparison|condition|operator|direction|count|boundary)|boundary|logic|always "
             r"(true|false|fails?|gives? up|retr)|never (retr|true|false)|immediately|"
             r"incorrect(ly)? (count|compar|condition)|keeps? (one )?fewer|deletes? (one|the newest)|"
             r"(should|must) be [<>]=?|[<>]=? (should|must)",
    "quoting": r"quot|word[- ]?split|glob|IFS|whitespace|spaces? in|\$\(ls|parsing ls|ls output",
    "fail-open": r"fail[s]?[- ]?open|fail[- ]closed|fails? (open|closed)|allow(s|ed)? .{0,40}"
                 r"(error|fail|missing|unreadable|invalid|malformed|exception)|"
                 r"(error|fail\w*|missing|unreadable|invalid|malformed|exception).{0,60}"
                 r"(allow|accept|pass|true|bypass)|bypass|swallow|suppress|silenc|"
                 r"2>/dev/null|returns? true|treated as (valid|allow)",
    "toctou": r"toctou|race|time[- ]of[- ]check|check[- ](then|and)[- ]\w+|symlink|atomic|"
              r"concurrent|noclobber|predictable|world[- ]writable|between the (check|exist)|"
              r"o_excl|mkstemp|mkdir",
    "test-cannot-fail": r"(cannot|can't|can never|never|always) (fail|pass)|vacuous|tautolog|"
                        r"itself|same (call|expression|value)|both sides|PIPESTATUS|pipefail|"
                        r"(status|rc|exit code) of (tee|the pipeline|the last)|tee'?s (exit|status)|"
                        r"not (actually )?(test|check|assert|verif)|no(thing)? (is )?(tested|checked|asserted)",
    "scope-creep": r"unrelated|scope|not mentioned|undocumented|unannounced|unexplained|"
                   r"silent(ly)? (chang|lower|rais|reduc|increas|shorten)|behaviou?r change|"
                   r"(retention|timeout|default)\b.{0,40}(chang|lower|rais|reduc|increas|shorten|from)|"
                   r"(chang|lower|rais|reduc|increas|shorten)\w*.{0,40}(retention|timeout|default)",
}
CLASSES = sorted(CLASS_PATTERNS)

# Strings that tie a fixture or a transcript to the key. A fixture carrying any
# of them (or a hint word) is refused by lint; a transcript carrying one is a
# leak: the critic saw (or echoed) the answer, so the sweep is inconclusive.
# ponytail: string evidence only - a critic that read the key and never echoed
# it is not caught; scan the critic's tool-call log once hermes records one.
KEY_MARKERS = ("review-panel/key", "seeds.json")
HINT_WORDS = re.compile(r"\b(seed(ed|s)?|inject(ed|ion)?|planted|defect|canary)\b", re.I)

SECTION = re.compile(r"^## (Critical Issues|Important Issues|Suggestions|"
                     r"Already Dispositioned Re-raises|Dropped Citations|Note|REVIEW NOT PERFORMED)")
SEV = {"Critical Issues": "crit", "Important Issues": "imp", "Suggestions": "sug"}
BULLET = re.compile(r"^- \[([A-Za-z0-9._]+(?:-[A-Za-z0-9._]+)*?)-(\d+)\]: (.*?)\s*\[([^\]\s]+):(\d+)\]\s*$")
UNAVAILABLE = re.compile(r"^- ([A-Za-z0-9._-]+): unavailable\b")


def norm_path(p):
    p = p.strip()
    for pre in ("a/", "b/", "./"):
        if p.startswith(pre):
            p = p[len(pre):]
    return p


def load_key(path):
    with open(path, encoding="utf-8") as fh:
        key = json.load(fh)
    if not isinstance(key, dict) or "cases" not in key or "canary" not in key:
        raise ValueError("key needs canary and cases")
    return key


def patch_added(text):
    """(new-file path, {added new-file line numbers}) of a one-file git diff."""
    path, added, new_line = None, set(), None
    for line in text.splitlines():
        if line.startswith("+++ "):
            path = norm_path(line[4:])
        elif line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            new_line = int(m.group(1)) if m else None
        elif new_line is not None:
            if line.startswith("+"):
                added.add(new_line)
                new_line += 1
            elif line.startswith(" ") or line == "":
                # An empty line is a blank context line whose leading space the
                # repo's trailing-whitespace hook strips (git apply reads it so).
                new_line += 1
    return path, added


def lint(fixtures, key_path):
    problems = []
    try:
        key = load_key(key_path)
    except (OSError, ValueError) as e:
        return ["key %s: %s" % (key_path, e)], 0, 0
    cases = key["cases"]
    files = sorted(f[:-6] for f in os.listdir(fixtures) if f.startswith("case-") and f.endswith(".patch"))
    if sorted(cases) != files:
        problems.append("fixtures and key disagree: only-fixture=%s only-key=%s"
                        % (sorted(set(files) - set(cases)), sorted(set(cases) - set(files))))
    pairs = {}
    for cid in files:
        with open(os.path.join(fixtures, cid + ".patch"), encoding="utf-8") as fh:
            text = fh.read()
        for marker in (key["canary"],) + KEY_MARKERS:
            if marker in text:
                problems.append("%s: carries key marker %r" % (cid, marker))
        m = HINT_WORDS.search(text)
        if m:
            problems.append("%s: carries hint word %r" % (cid, m.group(0)))
        c = cases.get(cid)
        if not c:
            continue
        path, added = patch_added(text)
        if c.get("kind") not in ("seeded", "clean"):
            problems.append("%s: kind must be seeded or clean" % cid)
        if (c.get("kind") == "seeded") != bool(c.get("defects")):
            problems.append("%s: a seeded case needs defects and a clean one none" % cid)
        for d in c.get("defects", []):
            if d.get("class") not in CLASS_PATTERNS:
                problems.append("%s: unknown class %r" % (cid, d.get("class")))
            if norm_path(d.get("file", "")) != path:
                problems.append("%s: seed file %r is not the diff's %r" % (cid, d.get("file"), path))
            if d.get("line") not in added:
                problems.append("%s: seed line %r is not an added line of its diff" % (cid, d.get("line")))
        pairs.setdefault(c.get("pair"), []).append((c.get("kind"), path))
    for pair, members in sorted(pairs.items()):
        kinds = sorted(k for k, _ in members)
        if kinds != ["clean", "seeded"] or len({p for _, p in members}) != 1:
            problems.append("pair %s: needs one seeded and one clean twin of the same file, got %s" % (pair, members))
    n_seeded = sum(1 for c in cases.values() if c.get("kind") == "seeded")
    return problems, n_seeded, len(cases) - n_seeded


def parse_review(text):
    """(findings, unavailable critics, performed). A finding is a dict with
    critic, sev, file, line, text; bullets outside the three severity
    sections (re-raises, dropped citations) are not findings."""
    findings, unavailable, performed, sev, in_note = [], set(), True, None, False
    declared, counted = {}, {}
    for line in text.splitlines():
        m = SECTION.match(line)
        if m:
            name = m.group(1)
            sev = SEV.get(name)
            if sev:
                n = re.search(r"\((\d+) found\)", line)
                declared[sev] = int(n.group(1)) if n else -1
                counted.setdefault(sev, 0)
            in_note = name == "Note"
            if name == "REVIEW NOT PERFORMED":
                performed = False
            continue
        if line.startswith("Unavailable critics:"):
            in_note = True
            continue
        u = UNAVAILABLE.match(line)
        if u and (in_note or not performed):
            unavailable.add(u.group(1))
            continue
        if sev and line.startswith("- [") and not line.startswith("- [citation-guard"):
            counted[sev] += 1
        b = BULLET.match(line)
        if b and sev:
            critic = b.group(1)
            if critic.startswith("citation-guard"):
                continue
            findings.append({"critic": critic, "sev": sev, "text": b.group(3),
                             "file": norm_path(b.group(4)), "line": int(b.group(5))})
    # The panel prints all three severity headings, each with its bullet count,
    # on every completed review; a transcript missing a heading or a bullet was
    # cut short and is not a zero-finding review.
    if not text.lstrip().startswith("# Critic Panel Review") or set(SEV.values()) - set(declared) \
            or declared != counted:
        performed = False
    return findings, unavailable, performed


def loc_hit(f, d, window):
    return f["file"] == norm_path(d["file"]) and abs(f["line"] - d["line"]) <= d.get("window", window)


def class_hit(f, d):
    return re.search(CLASS_PATTERNS[d["class"]], f["text"], re.I) is not None


def wilson(k, n, z=1.959964):
    if not n:
        return None
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return {"lo": round(max(0.0, mid - half), 4), "hi": round(min(1.0, mid + half), 4)}


def ratio(k, n):
    return (k / n) if n else None


def score(outputs, fixtures, key_path, critics, only=None, window=DEFAULT_WINDOW):
    key = load_key(key_path)
    cases = key["cases"]
    ids = sorted(cases) if not only else [c for c in only if c in cases]
    if only and len(ids) != len(only):
        raise ValueError("--only names cases the key lacks: %s" % sorted(set(only) - set(cases)))
    leak_markers = (key["canary"],) + KEY_MARKERS

    per_case, leaks, unscored = {}, [], []
    for cid in ids:
        md = os.path.join(outputs, cid + ".md")
        err = os.path.join(outputs, cid + ".err")
        text = open(md, encoding="utf-8", errors="replace").read() if os.path.isfile(md) else ""
        etext = open(err, encoding="utf-8", errors="replace").read() if os.path.isfile(err) else ""
        if any(m in text or m in etext for m in leak_markers):
            leaks.append(cid)
        findings, unavailable, performed = parse_review(text)
        rc = os.path.join(outputs, cid + ".rc")
        if os.path.isfile(rc) and open(rc).read().strip() != "0":
            performed = False  # the panel exits 0 only when >= 1 critic responded
        if not performed:
            unscored.append(cid)
            continue
        per_case[cid] = (findings, unavailable)

    seen = set(critics)
    for findings, unavailable in per_case.values():
        seen.update(f["critic"] for f in findings)
    members = sorted(seen) + ["panel"]

    metrics, ci, case_rows = {}, {}, {}
    n_defects = sum(len(cases[c]["defects"]) for c in ids)
    for who in members:
        hit = hit_loc = hit_gate = 0
        defects = true_f = all_f = clean_n = clean_fp = seeded_n = 0
        by_class = {c: [0, 0] for c in CLASSES}
        for cid, (findings, unavailable) in sorted(per_case.items()):
            if who != "panel" and who in unavailable:
                continue
            mine = findings if who == "panel" else [f for f in findings if f["critic"] == who]
            c = cases[cid]
            all_f += len(mine)
            true_f += sum(1 for f in mine if any(loc_hit(f, d, window) and class_hit(f, d) for d in c["defects"]))
            if c["kind"] == "clean":
                clean_n += 1
                fp = any(f["sev"] in GATING for f in mine)
                clean_fp += fp
                if who == "panel":
                    case_rows[cid] = {"findings": len(mine), "fp": fp}
                continue
            seeded_n += 1
            got = 0
            for d in c["defects"]:
                defects += 1
                by_class[d["class"]][1] += 1
                lh = [f for f in mine if loc_hit(f, d, window)]
                ch = [f for f in lh if class_hit(f, d)]
                hit_loc += bool(lh)
                hit += bool(ch)
                hit_gate += any(f["sev"] in GATING for f in ch)
                by_class[d["class"]][0] += bool(ch)
                got += bool(ch)
            if who == "panel":
                case_rows[cid] = {"findings": len(mine), "hit": got, "defects": len(c["defects"])}
        vals = {
            "recall": (hit, defects), "recall_loc": (hit_loc, defects),
            "recall_gating": (hit_gate, defects), "precision": (true_f, all_f),
            "fp_rate": (clean_fp, clean_n),
        }
        for name, (k, n) in vals.items():
            metrics["%s.%s" % (who, name)] = ratio(k, n)
            b = wilson(k, n)
            if b:
                ci["%s.%s" % (who, name)] = b
        metrics["%s.findings" % who] = all_f
        metrics["%s.seeded_scored" % who] = seeded_n
        metrics["%s.clean_scored" % who] = clean_n
        for cls, (k, n) in by_class.items():
            if n:
                metrics["%s.class.%s.recall" % (who, cls)] = ratio(k, n)
                metrics["%s.class.%s.n" % (who, cls)] = n
    metrics.update({"defects": n_defects, "cases": len(ids), "unscored": len(unscored),
                    "leaked": len(leaks)})
    status = "inconclusive" if (leaks or len(unscored) == len(ids)) else ("partial" if unscored else "ok")
    return {"status": status, "metrics": metrics, "ci": ci, "cases": case_rows,
            "leaks": leaks, "unscored": unscored, "critics": members[:-1], "window": window}


def fixture_set_hash(fixtures, key_path, ids):
    import hashlib
    h = hashlib.sha256()
    for cid in ids:
        h.update(cid.encode())
        h.update(eval_runs.file_sha256(os.path.join(fixtures, cid + ".patch")).encode())
    h.update(eval_runs.file_sha256(key_path).encode())
    return h.hexdigest()[:16]


def report(res):
    m = res["metrics"]
    out = ["review-panel: %d cases, %d defects, unscored=%d, leaked=%d, status=%s"
           % (m["cases"], m["defects"], m["unscored"], m["leaked"], res["status"])]
    for cid in res["leaks"]:
        out.append("LEAK %s: its transcript carries a key marker - the critic saw the answer" % cid)

    def fmt(x):
        return "  -  " if x is None else "%.2f" % x
    out.append("%-12s %-8s %-8s %-8s %-9s %-8s %s" % ("critic", "recall", "loc", "gating", "precision", "fp_rate", "n"))
    for who in res["critics"] + ["panel"]:
        out.append("%-12s %-8s %-8s %-8s %-9s %-8s n=%d seeded, %d clean, %d findings" % (
            who, fmt(m.get(who + ".recall")), fmt(m.get(who + ".recall_loc")),
            fmt(m.get(who + ".recall_gating")), fmt(m.get(who + ".precision")),
            fmt(m.get(who + ".fp_rate")), m.get(who + ".seeded_scored", 0),
            m.get(who + ".clean_scored", 0), m.get(who + ".findings", 0)))
    for who in res["critics"] + ["panel"]:
        parts = ["%s %s (n=%d)" % (c, fmt(m.get("%s.class.%s.recall" % (who, c))), m.get("%s.class.%s.n" % (who, c), 0))
                 for c in CLASSES if ("%s.class.%s.n" % (who, c)) in m]
        if parts:
            out.append("%-12s by class: %s" % (who, "; ".join(parts)))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("lint")
    ps = sub.add_parser("score")
    for p in (pl, ps):
        p.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
        p.add_argument("--key", default=os.path.join(HERE, "key", "seeds.json"))
    ps.add_argument("--outputs", required=True)
    ps.add_argument("--critics", default="")
    ps.add_argument("--only", default="")
    ps.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    ps.add_argument("--json")
    ps.add_argument("--ledger")
    ps.add_argument("--no-ledger", action="store_true")
    ps.add_argument("--meta-json", default="{}")
    a = ap.parse_args(argv)

    if a.cmd == "lint":
        problems, n_seeded, n_clean = lint(a.fixtures, a.key)
        for p in problems:
            print("lint: %s" % p, file=sys.stderr)
        print("review-panel lint: %d seeded, %d clean, %d problem(s)" % (n_seeded, n_clean, len(problems)))
        return 1 if problems else 0

    try:
        meta = json.loads(a.meta_json)
        if not isinstance(meta, dict):
            raise ValueError("--meta-json must be an object")
        critics = [c for c in a.critics.split(",") if c]
        only = [c for c in a.only.split(",") if c]
        res = score(a.outputs, a.fixtures, a.key, critics, only or None, a.window)
    except (OSError, ValueError) as e:
        print("score.py: %s" % e, file=sys.stderr)
        return 2
    print(report(res))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=2, sort_keys=True)
    if not a.no_ledger:
        ids = only or sorted(load_key(a.key)["cases"])
        config = {"fixture_set": fixture_set_hash(a.fixtures, a.key, ids),
                  "critics": res["critics"], "window": a.window,
                  "classes": CLASSES, "gating": list(GATING),
                  "class_patterns": hashlib.sha256(json.dumps(
                      CLASS_PATTERNS, sort_keys=True).encode()).hexdigest()[:16]}
        meta = dict(meta, leaks=res["leaks"], unscored=res["unscored"])
        row = eval_runs.make_row(EVAL_ID, SOURCE, config, res["metrics"], n=res["metrics"]["cases"],
                                 status=res["status"], ci=res["ci"], ci_level=0.95 if res["ci"] else None,
                                 ci_method="wilson" if res["ci"] else None, cases=res["cases"] or None,
                                 artifact=os.path.abspath(a.outputs), meta=meta, repo=HERE)
        eval_runs.append_safe(row, a.ledger, who="review-panel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
