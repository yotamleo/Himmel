#!/usr/bin/env python3
"""scripts/eval/leg-digest/leg_ledger.py - the leg ledgers writer (HIMMEL-4670 P2).

Turns one P1 digest (leg-digest.ts) into two ledger writes, then a marker:
  1. one leg-failures row per digest failures row (registered in
     scripts/observability/ledgers.json as `leg-failures`);
  2. one eval-runs row with eval "leg-trajectory" and meta.observational
     true (spec 3.1: a series, never a regression verdict);
  3. the digest itself at <state-dir>/<session>.json, LAST, as the commit marker.

  Path: $HIMMEL_LEG_FAILURES_LEDGER, else ~/.himmel/leg-failures.jsonl.

LEG-FAILURES ROW (v 1) -- closed-list categories only, never journal text:
  v, ts, host, source, kind "leg-failure"       registry envelope
  session     the leg's session uuid
  leg, console, ticket, pr                      who the row belongs to, or null
  agent       {id, role, kind, model} from the digest
  class       "<failure>/<sub>", the digest's closed-list class
  failure     denied | suite | blocked | error | run_error | traj
  count, identical_retry, recovered, first_ts, last_ts
  tool_call_ids  at most five tool-call ids
  final_red   suite rows only
Unknown keys are refused, so a field carrying free text cannot ride in.

IDEMPOTENCE (spec 5.3), all under a per-session flock at <state-dir>/<session>.lock:
  marker present with status ok          -> append nothing
  marker non-ok, new digest non-ok       -> append nothing
  an ok digest over a non-ok marker replaces the session's leg-failures rows (a partial
  digest's stale classes and counts go, other sessions' rows stay; HIMMEL-4701);
  otherwise append only the leg-failures rows missing by (session, agent.id, class)
  and the eval-runs row unless an ok one, or one of a non-ok status beside a
  non-ok digest, is already there; then rewrite the marker.

  leg_ledger.py record --digest F [--leg N --ticket K --console C --pr N --doc D --lane L]
                       [--digest-error timeout|crash|no-journal|bad-json|too-big]
                       [--failures-ledger P] [--eval-ledger P] [--state-dir D]
  leg_ledger.py backfill --since YYYY-MM-DD [--projects D] [--denials-ledger P] [--live-minutes N]
                       [--failures-ledger P] [--eval-ledger P] [--state-dir D]
  leg_ledger.py validate <leg-failures ledger>

backfill digests every leg-titled main journal under --projects whose first
timestamp is on or after --since, through `bun leg-digest.ts`. It reads the
journals only, and refuses one whose cwd sits under a salus root (spec 6.1).
It skips a journal whose last timestamp is under --live-minutes (default 30) old:
an ok digest of a still-live session would write the final marker and freeze the
leg before its remaining failures land (HIMMEL-4699).
"""

import argparse
import fcntl
import glob
import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

SOURCE = "scripts/eval/leg-digest/leg_ledger.py"
LEDGER_ENV = "HIMMEL_LEG_FAILURES_LEDGER"
EVAL_ID = "leg-trajectory"
METRICS = ("tool_calls", "subagents", "turns", "fail_denied", "fail_suite", "fail_blocked", "fail_error",
           "run_errors", "interrupts", "red_before_green", "denial_recovery", "identical_denied_retries",
           "verify_before_claim")
FAILURES = ("denied", "suite", "blocked", "error", "run_error", "traj")
KEYS = ("v", "ts", "host", "source", "kind", "session", "leg", "console", "ticket", "pr", "agent", "class",
        "failure", "count", "identical_retry", "recovered", "first_ts", "last_ts", "tool_call_ids")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SUB = re.compile(r"^[A-Za-z0-9._:+-]{1,80}$")
NAME = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
LEG = re.compile(r"^N\d+[a-z]?$")
TICKET = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
CONSOLE = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
MODEL = re.compile(r"^(claude|gpt|gemini|glm|codex|o\d)[a-z0-9.\-\[\]]{0,60}$", re.I)
TITLE = re.compile(r"^([A-Z][A-Z0-9]+-\d+)-(N\d+[a-z]?)-")
DIGEST_TIMEOUT = 60
LIVE_MINUTES = 30
DIGEST_ERRORS = ("timeout", "crash", "no-journal", "bad-json", "too-big")


