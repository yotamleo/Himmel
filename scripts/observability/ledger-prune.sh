#!/usr/bin/env bash
# scripts/observability/ledger-prune.sh — sanctioned prune helper for
# ~/.himmel/flow-runs.jsonl (HIMMEL-2149 item 2).
#
# WHY: the operator's own park-protocol prune (backup + filter unpaired start
# rows older than a cutoff) is the precedented recovery for ghost start rows
# that pile up in the ledger (killed workers, hermes-invoke stalls, ...). An
# inline write to ~/.himmel/flow-runs.jsonl is classifier-blocked in auto mode
# — it reads as an arbitrary write to a state file — and a bare
# `curl 127.0.0.1:9877/metrics` read was ALSO blocked. This script is the
# sanctioned single-purpose write path, same role restart-stack.sh and
# scripts/cr/write-verdicts.sh play for their own state.
#
# Drops ONLY unpaired start rows (ev="start" with no matching ev="end"
# run_id) older than --cutoff-hours (default 30h). Every end row, every
# paired start row, and every row this script cannot parse or judge the age
# of is kept untouched.
#
# Why 30h, not FLOW_STALLED_ALERT_TTL_SECONDS's 24h directly (CR round 1,
# codex-1): the exporter counts a row as ALERTING only until
# `age > deadlineSeconds(flow) + FLOW_STALLED_ALERT_TTL_SECONDS` — for the
# DEFAULT 6h stall deadline that's 6h + 24h = 30h from fired_at, not 24h. A
# flat 24h-from-fired_at cutoff would prune (and so silently resolve) a row
# still inside the exporter's own alerting window for every flow at or below
# the default deadline. This script has no observability.json parser, so it
# cannot compute a per-flow deadline the way flow-exporter.ts does — for any
# flow with a LONGER declared stall_deadline_seconds, pass a correspondingly
# larger --cutoff-hours (that flow's deadline + 24h) or the same premature-
# prune risk applies to it too.
#
# Usage:
#   bash scripts/observability/ledger-prune.sh [--dry-run] [--cutoff-hours N] [--ledger PATH]
#
# --dry-run       report what WOULD be dropped; writes nothing.
# --cutoff-hours  default 30 (see WHY above).
# --ledger        override the ledger path. Default: $HIMMEL_FLOW_RUNS_LEDGER,
#                 else $HOME/.himmel/flow-runs.jsonl — the same resolution
#                 scripts/telegram/flow-run-ledger.ts's ledgerPath() uses.
#
# A live write backs the ledger up first, to <ledger>.bak-<UTC timestamp>,
# then replaces it via tmp-file + rename (atomic — a concurrent reader, e.g.
# the exporter's own scrape, never sees a half-written file).
#
# Exit codes: 0 success (including "ledger missing, nothing to prune");
# 2 usage error; 3 python3 not found on PATH.
set -uo pipefail

ledger=""
cutoff_hours=30
dry_run=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) dry_run=1; shift ;;
  --cutoff-hours)
    [ $# -ge 2 ] || { echo "ledger-prune.sh: --cutoff-hours requires a value" >&2; exit 2; }
    cutoff_hours="$2"; shift 2 ;;
  --ledger)
    [ $# -ge 2 ] || { echo "ledger-prune.sh: --ledger requires a value" >&2; exit 2; }
    ledger="$2"; shift 2 ;;
  *) echo "ledger-prune.sh: unknown arg $1" >&2; exit 2 ;;
esac; done

# CR round 1 (codex-3): a bare digit-and-dot char class also accepted "0",
# ".", and "1.2.3" — all pass a naive check but are not a meaningful positive
# cutoff ("0" pruned every unpaired start regardless of age). Require a
# strict decimal (digits, optionally one dot with trailing digits) that is
# also > 0.
if ! grep -qE '^[0-9]+(\.[0-9]+)?$' <<< "$cutoff_hours" || ! awk -v v="$cutoff_hours" 'BEGIN { exit !(v > 0) }'; then
  echo "ledger-prune.sh: --cutoff-hours must be a positive number (got '$cutoff_hours')" >&2
  exit 2
fi

if [ -z "$ledger" ]; then
  if [ -n "${HIMMEL_FLOW_RUNS_LEDGER:-}" ]; then
    ledger="$HIMMEL_FLOW_RUNS_LEDGER"
  else
    ledger="${HOME:-}/.himmel/flow-runs.jsonl"
  fi
fi

if [ ! -f "$ledger" ]; then
  echo "ledger-prune.sh: no ledger at $ledger — nothing to prune"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "ledger-prune.sh: python3 not found on PATH" >&2; exit 3; }

tmp="${ledger}.tmp.$$"

if [ "$dry_run" -eq 0 ]; then
  # CR round 3 (codex-2, Suggestion): a bare second-resolution timestamp
  # collides on two prunes started within the same second, and `cp` has no
  # -n — the second run's backup would silently overwrite the first run's
  # true pre-prune backup with an already-once-pruned copy. Append this
  # process's pid: unique across any concurrent invocation, timestamp still
  # human-sortable.
  backup="${ledger}.bak-$(date -u +%Y%m%d-%H%M%S)-$$"
  cp "$ledger" "$backup" || { echo "ledger-prune.sh: backup to $backup failed — refusing to prune" >&2; exit 1; }
  echo "ledger-prune.sh: backed up to $backup"
fi

CUTOFF_HOURS="$cutoff_hours" DRY_RUN="$dry_run" python3 - "$ledger" "$tmp" <<'PYEOF'
import datetime, json, os, stat, sys

src, tmp_path = sys.argv[1], sys.argv[2]
cutoff_hours = float(os.environ["CUTOFF_HOURS"])
dry_run = os.environ["DRY_RUN"] == "1"


