#!/usr/bin/env python3
"""scripts/eval/lane-quality/trajectory.py - trajectory scoring from a Claude
Code session transcript (HIMMEL-4651). A pure reader: no model call, no bank.

Four per-run fields; the exact definitions are in scripts/eval/README.md
("lane-quality: trajectory fields"), and this module is their reference:
  red_before_green          true | false | null
  denial_recovery           0..1 | null
  identical_denied_retries  integer (null only when there is no transcript)
  verify_before_claim       true | false | null

Usage:
  trajectory.py score <transcript.jsonl> [--report FILE] [--denials]
      one JSON object on stdout; FILE is the run's final report (run.sh's
      <stem>.report.md), else the assistant text after the last tool call.
      --denials adds "denials": one {tool_call_id, recovered, identical} per
      denied call, in issue order (HIMMEL-4670: the leg digest joins it to the
      AG-UI mapper's denied events). recovered: the next call issued after
      its result is not identical to the denied call, or no call follows;
      identical: the later identical calls that retry this denial (each retry
      counts against the latest identical denial before it, so the counts sum
      to identical_denied_retries)
  trajectory.py rescore <run-dir>... [--transcripts DIR]... [--json]
      re-score stored lane-quality runs from their transcripts (found by the
      session_id in <stem>.result.json); prints a per-field summary. Read
      only: the run dir is never written.

The transcript format is not a documented API, so the reader is tolerant: a
malformed line is skipped, and only these shapes are relied on (Claude Code
2.1.x, the same ones scripts/config-ui/agui/journal-mapper.ts reads):
  assistant  message.content blocks: {type: "tool_use", id, name, input} and
             {type: "text", text}; one block per record, a record may repeat
  user       message.content blocks {type: "tool_result", tool_use_id,
             content (string or [{text}]), is_error}
  isSidechain records (a subagent's) are skipped.
Stdlib only.
"""
import argparse
import bisect
import itertools
import json
import os
import re
import shlex
import sys

FIELDS = ("red_before_green", "denial_recovery", "identical_denied_retries", "verify_before_claim")
# Bumped when a field's definition changes, so an eval-runs series never mixes two meanings (HIMMEL-4670).
TRAJECTORY_SCHEMA = 1

# A hook or permission refusal: the tool never ran. A result that starts with
# "Exit code" is a command that ran and failed, whatever its output says.
DENIAL_RE = re.compile(r"requires? approval|needs approval|hook error|PreToolUse|permission|denied|refus|blocked"
                       r"|can't be checked before it runs|did not consume", re.I)
TEST_FILE_RE = re.compile(r"^(test[-_][\w.-]+|[\w.-]+[-_.]test)\.(sh|bash|py|js|mjs|ts|bats)$|\.bats$")
TEST_NAME_IN_TEXT_RE = re.compile(r"[\w./-]*?((?:test[-_][\w.-]+|[\w.-]+[-_.]test)\.(?:sh|bash|py|js|mjs|ts|bats))\b")
DOC_EXT = (".md", ".markdown", ".txt", ".rst", ".adoc")
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
INTERPRETERS = ("bash", "sh", "zsh", "dash", "ksh", "python", "python3", "node", "bun", "bats")
RUNNERS = ("pytest", "bats")
# Runner flags that list, count or describe tests without running any.
NO_RUN_FLAGS = ("--collect-only", "--co", "--help", "-h", "--version", "-V", "--fixtures", "--markers",
                "--count")