def ledger_path(path=None):
    return path or os.environ.get(LEDGER_ENV) or os.path.expanduser("~/.himmel/leg-failures.jsonl")


def default_state_dir():
    return os.path.expanduser("~/.himmel/state/leg-digest")


def _int(x, lo):
    return isinstance(x, int) and not isinstance(x, bool) and x >= lo


def _opt(x, rx):
    return x is None or (isinstance(x, str) and bool(rx.match(x)))


def validate(row):
    """List of problems; empty = a valid v1 leg-failures row."""
    if not isinstance(row, dict):
        return ["row is not an object"]
    extra = sorted(set(row) - set(KEYS) - {"final_red"})
    p = ["unknown key %s" % k for k in extra] + ["missing %s" % k for k in KEYS if k not in row]
    if p:
        return p
    if row["v"] != 1:
        p.append("v must be 1")
    if row["kind"] != "leg-failure":
        p.append("kind must be leg-failure")
    for k in ("ts", "host", "source"):
        if not isinstance(row[k], str) or not row[k]:
            p.append("%s must be a non-empty string" % k)
    if not isinstance(row["session"], str) or not UUID.match(row["session"]):
        p.append("session must be a uuid")
    if not _opt(row["leg"], LEG):
        p.append("leg must be N<digits> or null")
    if not _opt(row["ticket"], TICKET):
        p.append("ticket must be a ticket key or null")
    if not _opt(row["console"], CONSOLE):
        p.append("console must be a session name or null")
    if row["pr"] is not None and not _int(row["pr"], 1):
        p.append("pr must be a positive integer or null")
    a = row["agent"]
    if not isinstance(a, dict) or sorted(a) != ["id", "kind", "model", "role"]:
        p.append("agent must be exactly {id, role, kind, model}")
    elif not (_opt(a["id"], NAME) and a["id"] and _opt(a["role"], NAME) and a["role"]
              and _opt(a["kind"], NAME) and _opt(a["model"], MODEL)):
        p.append("agent fields must be closed-list names")
    if row["failure"] not in FAILURES:
        p.append("failure must be one of %s" % ", ".join(FAILURES))
    c = row["class"]
    if not isinstance(c, str) or "/" not in c:
        p.append("class must be <failure>/<sub>")
    else:
        head, _, sub = c.partition("/")
        if head != row["failure"]:
            p.append("class prefix must equal failure")
        if not SUB.match(sub):
            p.append("class sub must be a closed-list name")
    if not _int(row["count"], 1):
        p.append("count must be a positive integer")
    if row["identical_retry"] is not None and not _int(row["identical_retry"], 0):
        p.append("identical_retry must be a non-negative integer or null")
    if row["recovered"] is not None and not isinstance(row["recovered"], bool):
        p.append("recovered must be a boolean or null")
    for k in ("first_ts", "last_ts"):
        if row[k] is not None and not _int(row[k], 0):
            p.append("%s must be epoch milliseconds or null" % k)
    ids = row["tool_call_ids"]
    if not isinstance(ids, list) or len(ids) > 5 or not all(isinstance(i, str) and NAME.match(i) for i in ids):
        p.append("tool_call_ids must be at most five ids")
    if "final_red" in row and (row["failure"] != "suite" or not isinstance(row["final_red"], bool)):
        p.append("final_red is a boolean on suite rows only")
    return p


def validate_file(path):
    bad = 0
    try:
        fh = open(path, encoding="utf-8")
    except OSError as e:
        print("leg-failures: cannot read %s: %s" % (path, e), file=sys.stderr)
        return 1
    with fh:
        for nr, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                problems = validate(json.loads(line))
            except json.JSONDecodeError:
                problems = ["not JSON"]
            if problems:
                bad += 1
                print("%s:%d: %s" % (path, nr, "; ".join(problems)), file=sys.stderr)
    print("leg-failures: %s %s" % (path, "valid" if not bad else "%d bad row(s)" % bad))
    return 1 if bad else 0


