#!/usr/bin/env python3
"""scripts/eval/leg-digest/failure_router.py - the failure router (HIMMEL-4670 P5).

Reads the leg-failures ledger (leg_ledger.py writes it), finds the class keys that
recur across distinct legs, and routes each through failure-routes.table.json
(spec 4.2, as data): a Jira ticket on recurrence, a comment on a later one, a
memory-inbox candidate for classifier denials. Deterministic, local, no model.

  failure_router.py route [--dry-run] [--ledger P] [--state P] [--log P] [--inbox P]
                          [--table P] [--now ISO] [--jira-bin P]
  failure_router.py check-body <file>     the body alphabet check, exit 1 on a refusal

RECURRENCE (spec 4.1): a class recurs at the table row's threshold in DISTINCT legs
within window_days. A leg label is counted with a trailing [a-z] stripped, so a
resume chain (N100 + N100b) is one leg; a row with no leg is not counted. Agent-
behaviour classes count only rows whose agent.role is leg or whose agent.id is
main; a row marked any_role (suite/*) counts every role. Rows that fail the
leg_ledger.py validator are ignored.

DECISIONS, one decision-log line each (P4 contract): filed | commented | capped |
recurred-after-done | skipped:<why>. A class whose window legs were all acted on
before makes no decision; a decision equal to the class's last one on
the same legs writes no second line. Never-routed and signal-only rows (the
traj/red-before-green and traj/claim-unverified classes among them) decide nothing.

  log    $HIMMEL_FAILURE_ROUTES_LOG, else ~/.himmel/state/failure-routes.log.jsonl
         {ts, class, legs, decision, ticket}, one O_APPEND write per line
  state  $HIMMEL_FAILURE_ROUTES_STATE, else ~/.himmel/state/failure-routes.json
         class -> ticket and counts, plus the day's create count; flock, temp then rename
  inbox  $HIMMEL_FAILURE_INBOX, else --inbox (<bucket>/failure-loop/memory-inbox.md);
         one `- ` line per class ever, under flock; none when neither is set

JIRA (the himmel CLI by absolute path; --jira-bin replaces it, as the tests' stub):
a --jql label search over every status before any create, one Task per class with
labels failure-loop + fl-<slug> and no fixVersion, at most one comment a day per
ticket, at most daily_cap creates a UTC day. A Done ticket is never reopened or
re-filed. FAIL CLOSED: an unreadable state file, a search error, a CLI error or a
body outside the alphabet files nothing and logs skipped:<why>.

--dry-run reads only: it prints the would-be decisions and writes no file and makes
no Jira call, the search included.
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import leg_ledger  # noqa: E402

TABLE = os.path.join(HERE, "failure-routes.table.json")
PLAYBOOK = os.path.join(HERE, "..", "..", "..", "docs", "internals", "stuck-playbook.md")
LOG_ENV, STATE_ENV, INBOX_ENV = "HIMMEL_FAILURE_ROUTES_LOG", "HIMMEL_FAILURE_ROUTES_STATE", "HIMMEL_FAILURE_INBOX"
DONE = ("done", "closed", "resolved", "won't do", "cancelled", "canceled")
JIRA_TIMEOUT = 60

CLASS = re.compile(r"^(denied|suite|blocked|error|run_error|traj)/[A-Za-z0-9._:+-]{1,80}$")
SUB = r"[A-Za-z0-9._:+-]{1,80}"
LEGS = re.compile(r"^N\d+(, N\d+)*$")
KEYS = re.compile(r"^(none|[A-Z][A-Z0-9]+-\d+(, [A-Z][A-Z0-9]+-\d+)*)$")
PRS = re.compile(r"^(none|#\d+(, #\d+)*)$")
TICKET = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
PROJECT = re.compile(r"^[A-Z][A-Z0-9]+$")
HEADS = ("Failure-loop recurrence (HIMMEL-4670 router).", "Failure-loop recurrence update.", "")
INBOX_LINE = re.compile(r"^- \d{4}-\d{2}-\d{2} (denied|suite|blocked|error|run_error|traj)/%s legs=\d+ "
                        r"topic=[a-z0-9-]+\.md: candidate line, classifier denials recurred, check the allow-rule shape$"
                        % SUB)


def now_utc(s=None):
    if not s:
        return datetime.now(timezone.utc).replace(microsecond=0)
    t = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def slug(cls):
    return re.sub(r"[^a-z0-9-]", "-", cls.lower())[:60]


def leg_of(label):
    return re.sub(r"[a-z]$", "", label) if isinstance(label, str) else None


def load_table(path):
    with open(path, encoding="utf-8") as fh:
        t = json.load(fh)
    for r in t["routes"]:
        if r["route"] not in ("ticket", "never", "signal-only"):
            raise ValueError("table route %r is not ticket|never|signal-only" % r["route"])
    return t


def fits(pattern, cls):
    return cls.startswith(pattern[:-1]) if pattern.endswith("*") else cls == pattern


def keep(row, when):
    if when == "identical_retry":
        return (row.get("identical_retry") or 0) >= 1
    if when == "recovered":
        return row.get("recovered") is True and not row.get("identical_retry")
    if when == "final_red":
        return row.get("final_red") is True
    return True


def read_ledger(path, cutoff, now):
    """Valid rows inside the window, by class."""
    by = {}
    if not os.path.exists(path):
        return by
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if leg_ledger.validate(r):
                continue
            try:
                if not cutoff <= now_utc(r["ts"]) <= now:
                    continue
            except ValueError:
                continue
            by.setdefault(r["class"], []).append(r)
    return by


def firing(table, cls, rows):
    """(route row, sorted distinct legs, the counted rows) when the class fires, else None."""
    for t in table["routes"]:
        if not fits(t["match"], cls):
            continue
        when = t.get("when")
        if t["route"] != "ticket":
            if when is None:
                return None
            continue
        counted = [r for r in rows if keep(r, when) and (t.get("any_role") or r["agent"]["role"] == "leg"
                                                          or r["agent"]["id"] == "main")]
        legs = sorted({leg_of(r["leg"]) for r in counted if r["leg"]}, key=lambda x: int(x[1:]))
        if len(legs) >= t["threshold"]:
            return t, legs, counted
        if when is None:
            return None
    return None


def summary_rx(template):
    parts = re.split(r"(\{sub\}|\{legs\})", template)
    return re.compile("^" + "".join(SUB if p == "{sub}" else r"\d+" if p == "{legs}" else re.escape(p)
                                    for p in parts) + "$")


def check_body(text, table=None):
    """Problems; empty = every line is a fixed line or a known label with a value in its alphabet."""
    table = table or load_table(TABLE)
    rows = {t["row"] for t in table["routes"]}
    p = []
    for n, line in enumerate(text.split("\n"), 1):
        if line in HEADS:
            continue
        m = re.match(r"^- ([A-Za-z ()0-9]+): (.*)$", line)
        label, val = (m.group(1), m.group(2)) if m else (None, None)
        good = {"class": lambda v: CLASS.match(v), "legs": lambda v: LEGS.match(v),
                "tickets": lambda v: KEYS.match(v), "PRs": lambda v: PRS.match(v),
                "route": lambda v: v in rows, "playbook entry names the hook": lambda v: v in ("yes", "no")}
        if label and re.match(r"^distinct legs \(\d+ d\)$", label):
            ok = re.match(r"^\d+$", val)
        else:
            ok = label in good and good[label](val)
        if not ok:
            p.append("line %d is outside the body alphabet" % n)
    return p


def build_body(table, t, cls, legs, counted, update):
    tickets = sorted({r["ticket"] for r in counted if r["ticket"]})
    prs = sorted({r["pr"] for r in counted if r["pr"]})
    out = [HEADS[1] if update else HEADS[0], "",
           "- class: %s" % cls,
           "- distinct legs (%d d): %d" % (table["window_days"], len(legs)),
           "- legs: %s" % ", ".join(legs)]
    if not update:
        out += ["- tickets: %s" % (", ".join(tickets) or "none"),
                "- PRs: %s" % (", ".join("#%d" % n for n in prs) or "none")]
        if t.get("playbook"):
            hook = cls.partition("/")[2]
            try:
                with open(PLAYBOOK, encoding="utf-8") as fh:
                    named = hook in fh.read()
            except OSError:
                named = False
            out.append("- playbook entry names the hook: %s" % ("yes" if named else "no"))
        out.append("- route: %s" % t["row"])
    return "\n".join(out) + "\n"


def default_jira():
    try:
        common = subprocess.run(["git", "-C", HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=15, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    cli = os.path.join(os.path.dirname(common), "scripts", "jira", "dist", "index.js")
    return ["node", cli] if os.path.isfile(cli) else None


def jira(argv, args):
    if not argv:
        return None
    try:
        r = subprocess.run(argv + args, capture_output=True, text=True, timeout=JIRA_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def with_file(text, fn):
    fd, path = tempfile.mkstemp(prefix="failure-route-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        return fn(path)
    finally:
        os.unlink(path)


def load_state(path):
    """(state, ok). A missing file is an empty state; anything unreadable is not ok."""
    if not os.path.exists(path):
        return {"v": 1, "classes": {}, "created": {"day": None, "n": 0}}, True
    try:
        with open(path, encoding="utf-8") as fh:
            s = json.load(fh)
        if not (isinstance(s, dict) and isinstance(s.get("classes"), dict) and isinstance(s.get("created"), dict)):
            return None, False
        return s, True
    except (OSError, ValueError):
        return None, False


def save_state(path, s):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".failure-routes.", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(s, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def append_inbox(path, line):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(line + "\n")


def search(jbin, project, cls):
    out = jira(jbin, ["list", "--jql", 'project = %s AND labels = "fl-%s"' % (project, slug(cls)), "--limit", "5"])
    if out is None:
        return None
    hits = []
    for line in out.splitlines():
        if not line.strip():
            continue
        f = line.split("\t")
        if len(f) < 3 or not TICKET.match(f[0]):
            return None  # the CLI prints only ticket rows (nothing on zero hits): anything else is an error
        hits.append((f[0], f[2].strip().lower()))
    return hits


def acted(c, legs):
    """Record the legs a decision acted on, so the same legs never fire twice but new ones do."""
    c["acted"] = sorted(set(c.get("acted", [])) | set(legs))


def decide(a, table, cls, t, legs, counted, c, state, state_ok, today, jbin, project):
    """(decision, ticket). Mutates the class entry c and the state's create count."""
    n = len(legs)
    if not state_ok:
        return "skipped:state-unreadable", None
    if c.get("ticket") and c.get("last_comment_day") == today:
        return "skipped:comment-daily", c["ticket"]
    if a.dry_run:
        cap = state["created"]["n"] if state["created"].get("day") == today else 0
        return ("would-comment" if c.get("ticket") else "would-cap" if cap >= table["daily_cap"]
                else "would-file"), c.get("ticket")
    hits = search(jbin, project, cls)
    if hits is None:
        return "skipped:search-error", c.get("ticket")
    keys = [k for k, _ in hits]
    if c.get("ticket") and c["ticket"] not in keys:
        return "skipped:ticket-unverified", c["ticket"]
    key = c.get("ticket") or (keys[0] if keys else None)
    if key:
        c["ticket"] = key
        if dict(hits)[key] in DONE:
            acted(c, legs)
            return "recurred-after-done", key
        body = build_body(table, t, cls, legs, counted, True)
        if check_body(body, table):
            return "skipped:alphabet", key
        if with_file(body, lambda f: jira(jbin, ["comment", key, "--comment-file", f])) is None:
            return "skipped:jira-error", key
        acted(c, legs)
        c["last_comment_day"] = today
        return "commented", key
    if state["created"].get("day") != today:
        state["created"] = {"day": today, "n": 0}
    if state["created"]["n"] >= table["daily_cap"]:
        return "capped", None
    sub = cls.partition("/")[2]
    title = t["summary"].replace("{sub}", sub).replace("{legs}", str(n))
    body = build_body(table, t, cls, legs, counted, False)
    if check_body(body, table) or not summary_rx(t["summary"]).match(title):
        return "skipped:alphabet", None
    out = with_file(body, lambda f: jira(jbin, ["create", "--type", "Task", "--title", title, "--desc-file", f,
                                                 "--labels", "failure-loop,fl-%s" % slug(cls),
                                                 "--project", project]))
    m = re.search(r"^Created ([A-Z][A-Z0-9]+-\d+)$", out or "", re.M)
    if not m:
        return "skipped:jira-error", None
    state["created"]["n"] += 1
    c["ticket"] = m.group(1)
    acted(c, legs)
    return "filed", m.group(1)


