#!/usr/bin/env python3
"""scripts/eval/leg-digest/failure_review.py - the daily failure review (HIMMEL-4713, P5b of HIMMEL-4670).

One LLM-free pass over the leg-failures ledger: run the failure router, summarise the last 24 h,
write the digest, tell the operator in one Telegram line when something happened.

  failure_review.py [--live] [--ledger P] [--state P] [--log P] [--inbox P] [--table P] [--now ISO]
                    [--jira-bin P] [--out-dir D] [--vault V] [--notify-cmd C]

ROUTING: failure_router.py route, whose own window (14 d, >= threshold distinct legs) decides
recurrence. DRY-RUN BY DEFAULT: the router reads only, files nothing and calls no Jira. --live
routes for real (tickets, comments, memory-inbox candidates); the cadence passes it only when it
was armed with --live (judge note on PR #2020: burn in on dry-run before live filing).

DIGEST (the section "## Failure review"), over the ledger rows of the last 24 h:
  - top classes with their rows and legs, each (new) when the ledger has no earlier row of it,
    else (recurring);
  - what was routed (or would be, on a dry run), what was capped, what the router skipped;
  - the trajectory signals, minus traj/claim-unverified and traj/red-before-green (unreliable,
    HIMMEL-4698), which are left out of every count.
  Written to <out-dir>/failure-review-<local date>.md (the morning report reads it) and, with
  --vault, upserted into <vault>/50-Journal/Daily/<local date>.md.
  out-dir: --out-dir, else $HIMMEL_FAILURE_REVIEW_DIR, else ~/.himmel/state/failure-review.

TELEGRAM: one line through the notifier (--notify-cmd, else $FAILURE_REVIEW_NOTIFY_CMD, else
scripts/luna/vault-stall-alert.sh, the existing operator DM path) when a live run routed something
or a class appeared that the ledger never saw before. A quiet day sends nothing. A dry run's
would-be routing does not send: the router keeps no state on a dry run, so it would repeat daily.
DELIVERY (HIMMEL-4790) is kept in <state file>.notify.json beside the router state (--state, else
$HIMMEL_FAILURE_ROUTES_STATE, else ~/.himmel/state/failure-routes.json), under flock, temp then
rename: {pending, sent}. The router state advances before the send, so the line is saved in pending
as soon as the router returns, before the digest is written, and the next run sends it again until
one is delivered. The name appends to the whole state filename, so states differing only in extension
never share it (HIMMEL-4798); an older <stem>.notify.json is renamed to it on first use. A delivered new
class is recorded in sent and not named again for 24 h; a failed send records nothing there. An
unreadable state file is kept aside as <file>.unreadable.<unique> and a fresh one started.

Exit 0 on a written digest, 1 when the router failed (the digest still says so), 2 on bad input,
3 when the Telegram line was due but not delivered (the digest is still written; the cadence alerts).
"""

import argparse
import contextlib
import fcntl
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import failure_router  # noqa: E402

HEADING = "## Failure review"
EXCLUDED = {"traj/claim-unverified": "verify_before_claim", "traj/red-before-green": "red_before_green"}
ROUTED = ("filed", "commented", "recurred-after-done", "would-file", "would-comment")
CAPPED = ("capped", "would-cap")
LIVE_LINE = re.compile(r"^failure-router: (\S+) legs=(\d+) (\S+)(?: (\S+))?$")
TOP = 10
NOTIFIER = os.path.join(HERE, "..", "..", "luna", "vault-stall-alert.sh")


def leg_key(leg):
    m = re.match(r"^N(\d+)", leg)
    return (int(m.group(1)) if m else 0, leg)


def run_router(a):
    """(rc, decisions, inbox classes). Decisions are dicts {class, legs, decision, ticket}."""
    argv = ["route", "--now", failure_router.iso(a.now)]
    for flag, val in (("--ledger", a.ledger), ("--state", a.state), ("--log", a.log), ("--inbox", a.inbox),
                      ("--table", a.table), ("--jira-bin", a.jira_bin)):
        if val:
            argv += [flag, val]
    if not a.live:
        argv.append("--dry-run")
    inbox = a.inbox or os.environ.get(failure_router.INBOX_ENV)
    before = inbox_lines(inbox)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = failure_router.main(argv)
    decisions, boxed = [], []
    for line in out.getvalue().splitlines():
        if a.live:
            m = LIVE_LINE.match(line)
            if m:
                decisions.append({"class": m.group(1), "legs": int(m.group(2)), "decision": m.group(3),
                                  "ticket": m.group(4)})
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        decisions.append(d)
        if d.get("inbox"):
            boxed.append(d["class"])
    if a.live:
        boxed = [ln.split(" ")[2] for ln in inbox_lines(inbox)[len(before):] if len(ln.split(" ")) > 2]
    return rc, decisions, boxed


def inbox_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.startswith("- ")]
    except (OSError, TypeError):
        return []