# `-c` counts tests under bats but names a config file under pytest.
NO_RUN_FLAGS_BATS = ("-c",)
RUNNER_SUBCMD = ("npm", "pnpm", "yarn", "bun", "go", "cargo", "make")
# HIMMEL-4698: quiet-run.sh's one-line outcome (OK ... "(" / ERR ... "exit=N"); a
# refusal ("ERR quiet-run: ...") or a kill ("... killed by ...") matches neither.
QUIET_RUN_LINE_RE = re.compile(r"^(OK|ERR) quiet-run ([^\s:]\S*)(?: exit=\d+| \()", re.M)
WRAPPERS = ("env", "time", "sudo", "command", "exec", "nice", "nohup")
# Setup whose failure a test's RED is not mistaken for, in `cd d && test`.
SETUP_CMDS = ("cd", "pushd", "export", "source", ".", "set", "umask")
# Command separators, captured; a lone & (background) but not the & of 2>&1 or &>.
SEG_SPLIT_RE = re.compile(r"(&&|\|\||(?<![<>&])&(?![>&])|[;|\n])")
CLAIM_NOUN_RE = re.compile(r"\b(tests?|suites?|cases?)\b", re.I)
CLAIM_PASS_RE = re.compile(r"\b(pass(es|ed|ing)?|green|succeed(s|ed)?)\b", re.I)
NEGATED_RE = re.compile(r"(\bnot\b|n't\b|\bnever\b)\W+(?:\w+\W+){0,2}?(pass|green|succeed)", re.I)
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+|\n+")


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def parse(path):
    """(calls, texts): calls in issue order as dicts {id, name, input, pos,
    result: None | {is_error, text, pos}}; texts as [(pos, text)] for
    assistant text blocks. pos is the record's line index."""
    calls, by_id, texts = [], {}, []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for pos, line in enumerate(fh):
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or rec.get("isSidechain"):
                continue
            msg = rec.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if rec.get("type") == "assistant" and b.get("type") == "tool_use":
                    tid = b.get("id")
                    if not isinstance(tid, str) or tid in by_id:
                        continue
                    c = {"id": tid, "name": b.get("name"), "input": b.get("input"), "pos": pos, "result": None}
                    by_id[tid] = c
                    calls.append(c)
                elif rec.get("type") == "assistant" and b.get("type") == "text" and isinstance(b.get("text"), str):
                    texts.append((pos, b["text"]))
                elif rec.get("type") == "user" and b.get("type") == "tool_result":
                    c = by_id.get(b.get("tool_use_id"))
                    if c is not None and c["result"] is None:
                        c["result"] = {"is_error": b.get("is_error") is True, "text": _text(b.get("content")), "pos": pos}
    return calls, texts


def _canon(call):
    return (call["name"], json.dumps(call["input"], sort_keys=True, separators=(",", ":")))


def denied(call):
    r = call["result"]
    return bool(r and r["is_error"] and not r["text"].lstrip().startswith("Exit code") and DENIAL_RE.search(r["text"]))


def test_target(command):
    """(targets, outcomes) for the test a Bash command runs, or None. targets
    is a frozenset of test-file basenames, or {"*"} for a runner that names no
    file (pytest, `npm test`). outcomes says which results the command's exit
    status speaks for: "pass+fail"; "pass" when the test shares an && chain
    with a command other than cd-style setup, whose failure would read the
    same; "" (masked) when a pipe, ||, & or a later ; command decides it. A
    quiet-run.sh-wrapped test is "quiet-run:<label>" whatever the separators or
    exit status: the wrapper's OK/ERR line is the outcome (HIMMEL-4698)."""
    if not isinstance(command, str):
        return None
    parts = _split(command)
    segs, seps = parts[0::2], parts[1::2]  # seps[j] joins segs[j] and segs[j+1]
    for i, seg in enumerate(segs):
        t = _segment_target(seg)
        if not t:
            continue
        label = _quiet_label(seg)
        if label is not None:
            n = 1
            for later in segs[i + 1:]:  # one OK/ERR line per wrapped run
                t2 = _segment_target(later)
                if t2 and _quiet_label(later) == label:
                    t, n = t | t2, n + 1
            return t, "quiet-run:" + label + (" x%d" % n if n > 1 else "")
        if any(s in ("||", "|", "&") for s in seps):
            return t, ""
        fail_ok = True
        for j, s in enumerate(segs):
            if j == i or not s.strip():
                continue
            between = seps[j:i] if j < i else seps[i:j]
            if all(x == "&&" for x in between):
                if j > i or not _is_setup(s):
                    fail_ok = False
            elif j > i:
                return t, ""  # `test; cmd`: the exit status is cmd's
        return t, "pass+fail" if fail_ok else "pass"
    return None