def route(a):
    table = load_table(a.table)
    now = now_utc(a.now)
    today = now.strftime("%Y-%m-%d")
    project = os.environ.get("JIRA_PROJECT_KEY") or "HIMMEL"
    if not PROJECT.match(project):
        print("failure-router: JIRA_PROJECT_KEY %r is not a project key" % project, file=sys.stderr)
        return 1
    try:
        by = read_ledger(a.ledger, now - timedelta(days=table["window_days"]), now)
    except OSError as e:
        print("failure-router: cannot read the ledger: %s" % e, file=sys.stderr)
        return 1
    jbin = [a.jira_bin] if a.jira_bin else default_jira()
    lock = None
    if not a.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(a.state)), exist_ok=True)
        lock = open(a.state + ".lock", "a")
        fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        state, state_ok = load_state(a.state)
        decisions = 0
        for cls in sorted(by):
            fire = firing(table, cls, by[cls])
            if not fire:
                continue
            t, legs, counted = fire
            n = len(legs)
            c = state["classes"].setdefault(cls, {}) if state_ok else {}
            if set(legs) <= set(c.get("acted", [])):
                continue
            inbox = a.inbox if t.get("inbox") and state_ok and not c.get("inbox") else None
            if inbox and not a.dry_run:
                line = ("- %s %s legs=%d topic=%s: candidate line, classifier denials recurred, check the "
                        "allow-rule shape" % (today, cls, n, t["inbox"]))
                if INBOX_LINE.match(line):
                    append_inbox(inbox, line)
                    c["inbox"] = True
            dec, ticket = decide(a, table, cls, t, legs, counted, c, state, state_ok, today, jbin, project)
            if a.dry_run:
                print(json.dumps({"class": cls, "legs": n, "decision": dec, "ticket": ticket,
                                  "inbox": bool(inbox)}, separators=(",", ":")))
                continue
            if (dec, legs) == (c.get("last_decision"), c.get("last_legs")):
                if state_ok:
                    save_state(a.state, state)
                continue
            if state_ok:
                c["last_decision"], c["last_legs"] = dec, legs
                save_state(a.state, state)
            leg_ledger._append(a.log, [{"ts": iso(now), "class": cls, "legs": n, "decision": dec, "ticket": ticket}])
            decisions += 1
            print("failure-router: %s legs=%d %s%s" % (cls, n, dec, " " + ticket if ticket else ""))
        if not a.dry_run:
            print("failure-router: decisions=%d" % decisions)
        return 0
    finally:
        if lock:
            lock.close()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="failure_router.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("route")
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--ledger")
    r.add_argument("--state", default=os.environ.get(STATE_ENV)
                   or os.path.expanduser("~/.himmel/state/failure-routes.json"))
    r.add_argument("--log", default=os.environ.get(LOG_ENV)
                   or os.path.expanduser("~/.himmel/state/failure-routes.log.jsonl"))
    r.add_argument("--inbox", default=os.environ.get(INBOX_ENV))
    r.add_argument("--table", default=TABLE)
    r.add_argument("--now")
    r.add_argument("--jira-bin")
    b = sub.add_parser("check-body")
    b.add_argument("file")
    a = ap.parse_args(argv)
    if a.cmd == "check-body":
        with open(a.file, encoding="utf-8") as fh:
            problems = check_body(fh.read())
        for p in problems:
            print("check-body: %s" % p, file=sys.stderr)
        print("check-body: %s" % ("refused" if problems else "ok"))
        return 1 if problems else 0
    a.ledger = leg_ledger.ledger_path(a.ledger)
    try:
        return route(a)
    except (OSError, ValueError, KeyError) as e:
        print("failure-router: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
