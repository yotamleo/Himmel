#!/usr/bin/env bash
# scripts/handover/console-kit/leg-digest-step.sh - the wrap step of the
# failure loop (HIMMEL-4670 P3, spec section 5.3): one leg session's P1 digest
# (scripts/eval/leg-digest/leg-digest.ts) handed to the P2 ledger writer
# (scripts/eval/leg-digest/leg_ledger.py record). Zero model calls.
#
# Usage:
#   leg-digest-step.sh --session <uuid> --doc <leg-doc> [--transcript <journal>]
#                      [--pid <pid>] [--projects <dir>] [--console <name>]
#       The close mode, run by close-wrapped-leg.sh after the TERM. Waits,
#       bounded, for <pid> to be gone and the journal and its subagent files to
#       stop changing (spec 1.2); if they never settle the row is `partial`.
#   leg-digest-step.sh --doc <leg-doc> [--projects <dir>]
#       The spec 1.2 fallback, for a leg not closed by close-wrapped-leg.sh.
#       Finds the leg's chain in the project dir of the doc's `resume_cwd` with
#       the close's own matcher (leg-transcripts.sh). A journal is a member when
#       it matches the leg's names, its first `cwd` is `resume_cwd`, and its
#       first timestamp falls in the doc's first-LIVE .. last-WRAPPED window
#       (date from the doc name; LEG_DIGEST_CHAIN_SLACK_MIN minutes before LIVE,
#       default 30, because a session starts before it writes its LIVE bullet).
#       Every member is digested, one line each, prefixed with its session id.
#
# Output: one line per session -
#   digest=ok|partial fails=<n> classes=<k> traj=rbg:<0|1|->,dr:<x|->,idr:<n|->,vbc:<0|1|->
#   digest=failed:<reason>     a row was still attempted: an inconclusive
#                              eval-runs row with meta.digest_error (timeout,
#                              crash, no-journal, bad-json), or the ledger
#                              write itself failed (ledger), or the digest came
#                              back inconclusive (inconclusive)
#   digest=skipped:<reason>    nothing to digest, nothing written
# Always exits 0 (2 on a usage error): the caller's rc never depends on it.
# Idempotence and write order belong to leg_ledger.py (per-session flock,
# marker last), so a re-run or a racing backfill appends nothing new.
#
# Seams: LEG_DIGEST_BIN (replaces `bun leg-digest.ts`), LEG_DIGEST_STATE_DIR,
# LEG_DIGEST_TIMEOUT (60), LEG_DIGEST_SETTLE_MAX (15), LEG_DIGEST_SETTLE_QUIET
# (5), CLAUDE_SESSIONS_PROC (/proc). Ledgers follow leg_ledger.py's own env
# (HIMMEL_LEG_FAILURES_LEDGER, HIMMEL_EVAL_RUNS_LEDGER).
#
# Platform guard: Linux bash 3.2+ (console kit; /proc, GNU date and timeout;
# no .ps1 twin - Windows is parked under HIMMEL-4102).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LD_DIR="$HERE/../../eval/leg-digest"
STATE_DIR="${LEG_DIGEST_STATE_DIR:-$HOME/.himmel/state/leg-digest}"
PROC_ROOT="${CLAUDE_SESSIONS_PROC:-/proc}"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

usage() {
    echo "usage: leg-digest-step.sh --session <uuid> --doc <leg-doc> [--transcript <journal>] [--pid <pid>] [--projects <dir>] [--console <name>]" >&2
    echo "       leg-digest-step.sh --doc <leg-doc> [--projects <dir>]" >&2
    exit 2
}

SID="" SID_SET=0 DOC="" JOURNAL="" PID="" CONSOLE=""
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --session) SID="$2" SID_SET=1 ;;
        --doc) DOC="$2" ;;
        --transcript) JOURNAL="$2" ;;
        --pid) PID="$2" ;;
        --projects) PROJECTS="$2" ;;
        --console) CONSOLE="$2" ;;
        *) usage ;;
    esac
    shift 2
done
if [ -z "$DOC" ] || [ ! -r "$DOC" ]; then usage; fi