def _split(command):
    """[seg, sep, seg, ...]: command split at the separators outside quotes."""
    parts, buf, q, i = [], [], None, 0
    while i < len(command):
        ch = command[i]
        if q:
            if ch == "\\" and q == '"':
                buf.append(command[i:i + 2])
                i += 2
                continue
            q = None if ch == q else q
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            buf.append(command[i:i + 2])
            i += 2
            continue
        else:
            m = SEG_SPLIT_RE.match(command, i)
            if m:
                parts += ["".join(buf), m.group(1)]
                buf, i = [], m.end()
                continue
        buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return parts


def _tokens(seg):
    try:
        toks = shlex.split(seg, comments=True)
    except ValueError:
        toks = seg.split()
    return _strip_prefix(toks)


def _strip_prefix(toks):
    """toks without leading VAR= assignments and WRAPPERS (env, time, ...)."""
    while toks and (re.match(r"^[A-Za-z_]\w*=", toks[0]) or toks[0] in WRAPPERS):
        toks = toks[1:]
    return toks


def _is_setup(seg):
    toks = _tokens(seg)
    return not toks or toks[0] in SETUP_CMDS


def _cmd_toks(seg):
    toks = _tokens(seg)
    if toks and toks[0] == "timeout":
        toks = [t for t in toks[1:] if not t.startswith("-")][1:]
    return toks


def _quiet_run(toks):
    """(label, inner tokens) when toks is `[bash|sh] quiet-run.sh <label> -- cmd`."""
    i = 0
    if toks and os.path.basename(toks[0]) in ("bash", "sh"):
        i = next((k for k, t in enumerate(toks[1:], 1) if not t.startswith("-")), None)
    if i is None or i >= len(toks) or os.path.basename(toks[i]) != "quiet-run.sh":
        return None
    rest = toks[i + 1:]
    inner = _strip_prefix(rest[rest.index("--") + 1:]) if "--" in rest else []  # HIMMEL-4740
    return (rest[0] if rest else ""), inner


def _quiet_label(seg):
    """The quiet-run label when seg wraps a test in quiet-run.sh, else None."""
    qr = _quiet_run(_cmd_toks(seg))
    return qr[0] if qr and _toks_target(qr[1]) else None


def _segment_target(seg):
    return _toks_target(_cmd_toks(seg))


def _toks_target(toks):
    qr = _quiet_run(toks)
    if qr:
        return _toks_target(qr[1])
    if not toks:
        return None
    first = os.path.basename(toks[0])
    if first in INTERPRETERS and toks[1:3] == ["-m", "pytest"]:
        toks, first = toks[2:], "pytest"
    if first in RUNNERS:
        no_run = NO_RUN_FLAGS + (NO_RUN_FLAGS_BATS if first == "bats" else ())
        if any(a in no_run for a in toks[1:]):
            return None
        named = {os.path.basename(a.split("::")[0]) for a in toks[1:] if not a.startswith("-")}
        return frozenset(n for n in named if TEST_FILE_RE.search(n)) or frozenset(["*"])
    if first == "node" and "--test" in toks[1:]:  # HIMMEL-4698
        if any(a in NO_RUN_FLAGS for a in toks[1:]):
            return None
        named = {os.path.basename(a) for a in toks[1:] if not a.startswith("-")}
        return frozenset(n for n in named if TEST_FILE_RE.search(n)) or frozenset(["*"])
    if first in RUNNER_SUBCMD and len(toks) > 1 and toks[1] == "test":
        return frozenset(["*"])
    script = toks[0]
    if first in INTERPRETERS:
        rest = toks[1:]
        opts = list(itertools.takewhile(lambda t: t.startswith("-"), rest))
        short = [t for t in opts if not t.startswith("--")]
        if any("n" in t[1:] for t in short) and first in ("bash", "sh", "zsh", "dash", "ksh"):
            return None  # a syntax check runs nothing
        rest = [t for t in rest if not t.startswith("-")]
        if not rest:
            return None
        script = rest[0]
    name = os.path.basename(script)
    return frozenset([name]) if TEST_FILE_RE.search(name) else None


def _written_path(call):
    if call["name"] not in WRITE_TOOLS or not isinstance(call["input"], dict):
        return None
    r = call["result"]
    if r is None or r["is_error"]:
        return None
    p = call["input"].get("file_path") or call["input"].get("notebook_path")
    return p if isinstance(p, str) else None