def _ledger_lock(path, mode):
    """Held by every writer of the ledger: appends share it, a rewrite owns it, so a rewrite
    never drops a row another session appended meanwhile."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    lk = open(path + ".lock", "w")
    fcntl.flock(lk, mode)
    return lk


def _dump(r):
    return (json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _append(path, rows):
    if not rows:
        return
    with _ledger_lock(path, fcntl.LOCK_SH):
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            for r in rows:
                line = _dump(r)
                # One O_APPEND write per row, so concurrent writers never interleave a line.
                if os.write(fd, line) != len(line):
                    raise OSError("short write to %s; the last row may be torn" % path)
        finally:
            os.close(fd)


def _replace_session(path, session, rows):
    """Drop every row of this session from the ledger, then add rows, atomically."""
    with _ledger_lock(path, fcntl.LOCK_EX):
        tmp = path + ".tmp"
        with open(tmp, "wb") as out:
            try:
                fh = open(path, "rb")
            except FileNotFoundError:
                fh = None
            if fh:
                with fh:
                    for line in fh:
                        if session.encode() in line:
                            try:
                                r = json.loads(line)
                            except ValueError:
                                r = None
                            if isinstance(r, dict) and r.get("session") == session:
                                continue
                        out.write(line)
            for r in rows:
                out.write(_dump(r))
        os.replace(tmp, path)


def failure_keys(path, session):
    """(agent.id, class) of the rows this session already has."""
    keys = set()
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        return keys
    with fh:
        for line in fh:
            if session not in line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(r, dict) and r.get("session") == session and isinstance(r.get("agent"), dict):
                keys.add((r["agent"].get("id"), r.get("class")))
    return keys


def eval_statuses(path, session):
    rows, _, _ = eval_runs.scan_rows(path)
    return [r["status"] for r in rows if r["eval"] == EVAL_ID and r["run_id"] == session]


def _metrics(digest):
    m = digest.get("metrics") if isinstance(digest.get("metrics"), dict) else {}
    out = {}
    for k in METRICS:
        v = m.get(k)
        out[k] = (1 if v else 0) if isinstance(v, bool) else v if eval_runs._num(v) else None
    return out


def build_rows(digest, who):
    """(leg-failures rows, eval-runs row) for one digest; raises ValueError."""
    session = digest.get("session")
    if not isinstance(session, str) or not UUID.match(session):
        raise ValueError("digest session is not a uuid: the journal must be named <uuid>.jsonl")
    status = digest.get("status")
    if status not in eval_runs.STATUSES:
        raise ValueError("digest status %r is not one of %s" % (status, ", ".join(eval_runs.STATUSES)))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    host = socket.gethostname()
    frows = []
    for f in digest.get("failures") or []:
        r = {"v": 1, "ts": now, "host": host, "source": SOURCE, "kind": "leg-failure", "session": session,
             "leg": who["leg"], "console": who["console"], "ticket": who["ticket"], "pr": who["pr"],
             "agent": f.get("agent"), "class": f.get("class"), "failure": f.get("failure"),
             "count": f.get("count"), "identical_retry": f.get("identical_retry"),
             "recovered": f.get("recovered"), "first_ts": f.get("first_ts"), "last_ts": f.get("last_ts"),
             "tool_call_ids": f.get("tool_call_ids")}
        if "final_red" in f:
            r["final_red"] = f["final_red"]
        problems = validate(r)
        if problems:
            raise ValueError("leg-failures row %s: %s" % (f.get("class"), "; ".join(problems)))
        frows.append(r)
    model = digest.get("model") if isinstance(digest.get("model"), str) else None
    config = {"digest_v": digest.get("digest_v"), "mapper_v": digest.get("mapper_v"),
              "trajectory_v": digest.get("trajectory_v"), "lane": who["lane"], "model": model}
    meta = {"leg": who["leg"], "doc": who["doc"], "ticket": who["ticket"], "pr": who["pr"],
            "console": who["console"], "observational": True}
    if who.get("backfill"):
        meta["backfill"] = True
    if who.get("digest_error"):
        meta["digest_error"] = who["digest_error"]
    m = _metrics(digest)
    erow = eval_runs.make_row(EVAL_ID, SOURCE, config, m, n=m["turns"] if _int(m["turns"], 0) else None,
                              model=model, lane=who["lane"], status=status, run_id=session,
                              artifact=os.path.join(who["state_dir"], session + ".json"), meta=meta,
                              repo=HERE)
    problems = eval_runs.validate(erow)
    if problems:
        raise ValueError("eval-runs row: %s" % "; ".join(problems))
    return frows, erow


def record(digest, who, failures_ledger, eval_ledger):
    """Write one digest under its session lock; returns (failures added, eval rows added)."""
    frows, erow = build_rows(digest, who)
    session, status, state = erow["run_id"], erow["status"], who["state_dir"]
    os.makedirs(state, exist_ok=True)
    marker = os.path.join(state, session + ".json")
    with open(os.path.join(state, session + ".lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            with open(marker, encoding="utf-8") as fh:
                prev = json.load(fh).get("status")
        except (OSError, ValueError, AttributeError):
            prev = None
        if prev == "ok" or (prev is not None and status != "ok"):
            return 0, 0
        if status == "ok" and prev is not None:
            # A non-ok digest left rows the ok one may no longer have, or with other counts:
            # replace the session's rows so readers see only the final digest (HIMMEL-4701).
            add = frows
            _replace_session(failures_ledger, session, add)
        else:
            have = failure_keys(failures_ledger, session)
            add = [r for r in frows if (r["agent"]["id"], r["class"]) not in have]
            _append(failures_ledger, add)
        seen = eval_statuses(eval_ledger, session)
        e = 0
        if not ("ok" in seen or (seen and status != "ok")):
            eval_runs.append_row(erow, eval_ledger)
            e = 1
        tmp = marker + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(digest, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, marker)
        return len(add), e


# --- backfill ------------------------------------------------------------------

def _roots(name):
    try:
        with open(os.path.expanduser("~/.config/claude-glm/" + name), encoding="utf-8") as fh:
            return [os.path.realpath(os.path.expanduser(l.strip())) for l in fh
                    if l.strip() and not l.lstrip().startswith("#")]
    except FileNotFoundError:
        return []  # absent = no listed roots; any other read error raises (fail closed)


def salus_rooted(cwd, roots):
    """True when cwd has a .salus marker on any ancestor or lies under a listed PHI root,
    or when there is no cwd to test (fail closed).
    ponytail: a minimal re-implementation of graphify-fence.sh's salus test (a hook, not
    sourceable), upgrade path: share one primitive when a second reader needs it."""
    if not cwd:
        return True
    p = os.path.realpath(cwd)
    for r in roots:
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return True
    while True:
        if os.path.exists(os.path.join(p, ".salus")):
            return True
        up = os.path.dirname(p)
        if up == p:
            return False
        p = up


def journal_head(path, limit=40):
    """(title, first timestamp, cwd): the LAST title in the whole journal (a rename lands late),
    the first timestamp and cwd from its first lines. Streams; never holds the file."""
    title = ts = cwd = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= limit and "customTitle" not in line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(r, dict):
                continue
            if isinstance(r.get("customTitle"), str):
                title = r["customTitle"]
            if i < limit and ts is None and isinstance(r.get("timestamp"), str):
                ts = r["timestamp"]
            if i < limit and cwd is None and isinstance(r.get("cwd"), str):
                cwd = r["cwd"]
    return title, ts, cwd


def journal_last_ts(path, tail=65536):
    """Epoch seconds of the journal's last timestamped entry, else its mtime."""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        fh.seek(max(0, fh.tell() - tail))
        lines = fh.read().decode("utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        try:
            ts = json.loads(line)["timestamp"]
            return datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        except (ValueError, TypeError, KeyError):
            continue
    return os.path.getmtime(path)


def run_digest(journal, session, denials):
    cmd = ["bun", os.path.join(HERE, "leg-digest.ts"), "--transcript", journal]
    if denials:
        cmd += ["--denials-ledger", denials]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=DIGEST_TIMEOUT, check=False)
        if r.returncode == 0:
            return json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return {"digest_v": 1, "mapper_v": 1, "trajectory_v": None, "session": session, "status": "inconclusive",
            "model": None, "metrics": {}, "failures": []}