def read_and_filter(path):
    """One coherent read -> parse -> classify pass. No writer lock exists on
    this ledger, so there is no way to make read-then-replace fully atomic
    against a concurrent appender; the mitigation is to make this the LAST
    thing the script does before either the dry-run report or the write
    (CR round 2, codex-1) — a single pass computed as late as possible, using
    ONE coherent end_run_ids set, rather than an earlier snapshot's pairing
    decisions applied alongside a later raw append. The earlier two-read
    design (CR round 1, codex-2) could carry a just-arrived end row through
    unfiltered while its matching start — paired only in the SECOND read —
    had already been dropped using the FIRST read's stale pairing info,
    orphaning the end row. A single late pass cannot do that: every row is
    classified against the end_run_ids computed from the SAME read. The
    residual window is now only the few milliseconds this function itself
    takes plus the final `mv` in the wrapping shell script — accepted as a
    genuine ceiling
    (a real writer lock needs a second sanctioned writer to also take it;
    none of this ledger's other writers do), not fixed further here.
    """
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=cutoff_hours)
    # A blank line carries no run data — the exporter's own ledger reader
    # (flow-exporter.ts's parseFlowLedgerRows: `if (!line.trim()) continue;`)
    # already treats one as pure noise to skip, never as content it
    # preserves or counts. Dropping it here on prune matches that existing
    # reader's convention rather than deviating from the "never drop
    # unjudged content" rule below, which is about ROWS this script cannot
    # parse or age-judge, not empty whitespace.
    lines = [l for l in open(path, encoding="utf-8") if l.strip()]
    parsed = []
    for l in lines:
        try:
            parsed.append(json.loads(l))
        except Exception:
            parsed.append(None)  # malformed line — never this script's call to drop

    end_run_ids = {r.get("run_id") for r in parsed if r and r.get("ev") == "end"}

    def keep(row):
        if row is None:
            return True  # malformed JSON — kept as-is
        if row.get("ev") != "start":
            return True  # only unpaired STARTS are ever dropped
        if row.get("run_id") in end_run_ids:
            return True  # paired — the matching end row already governs it
        fired_at = row.get("fired_at")
        try:
            fired = datetime.datetime.strptime(fired_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        except Exception:
            return True  # unparseable timestamp — can't judge age, keep it
        return fired >= cutoff

    kept = [l for l, r in zip(lines, parsed) if keep(r)]
    return lines, kept


if dry_run:
    lines, kept = read_and_filter(src)
    dropped = len(lines) - len(kept)
    print(f"ledger-prune.sh: would drop {dropped} of {len(lines)} row(s) (unpaired starts older than {cutoff_hours}h)")
else:
    # CR round 3 (codex-1, Critical): the single-pass read narrows the
    # inconsistent-pairing race (round 2) but read-then-replace with no
    # writer lock still has a window where a row appended between the read
    # and the swap is silently dropped. Turn silent loss into a loud,
    # retryable refusal instead of eliminating the window outright (a real
    # cross-process lock needs every OTHER writer to this ledger —
    # scripts/telegram/flow-run-ledger.ts's appender — to cooperate, which
    # is out of scope for a single prune helper): capture the source's
    # mtime at read time, and immediately before creating the replacement,
    # re-stat it. If it moved, something appended (or otherwise wrote)
    # concurrently — abort WITHOUT writing tmp_path at all, so the backup
    # stays the only artifact and the live ledger is untouched; rc=1 tells
    # the caller to simply re-run.
    mtime_at_read = os.stat(src).st_mtime
    lines, kept = read_and_filter(src)
    dropped = len(lines) - len(kept)
    if os.stat(src).st_mtime != mtime_at_read:
        print(f"ledger-prune.sh: {src} changed during the prune (concurrent write) — aborting without writing, re-run", file=sys.stderr)
        sys.exit(1)
    # CR round 2 (codex-2), hardened round 4 (codex-2 re-raised at Important:
    # a confidentiality concern, not cosmetic — silently replacing a private
    # ledger with an umask-default, potentially wider-readable file is worse
    # than refusing). Preserve the source's mode bits (e.g. 0600) rather than
    # letting the new tmp file take the process umask default (typically
    # 0644). Getting the source's CURRENT mode still fails open (an already-
    # missing file is the earlier existence check's problem, not this one's
    # to abort on) — but once src_mode is known, APPLYING it is now fail
    # CLOSED: a chmod failure discards tmp_path and aborts loudly rather than
    # silently completing the swap with the wrong (looser) permissions. The
    # backup and the untouched live ledger are always what remain.
    try:
        src_mode = stat.S_IMODE(os.stat(src).st_mode)
    except OSError:
        src_mode = None
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(kept)
    if src_mode is not None:
        try:
            os.chmod(tmp_path, src_mode)
        except OSError as e:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            print(f"ledger-prune.sh: could not preserve {src}'s permissions on the replacement ({e}) — aborting without writing, re-run", file=sys.stderr)
            sys.exit(1)
    print(f"ledger-prune.sh: dropped {dropped} of {len(lines)} row(s) (unpaired starts older than {cutoff_hours}h)")
PYEOF
py_rc=$?
[ "$py_rc" -eq 0 ] || { echo "ledger-prune.sh: filter step failed (rc=$py_rc) — ledger left untouched, backup is intact" >&2; exit 1; }

if [ "$dry_run" -eq 0 ]; then
  mv "$tmp" "$ledger" || { echo "ledger-prune.sh: replacing $ledger failed — backup is at $backup, filtered rows are at $tmp" >&2; exit 1; }
fi