# shellcheck source=scripts/lib/leg-identity.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/leg-identity.sh" || { echo "digest=skipped:no-lib"; exit 0; }
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh" 2>/dev/null || true
# shellcheck source=scripts/handover/console-kit/leg-transcripts.sh
# shellcheck disable=SC1091
. "$HERE/leg-transcripts.sh" || { echo "digest=skipped:no-lib"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/leg-digest-step.XXXXXX")" || { echo "digest=skipped:no-tmp"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# ---------- who: closed-shape fields only (leg_ledger.py refuses anything else)
who_args() {
    local stem leg ticket pr console doc_rel root lane
    stem="$(basename "$DOC" .md)"
    leg="$(leg_label "$DOC" 2>/dev/null)"
    printf '%s' "$leg" | grep -qE '^N[0-9]+[a-z]?$' && printf '%s\n' --leg "$leg"
    ticket="$(printf '%s' "$stem" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+')"
    [ -n "$ticket" ] && printf '%s\n' --ticket "$ticket"
    pr="$(grep -E '^- [0-9:]+ (READY|MERGED)' "$DOC" | grep -oE '(READY|MERGED)[ #-]+(PR[ #]+)?[0-9]+' | tail -n 1 | grep -oE '[0-9]+$')"
    [ -n "$pr" ] && printf '%s\n' --pr "$pr"
    console="$CONSOLE"
    # shellcheck disable=SC2016 # literal backticks in the pattern, not an expansion
    [ -n "$console" ] || console="$(grep -oE 'Your console is[^`]*`[^`]+`' "$DOC" | head -n 1 | sed -E 's/.*`([^`]+)`$/\1/')"
    printf '%s' "$console" | grep -qE '^[A-Za-z0-9._-]{1,120}$' && printf '%s\n' --console "$console"
    lane="$(grep -m1 -oE '\((opus|sonnet|haiku|fable)[^)]*, (native|claudex|codex|openrouter|cloud)\)' "$DOC" | sed -E 's/.*, ([a-z]+)\)$/\1/')"
    [ -n "$lane" ] && printf '%s\n' --lane "$lane"
    root="$(handover_root 2>/dev/null)"
    case "$DOC" in
        "$root"/*) doc_rel="${DOC#"$root"/}" ;;
        *) doc_rel="$(basename "$DOC")" ;;
    esac
    printf '%s\n' --doc "$doc_rel"
}

# ---------- settle: pid gone and the session's files unchanged for QUIET s
snapshot() {
    { stat -c '%n %Y %s' "$1" 2>/dev/null
      find "${1%.jsonl}" -name '*.jsonl' -exec stat -c '%n %Y %s' {} + 2>/dev/null; } | sort
}
settle() {
    local pid="$1" j="$2" max="${LEG_DIGEST_SETTLE_MAX:-15}" need="${LEG_DIGEST_SETTLE_QUIET:-5}" i=0 quiet=0 snap prev="-"
    while :; do
        snap="$(snapshot "$j")"
        if [ "$snap" = "$prev" ]; then quiet=$((quiet + 1)); else quiet=0; prev="$snap"; fi
        if { [ -z "$pid" ] || [ ! -d "$PROC_ROOT/$pid" ]; } && [ "$quiet" -ge "$need" ]; then return 0; fi
        [ "$i" -lt "$max" ] || return 1
        i=$((i + 1))
        sleep 1
    done
}

# ---------- record: the P2 writer, then the one result line
summary() { # summary <digest> <word>
    jq -r --arg w "$2" '
        def b: if . == true or . == 1 then "1" elif . == false or . == 0 then "0" else "-" end;
        def n: if type == "number" then tostring else "-" end;
        (.failures // []) as $f | (.metrics // {}) as $m |
        "digest=\($w) fails=\([$f[] | select(.failure != "traj") | .count] | add // 0) classes=\($f | length)" +
        " traj=rbg:\($m.red_before_green | b),dr:\($m.denial_recovery | n),idr:\($m.identical_denied_retries | n),vbc:\($m.verify_before_claim | b)"
    ' "$1" 2>/dev/null
}
record() { # record <digest-file> [<digest-error>]
    local args=() a
    while IFS= read -r a; do args+=("$a"); done <<EOF
$(who_args)
EOF
    [ -z "${2:-}" ] || args+=(--digest-error "$2")
    timeout -k 5 30 python3 "$LD_DIR/leg_ledger.py" record --digest "$1" --state-dir "$STATE_DIR" "${args[@]}" >/dev/null 2>&1
}
failed_digest() { # failed_digest <sid> <reason>
    printf '{"digest_v":1,"mapper_v":1,"trajectory_v":null,"session":"%s","status":"inconclusive","model":null,"metrics":{},"failures":[]}\n' "$1" > "$WORK/failed.json"
    if record "$WORK/failed.json" "$2"; then echo "digest=failed:$2"; else echo "digest=failed:ledger"; fi
}
digest_one() { # digest_one <sid> <journal> <pid-or-empty> <wait:0|1>
    local sid="$1" j="$2" pid="$3" settled=1 rc status
    if [ -z "$j" ] || [ ! -f "$j" ]; then failed_digest "$sid" no-journal; return; fi
    if [ "$4" = 1 ] && ! settle "$pid" "$j"; then settled=0; fi
    if [ -n "${LEG_DIGEST_BIN:-}" ]; then
        nice -n 10 timeout -k 5 "${LEG_DIGEST_TIMEOUT:-60}" "$LEG_DIGEST_BIN" --transcript "$j" > "$WORK/digest.json" 2>/dev/null
    else
        nice -n 10 timeout -k 5 "${LEG_DIGEST_TIMEOUT:-60}" bun "$LD_DIR/leg-digest.ts" --transcript "$j" > "$WORK/digest.json" 2>/dev/null
    fi
    rc=$?
    case "$rc" in
        0) ;;
        124|137) failed_digest "$sid" timeout; return ;;
        *) failed_digest "$sid" crash; return ;;
    esac
    status="$(jq -r 'if type == "object" then .status else empty end' "$WORK/digest.json" 2>/dev/null)"
    [ -n "$status" ] || { failed_digest "$sid" bad-json; return; }
    if [ "$settled" = 0 ] && [ "$status" = ok ]; then
        jq -c '.status = "partial"' "$WORK/digest.json" > "$WORK/digest.p" && mv "$WORK/digest.p" "$WORK/digest.json"
        status=partial
    fi
    record "$WORK/digest.json" || { echo "digest=failed:ledger"; return; }
    case "$status" in
        ok|partial) summary "$WORK/digest.json" "$status" ;;
        *) echo "digest=failed:inconclusive" ;;
    esac
}

# ---------- close mode -------------------------------------------------------
if [ "$SID_SET" = 1 ]; then
    printf '%s' "$SID" | grep -qE "$UUID_RE" || { echo "digest=skipped:no-session"; exit 0; }
    if [ -z "$JOURNAL" ] || [ "$(transcript_sid "$JOURNAL")" != "$SID" ]; then
        JOURNAL="$(find "$PROJECTS" -mindepth 2 -maxdepth 2 -name "$SID.jsonl" 2>/dev/null | head -n 1)"
    fi
    digest_one "$SID" "$JOURNAL" "$PID" 1
    exit 0
fi

# ---------- fallback: the leg's chain from its doc (spec 1.2) ----------------
cwd="$(sed -n '1,/^---$/{s/^resume_cwd: *//p;}' "$DOC" | head -n 1)"
[ -n "$cwd" ] || { echo "digest=skipped:no-resume-cwd"; exit 0; }
day="$(basename "$DOC" .md | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -n 1)"
live="$(grep -m1 -oE '^- [0-9]{2}:[0-9]{2} LIVE' "$DOC" | grep -oE '[0-9]{2}:[0-9]{2}')"
wrapped="$(grep -oE '^- [0-9]{2}:[0-9]{2} WRAPPED' "$DOC" | tail -n 1 | grep -oE '[0-9]{2}:[0-9]{2}')"
if [ -z "$day" ] || [ -z "$live" ] || [ -z "$wrapped" ]; then echo "digest=skipped:no-window"; exit 0; fi
# Midnights the leg crossed: each HH:MM bullet, first LIVE .. last WRAPPED, that
# reads earlier than the bullet before it is a day roll-over (HIMMEL-4705).
# ponytail: a >24h gap with no bullet in between still counts as one day, upgrade path: full dates in the Results bullets if such a leg is seen
rolls="$(awk '/^- [0-9][0-9]:[0-9][0-9] / {
        m = substr($2, 1, 2) * 60 + substr($2, 4, 2)
        if (!on) { if ($3 ~ /^LIVE/) { on = 1; prev = m }; next }
        if (m < prev) d++
        prev = m
        if ($3 ~ /^WRAPPED/) last = d
    } END { print last + 0 }' "$DOC")"
lo=$(( $(date -d "$day $live" +%s) - ${LEG_DIGEST_CHAIN_SLACK_MIN:-30} * 60 ))
hi=$(( $(date -d "$day $wrapped" +%s) + rolls * 86400 + 60 ))
ident="$(leg_identity "$DOC")"
candidates="$(printf '%s\n%s\n' "${ident#*$'\t'}" "$(basename "$DOC" .md)" | tr ',' '\n' | sed '/^$/d')"
slug="$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
[ -d "$PROJECTS/$slug" ] || { echo "digest=skipped:no-chain"; exit 0; }
# Every file of the leg's own project dir, whole: a chain spans days and
# renames, so the close's recent-and-head-bounded first pass would hide members.
members=0
while IFS= read -r j; do
    [ -n "$j" ] || continue
    sid="$(transcript_sid "$j")"
    printf '%s' "$sid" | grep -qE "$UUID_RE" || continue  # a subagent file, not a session
    first="$(head -n 40 "$j" | jq -r 'select(type == "object") | [.cwd // empty, .timestamp // empty] | @tsv' 2>/dev/null)"
    jcwd="$(printf '%s\n' "$first" | awk -F'\t' 'NF == 2 { print $1; exit }')"
    jts="$(printf '%s\n' "$first" | awk -F'\t' 'NF == 2 { print $2; exit }')"
    [ "$jcwd" = "$cwd" ] || continue
    t="$(date -d "$jts" +%s 2>/dev/null)" || continue
    if [ "$t" -lt "$lo" ] || [ "$t" -gt "$hi" ]; then continue; fi
    members=$((members + 1))
    printf '%s %s\n' "$sid" "$(digest_one "$sid" "$j" "" 0)"
done <<EOF
$(match_transcripts "$(find "$PROJECTS/$slug" -type f -name '*.jsonl' 2>/dev/null)" 0 "$candidates")
EOF
[ "$members" -gt 0 ] || echo "digest=skipped:no-chain"
exit 0