def backfill(a):
    since = datetime.strptime(a.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    roots = _roots("phi-roots") + _roots("egress-denylist")
    live_cut = datetime.now(timezone.utc).timestamp() - a.live_minutes * 60
    n = legs = salus = done = live = fa = ea = 0
    for j in sorted(glob.glob(os.path.join(a.projects, "*", "*.jsonl"))):
        session = os.path.basename(j)[:-len(".jsonl")]
        if not UUID.match(session) or os.path.getmtime(j) < since.timestamp():
            continue
        title, ts, cwd = journal_head(j)
        try:
            when = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
        if when < since:
            continue
        n += 1
        m = TITLE.match(title or "")
        if not m:
            continue
        if salus_rooted(cwd, roots):
            salus += 1
            continue
        legs += 1
        try:
            with open(os.path.join(a.state_dir, session + ".json"), encoding="utf-8") as fh:
                if json.load(fh).get("status") == "ok":
                    done += 1
                    continue
        except (OSError, ValueError, AttributeError):
            pass
        # ponytail: recency stands in for "still running" (a leg idle past the window
        # still freezes), upgrade path: an end-of-session signal in the journal.
        if journal_last_ts(j) > live_cut:
            live += 1
            continue
        who = {"leg": m.group(2), "ticket": m.group(1), "console": None, "pr": None, "doc": None,
               "lane": None, "state_dir": a.state_dir, "backfill": True}
        try:
            f, e = record(run_digest(j, session, a.denials_ledger), who, a.failures_ledger, a.eval_ledger)
        except ValueError as err:
            print("backfill: %s skipped: %s" % (session, err), file=sys.stderr)
            continue
        fa += f
        ea += e
    print("backfill: journals=%d legs=%d salus=%d already=%d failures+=%d eval+=%d live=%d"
          % (n, legs, salus, done, fa, ea, live))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="leg_ledger.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("record", "backfill"):
        s = sub.add_parser(name)
        s.add_argument("--failures-ledger")
        s.add_argument("--eval-ledger")
        s.add_argument("--state-dir", default=default_state_dir())
    r = sub.choices["record"]
    r.add_argument("--digest", required=True)
    for k in ("leg", "ticket", "console", "doc", "lane"):
        r.add_argument("--" + k)
    r.add_argument("--pr", type=int)
    r.add_argument("--digest-error", choices=DIGEST_ERRORS)
    b = sub.choices["backfill"]
    b.add_argument("--since", required=True)
    b.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    b.add_argument("--denials-ledger")
    b.add_argument("--live-minutes", type=int, default=LIVE_MINUTES)
    v = sub.add_parser("validate")
    v.add_argument("ledger")
    a = ap.parse_args(argv)
    if a.cmd == "validate":
        return validate_file(a.ledger)
    a.failures_ledger = ledger_path(a.failures_ledger)
    a.state_dir = os.path.abspath(a.state_dir)
    if a.cmd == "backfill":
        try:
            datetime.strptime(a.since, "%Y-%m-%d")
        except ValueError:
            ap.error("--since must be YYYY-MM-DD")
        return backfill(a)
    try:
        with open(a.digest, encoding="utf-8") as fh:
            digest = json.load(fh)
        who = {"leg": a.leg, "ticket": a.ticket, "console": a.console, "pr": a.pr, "doc": a.doc,
               "lane": a.lane, "state_dir": a.state_dir, "digest_error": a.digest_error}
        f, e = record(digest, who, a.failures_ledger, a.eval_ledger)
    except (OSError, ValueError) as err:
        print("leg-ledger: %s" % err, file=sys.stderr)
        return 1
    print("leg-ledger: %s failures+=%d eval+=%d" % (digest.get("session"), f, e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