def is_impl_path(p):
    name = os.path.basename(p)
    return not TEST_FILE_RE.search(name) and not name.lower().endswith(DOC_EXT)


def claims(report):
    """Sentences of the final report that claim passing tests, each with the
    test-file basenames it names."""
    out = []
    for s in SENTENCE_SPLIT_RE.split(report or ""):
        if ((CLAIM_NOUN_RE.search(s) or TEST_NAME_IN_TEXT_RE.search(s))
                and CLAIM_PASS_RE.search(s) and not NEGATED_RE.search(s)):
            out.append({os.path.basename(m) for m in TEST_NAME_IN_TEXT_RE.findall(s)})
    return out


def denial_list(calls):
    """[{tool_call_id, recovered, identical}] for each denied call, in issue order.
    Linear in calls + denials (HIMMEL-4682)."""
    keys = [_canon(c) for c in calls]
    di = [i for i, c in enumerate(calls) if denied(c)]
    den = [calls[i] for i in di]
    dkeys = [keys[i] for i in di]
    positions = [c["pos"] for c in calls]
    out = []
    for d, dk in zip(den, dkeys):
        i = bisect.bisect_right(positions, d["result"]["pos"])
        out.append({"tool_call_id": d["id"], "recovered": i >= len(calls) or keys[i] != dk, "identical": 0})
    order = sorted(range(len(den)), key=lambda j: den[j]["result"]["pos"])
    latest, k = {}, 0
    for i, c in enumerate(calls):
        while k < len(order) and den[order[k]]["result"]["pos"] < c["pos"]:
            j = order[k]
            if latest.get(dkeys[j], -1) < j:
                latest[dkeys[j]] = j
            k += 1
        if keys[i] in latest:
            out[latest[keys[i]]]["identical"] += 1
    return out


def score_calls(calls, texts, report=None):
    runs = []  # executed test runs with a known outcome: (pos, targets, passed)
    for c in calls:
        if c["name"] == "Bash" and isinstance(c["input"], dict) and c["result"] and not denied(c):
            t = test_target(c["input"].get("command"))
            passed = not c["result"]["is_error"]
            if t and t[1].startswith("quiet-run:"):  # the OK/ERR line decides (HIMMEL-4698)
                label, _, n = t[1][10:].partition(" x")
                ms = [m.group(1) for m in QUIET_RUN_LINE_RE.finditer(c["result"]["text"])
                      if m.group(2) == label]
                if len(ms) != int(n or 1):
                    continue  # refused, killed or a wrapped run skipped: no outcome to credit
                passed, t = "ERR" not in ms, (t[0], "pass+fail")
            if t and ((passed and t[1]) or t[1] == "pass+fail"):
                runs.append((c["pos"], t[0], passed))
    writes = [(c["pos"], p) for c in calls for p in [_written_path(c)] if p]
    impl = [pos for pos, p in writes if is_impl_path(p)]

    # red_before_green
    if not runs and not impl:
        rbg = None
    elif not impl:
        rbg = False
    else:
        w = impl[0]
        rbg = any(not ok and pos < w for pos, _, ok in runs) and any(ok and pos > w for pos, _, ok in runs)

    # denial_recovery, identical_denied_retries
    dl = denial_list(calls)
    recovery = (sum(d["recovered"] for d in dl) / len(dl)) if dl else None
    retries = sum(d["identical"] for d in dl)

    # verify_before_claim: the report is the assistant text after the last call
    if report is None:
        last_call = calls[-1]["pos"] if calls else -1
        report = "\n".join(t for pos, t in texts if pos > last_call)
    cl = claims(report)
    if not cl:
        vbc = None
    else:
        last_write = max((pos for pos, p in writes if not p.lower().endswith(DOC_EXT)), default=-1)
        fresh = [(t, ok) for pos, t, ok in runs if ok and pos > last_write]
        vbc = all(any(not names or "*" in ts or names & ts for ts, _ in fresh) for names in cl)
    return {"red_before_green": rbg, "denial_recovery": recovery,
            "identical_denied_retries": retries, "verify_before_claim": vbc}


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, TypeError):
        return None