def build(a, rows, seen_before, rc, decisions, boxed):
    """(section text, new classes)."""
    mode = "live" if a.live else "dry-run"
    since = a.now - timedelta(hours=24)
    out = [HEADING, "",
           "- window: %s to %s, mode: %s" % (failure_router.iso(since), failure_router.iso(a.now), mode)]
    fails = {c: r for c, r in rows.items() if c not in EXCLUDED}
    new = sorted(c for c in fails if not c.startswith("traj/") and c not in seen_before)
    n = sum(len(r) for r in fails.values())
    if not n:
        out.append("- no failures in the last 24 h")
    else:
        legs = {r["leg"] for rs in fails.values() for r in rs if r.get("leg")}
        out.append("- failures: %d rows, %d classes, %d legs" % (n, len(fails), len(legs)))
    if rc != 0:
        out.append("- router: failed (rc %d), see the cadence log" % rc)

    classes = sorted((c for c in fails if not c.startswith("traj/")), key=lambda c: (-len(fails[c]), c))
    out += ["", "### Top classes", ""]
    for c in classes[:TOP]:
        legs = sorted({r["leg"] for r in fails[c] if r.get("leg")}, key=leg_key)
        out.append("- %s: %d rows, legs %s (%s)" % (c, len(fails[c]), ", ".join(legs) or "none",
                                                   "new" if c in new else "recurring"))
    if len(classes) > TOP:
        out.append("- and %d more classes" % (len(classes) - TOP))
    if not classes:
        out.append("- none")

    out += ["", "### Routing (%s)" % mode, ""]
    routed = [d for d in decisions if d["decision"] in ROUTED]
    capped = [d for d in decisions if d["decision"] in CAPPED]
    skipped = [d for d in decisions if d["decision"].startswith("skipped:")]
    if routed:
        out += ["- %s %s%s (legs %d)" % (d["decision"], d["class"], " " + d["ticket"] if d.get("ticket") else "",
                                         d["legs"]) for d in routed]
    else:
        out.append("- routed: none")
    if boxed:
        out.append("- memory-inbox candidates: %s" % ", ".join(boxed))
    if capped:
        out.append("- capped: the daily create cap was hit; waiting: %s" % ", ".join(d["class"] for d in capped))
    else:
        out.append("- capped: none")
    if skipped:
        out.append("- skipped: %s" % ", ".join("%s (%s)" % (d["class"], d["decision"][8:]) for d in skipped))

    out += ["", "### Trajectory signals", ""]
    traj = sorted(c for c in fails if c.startswith("traj/"))
    out += ["- %s: %d" % (c, len(fails[c])) for c in traj] or ["- none"]
    out.append("- excluded until HIMMEL-4698: %s" % ", ".join(sorted(EXCLUDED.values())))
    return "\n".join(out) + "\n", new, n, len(fails), routed, boxed


def state_file(a):
    return os.path.abspath(a.state or os.environ.get(failure_router.STATE_ENV) or os.path.expanduser(
        "~/.himmel/state/failure-routes.json"))


def notify_path(a):
    return state_file(a) + ".notify.json"


def legacy_notify_path(a):
    # HIMMEL-4790 named it after the state file's stem, so routes.json and routes.state shared one.
    return os.path.splitext(state_file(a))[0] + ".notify.json"


def load_notify(path):
    """(state, ok). A missing file is an empty state; anything unreadable is not ok."""
    if not os.path.exists(path):
        return {"v": 1, "pending": [], "sent": {}}, True
    try:
        with open(path, encoding="utf-8") as fh:
            s = json.load(fh)
        if not (isinstance(s, dict) and isinstance(s.get("pending"), list) and isinstance(s.get("sent"), dict)
                and all(isinstance(p, str) for p in s["pending"])):
            return None, False
        return s, True
    except (OSError, ValueError):
        return None, False


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".failure-review.", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def upsert(note, section):
    """Replace the note's "## Failure review" section (up to the next "## " heading), else append it."""
    lines = note.split("\n")
    start = next((i for i, ln in enumerate(lines) if ln.rstrip() == HEADING), None)
    if start is None:
        return note.rstrip("\n") + "\n\n" + section
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    tail = "\n".join(lines[end:])
    return "\n".join(lines[:start]) + "\n" + section + ("\n" + tail if tail else "")


def daily_note(vault, day, section):
    path = os.path.join(vault, "50-Journal", "Daily", "%s.md" % day)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            note = fh.read()
    else:
        try:
            with open(os.path.join(vault, "_Templates", "Daily-Note.md"), encoding="utf-8") as fh:
                note = fh.read().replace("{{date}}", day)
        except OSError:
            note = "---\ndate: %s\ntype: daily\n---\n\n# %s\n" % (day, day)
    write_atomic(path, upsert(note, section))
    return path


def write_outputs(a, day, section):
    digest = os.path.join(a.out_dir, "failure-review-%s.md" % day)
    write_atomic(digest, section)
    print("failure-review: wrote %s" % digest)
    if a.vault:
        print("failure-review: daily note %s" % daily_note(a.vault, day, section))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="failure_review.py", description=__doc__.split("\n")[0])
    ap.add_argument("--live", action="store_true")
    for f in ("--ledger", "--state", "--log", "--inbox", "--table", "--now", "--jira-bin", "--vault"):
        ap.add_argument(f)
    ap.add_argument("--out-dir", default=os.environ.get("HIMMEL_FAILURE_REVIEW_DIR")
                    or os.path.expanduser("~/.himmel/state/failure-review"))
    ap.add_argument("--notify-cmd", default=os.environ.get("FAILURE_REVIEW_NOTIFY_CMD") or NOTIFIER)
    a = ap.parse_args(argv)
    try:
        a.now = failure_router.now_utc(a.now)
    except ValueError:
        print("failure-review: --now %r is not an ISO time" % a.now, file=sys.stderr)
        return 2
    day = a.now.astimezone().strftime("%Y-%m-%d")
    ledger = failure_router.leg_ledger.ledger_path(a.ledger)
    since = a.now - timedelta(hours=24)
    try:
        rows = failure_router.read_ledger(ledger, since, a.now)
        older = failure_router.read_ledger(ledger, datetime(1970, 1, 1, tzinfo=timezone.utc),
                                           since - timedelta(microseconds=1))
    except OSError as e:
        print("failure-review: cannot read the ledger: %s" % e, file=sys.stderr)
        return 2
    a.ledger = ledger
    rc, decisions, boxed = run_router(a)
    section, new, n, k, routed, boxed = build(a, rows, set(older), rc, decisions, boxed)
    npath = notify_path(a)
    os.makedirs(os.path.dirname(npath), exist_ok=True)
    with open(npath + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # ponytail: one-time carry of the HIMMEL-4790 stem-named file so its pending line is not dropped; two
        # states that shared it give it to whichever runs first. Drop once no station can still hold one
        # (HIMMEL-4798, a few weeks after merge).
        legacy = legacy_notify_path(a)
        if not os.path.exists(npath) and os.path.exists(legacy):
            os.replace(legacy, npath)
        ns, ns_ok = load_notify(npath)
        if not ns_ok:
            # Kept aside under a unique name, never overwritten; a fresh state keeps this run's undelivered lines.
            fd, kept = tempfile.mkstemp(prefix=os.path.basename(npath) + ".unreadable.", dir=os.path.dirname(npath))
            os.close(fd)
            os.replace(npath, kept)
            print("failure-review: %s is unreadable; kept as %s" % (npath, kept), file=sys.stderr)
            ns = {"v": 1, "pending": [], "sent": {}}
        sent = {}
        for c, t in ns["sent"].items():
            try:
                if failure_router.now_utc(t) >= since:
                    sent[c] = t
            except (AttributeError, TypeError, ValueError):
                pass
        # What this run has to say: its live routing, and the new classes not yet delivered in the window.
        done = (["%s %s%s" % (d["decision"], d["class"], " " + d["ticket"] if d.get("ticket") else "")
                 for d in routed] + ["inbox %s" % c for c in boxed]) if a.live else []
        fresh = [c for c in new if c not in sent]
        pending = [p for p in ns["pending"] if p not in done and p not in ["new %s" % c for c in fresh]]
        line = None
        if done or fresh or pending:
            line = "failure review %s (%s): %d failures in %d classes; %s %d%s%s" % (
                day, "live" if a.live else "dry-run", n, k, "routed" if a.live else "would route",
                len(routed) if a.live else len([d for d in decisions if d["decision"] in ROUTED]),
                "; undelivered earlier: %s" % ", ".join(pending) if pending else "",
                "; new: %s" % ", ".join(fresh) if fresh else "")
            # Saved as soon as the router returns: a run that dies before or during the send leaves its line.
            ns["pending"] = pending + done + ["new %s" % c for c in fresh]
            ns["sent"] = sent
            write_atomic(npath, json.dumps(ns, indent=1, sort_keys=True) + "\n")
        write_outputs(a, day, section)
        if line:
            try:
                ok = subprocess.run([a.notify_cmd, line], capture_output=True, timeout=60).returncode == 0
            except (OSError, subprocess.SubprocessError):
                ok = False
            print("failure-review: telegram %s" % ("sent" if ok else "NOT delivered"),
                  file=sys.stdout if ok else sys.stderr)
            if ok:
                ns["pending"] = []
                for c in fresh + [p[4:] for p in pending if p.startswith("new ")]:
                    sent[c] = failure_router.iso(a.now)
                write_atomic(npath, json.dumps(ns, indent=1, sort_keys=True) + "\n")
            if rc == 0 and not ok:
                return 3
    return 1 if rc != 0 else 0


if __name__ == "__main__":
    sys.exit(main())