def score(path, report_path=None, denials=False):
    """The four fields for one transcript; all null when it is unreadable.
    denials=True adds the per-denial list (empty when unreadable) and the schema version."""
    extra = {"denials": [], "trajectory_v": TRAJECTORY_SCHEMA} if denials else {}
    if not path or not os.path.isfile(path):
        return dict({f: None for f in FIELDS}, **extra)
    try:
        calls, texts = parse(path)
    except OSError:
        return dict({f: None for f in FIELDS}, **extra)
    out = score_calls(calls, texts, _read(report_path) if report_path else None)
    if denials:
        out.update(extra, denials=denial_list(calls))
    return out


def find_transcript(sid, roots):
    if not sid:
        return None
    for root in roots:
        for d, _, files in os.walk(root):
            if sid + ".jsonl" in files:
                return os.path.join(d, sid + ".jsonl")
    return None


def summarize(rows):
    s = {}
    for f in FIELDS:
        xs = [r[f] for r in rows if r.get(f) is not None]
        if f in ("red_before_green", "verify_before_claim"):
            t = sum(1 for x in xs if x is True)
            s[f] = {"n": len(xs), "true": t, "rate": (t / len(xs)) if xs else None}
        elif f == "denial_recovery":
            s[f] = {"n": len(xs), "mean": (sum(xs) / len(xs)) if xs else None}
        else:
            s[f] = {"n": len(xs), "sum": sum(xs) if xs else None}
    return s


def rescore(run_dirs, roots):
    rows = []
    for d in run_dirs:
        with open(os.path.join(d, "runs.jsonl"), encoding="utf-8") as fh:
            tasks = [json.loads(l) for l in fh if l.strip()]
        for t in tasks:
            rep = t.get("rep") or 1
            stem = t["task"] + (".r%d" % rep if rep > 1 else "")
            sid = None
            try:
                with open(os.path.join(d, stem + ".result.json"), encoding="utf-8") as fh:
                    sid = json.load(fh).get("session_id")
            except (OSError, ValueError, AttributeError):
                pass
            tr = find_transcript(sid, roots)
            row = {"run": os.path.basename(os.path.normpath(d)), "task": t["task"], "rep": rep,
                   "session_id": sid, "transcript": tr}
            rp = os.path.join(d, stem + ".report.md")
            row.update(score(tr, rp if os.path.isfile(rp) else None))
            rows.append(row)
    return {"rows": rows, "summary": summarize(rows)}


def _fmt(x):
    if x is None:
        return "–"
    if isinstance(x, float):
        return "%.3f" % x
    return str(x).lower() if isinstance(x, bool) else str(x)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="trajectory.py", description="trajectory scoring (HIMMEL-4651)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("transcript")
    s.add_argument("--report")
    s.add_argument("--denials", action="store_true")
    r = sub.add_parser("rescore")
    r.add_argument("run_dirs", nargs="+")
    r.add_argument("--transcripts", action="append")
    r.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.cmd == "score":
        print(json.dumps(score(args.transcript, args.report, args.denials)))
        return 0
    roots = args.transcripts or [os.path.expanduser("~/.claude/projects"),
                                 os.path.expanduser("~/.claude-openrouter/projects")]
    try:
        out = rescore(args.run_dirs, roots)
    except (OSError, ValueError, KeyError) as e:
        print("trajectory: cannot rescore: %s" % e, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(out, indent=1))
        return 0
    print("| run | task | rep | red_before_green | denial_recovery | identical_denied_retries | verify_before_claim |")
    print("|---|---|---|---|---|---|---|")
    for row in out["rows"]:
        if row["transcript"] is None:
            print("| %s | %s | %s | no transcript | | | |" % (row["run"], row["task"], row["rep"]))
            continue
        print("| %s | %s | %s | %s |" % (row["run"], row["task"], row["rep"],
                                         " | ".join(_fmt(row[f]) for f in FIELDS)))
    print()
    print("| field | n | value |")
    print("|---|---|---|")
    for f, v in out["summary"].items():
        val = ("%d/%d true (%s)" % (v["true"], v["n"], _fmt(v["rate"])) if "rate" in v
               else "mean %s" % _fmt(v["mean"]) if "mean" in v else "sum %s" % _fmt(v["sum"]))
        print("| %s | %d | %s |" % (f, v["n"], val))
    return 0


if __name__ == "__main__":
    sys.exit(main())
