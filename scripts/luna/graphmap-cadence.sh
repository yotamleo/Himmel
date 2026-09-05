#!/usr/bin/env bash
# graphmap-cadence.sh — arm/status/disarm the recurring graphify curated-map
# cadence (HIMMEL-829, Option B).
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. scripts/graphify/refresh-graph-map.sh (HIMMEL-825) is the schedulable
# RUNNER that does a fence-safe incremental refresh + republishes a curated MOC
# for ONE corpus. What was missing is the scheduler/arm layer. This is that
# layer: a SEPARATE OS-scheduler cadence (Option B) that bounds graph drift with
# TWO tiers, inverted from the original daily-semantic-only shape (HIMMEL-1948):
#   - STRUCTURAL/AST (`graphify update <corpus> --force`): pure local parse, no
#     LLM, no API key, no bank, no egress. Cheap enough to run HOURLY.
#   - SEMANTIC (refresh-graph-map.sh: LLM extraction of markdown docs + curated
#     MOC/community naming): the only tier that costs anything. Runs WEEKLY, off
#     the interactive Anthropic bank (see BACKEND below).
# HIMMEL-1948: the ORIGINAL shape ran the expensive semantic tier daily and the
# free structural tier never. When the operator's 5h/weekly bank got tight,
# bank-preflight silently no-opped the daily semantic refresh for a month
# (nobody noticed — see graph-refresh.sh's exit-code fix, HIMMEL-1948 Task 1)
# while the structural graph, which needed no bank at all, went stale right
# alongside it for no reason. Inverted: cheap+free runs often, expensive+paid
# runs rarely.
#
# DESIGN DIFFERENCE from the sibling pipeline-cadence.sh: pipeline-cadence fires
# interactive `claude "<prompt>" < NUL` bounded sessions (each pipeline task = a
# claude session, wired with a --settings auto-approve fragment). THIS scheduler
# fires DETERMINISTIC commands directly — `bash <himmel>/scripts/graphify/
# refresh-graph-map.sh <args>` for the semantic pair, `bash <himmel>/scripts/
# graphify/ast-update.sh <corpus>` for the structural pair (CR r1b: routed
# through the promote-lock wrapper instead of a bare `graphify update` call)
# — so NEITHER pair ever opens a claude SESSION, NO NUL-stdin, NO settings
# fragment, and NO auto-approve hook.
# That keeps pipeline-cadence's "every task = a claude session" invariant
# clean, and makes this scheduler strictly simpler than its sibling.
# HIMMEL-1948: the semantic BACKEND is `kimi` (Moonshot API), not claude-cli —
# HIMMEL-128's claude invocation billing does NOT apply here at all anymore
# (no CLI is shelled, on either pair); egress is governed by the matrix instead
# (see BACKEND below). The structural pair never talks to any provider.
#
# FENCE SAFETY: refresh-graph-map.sh never extracts on a live vault — it copies
# the corpus to a PID-owned scratchpad, carries the `.graphify-corpus` marker,
# and only publishes the curated MOC back into the vault's 60-Maps/. That
# discipline lives in the runner; this scheduler just fires it.
#
# OPERATOR FLIP: arming this cadence commits to an HOURLY free structural
# extraction per corpus (no bank, no egress) AND a WEEKLY semantic extraction
# per corpus on the kimi (Moonshot API) backend (HIMMEL-1948 — off the
# interactive Anthropic bank; the fence maps kimi -> moonshot by effective
# endpoint). It never auto-arms — `arm` registers all four tasks only when
# explicitly invoked, so the operator decides.
#
# Four tasks are registered:
#   HIMMEL-GraphMap-Luna       weekly, semantic (default Sunday 13:00 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name luna ...
#   HIMMEL-GraphMap-Himmel     weekly, semantic (default Sunday 13:20 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name himmel ...
#   HIMMEL-GraphMapAst-Luna    DAILY, structural, free (default 00:05 local)
#       bash <himmel>/scripts/graphify/ast-update.sh <vault>
#   HIMMEL-GraphMapAst-Himmel  hourly, structural, free (default :15 past)
#       bash <himmel>/scripts/graphify/ast-update.sh <himmel repo>
#   (ast-update.sh runs `graphify update <corpus> --force` itself, behind the
#   HIMMEL-910 promote lock shared with the semantic pair -- CR r1b, see that
#   script's header.)
#
# WHY SUNDAY 13:00 / 13:20 LOCAL for the semantic pair (staggered 20 min apart,
# same as before HIMMEL-1948, now weekly instead of daily): a quiet day/time
# default; the stagger REDUCES THE CHANCE of the two extraction jobs
# overlapping (it cannot guarantee no overlap — luna and himmel are different
# corpora / out dirs, so the per-out-dir promote lock does not serialize them).
# The kimi backend has no provider off-peak window, so these times are not
# cost-driven. WHY :05 / :15 PAST THE HOUR for the structural pair (10 min
# apart, tighter than the semantic stagger — these legs are seconds-to-minutes,
# not the semantic legs' LLM-bound runtime): same overlap-reduction rationale,
# scaled to how fast a local AST re-parse actually is. The backend/day/hour
# offsets are fixed as BACKEND/WEEKLY_DAY_*/AST_*_TIME in this script — not
# flags; edit + re-arm to change them.
#
# Usage:
#   bash scripts/luna/graphmap-cadence.sh arm [--luna-time HH:MM]
#       [--himmel-time HH:MM] [--vault PATH] [--force] [--dry-run]
#   bash scripts/luna/graphmap-cadence.sh status
#   bash scripts/luna/graphmap-cadence.sh disarm
#
# --luna-time/--himmel-time apply ONLY to the weekly semantic pair (unchanged
# from before HIMMEL-1948); the structural pair's fire offsets are not
# operator-configurable (see WHY :05/:15 above).
#
# Test seams (used by test-graphmap-cadence.sh):
#   GRAPHMAP_SCHTASKS  — command invoked instead of `schtasks` (Windows)
#   GRAPHMAP_CRONTAB   — command invoked instead of `crontab` (POSIX)
#   GRAPHMAP_BAT_DIR   — where the persistent runners (.bat/.sh) live
#
# Exit codes (mirrors pipeline-cadence.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no schtasks/crontab; unknown platform; runner missing;
#      query tool errored)
#   3  dedup block — HIMMEL-GraphMap-* task(s) already armed; use --force
#   4  scheduler invocation failed (/create, /delete, crontab rewrite,
#      path conversion)
set -euo pipefail

TASK_PREFIX="HIMMEL-GraphMap-"
TASK_LUNA="${TASK_PREFIX}Luna"
TASK_HIMMEL="${TASK_PREFIX}Himmel"
# Structural (AST) pair (HIMMEL-1948 Task 3): a DISTINCT prefix so these can
# never collide with the semantic pair above.
TASK_AST_PREFIX="HIMMEL-GraphMapAst-"
TASK_AST_LUNA="${TASK_AST_PREFIX}Luna"
TASK_AST_HIMMEL="${TASK_AST_PREFIX}Himmel"
# Exact-name match for "does this task/cron-entry belong to THIS cadence"
# (HIMMEL-1948 CR r2): built from the four owned names only, used by
# list_existing/cron_existing/the crontab own-entry filters so arm/status/
# disarm treat exactly these four as one cadence family. A dash-less PREFIX
# match used to sit here and would catch an operator's own unrelated
# "HIMMEL-GraphMap*" task/cron-entry too — collateral delete on disarm, or a
# false dedup-block on arm. Adding a fifth task later means adding it to this
# alternation, not widening a prefix.
TASK_MATCH_RE="(${TASK_LUNA}|${TASK_HIMMEL}|${TASK_AST_LUNA}|${TASK_AST_HIMMEL})"
SCHTASKS_BIN="${GRAPHMAP_SCHTASKS:-schtasks}"
CRONTAB_BIN="${GRAPHMAP_CRONTAB:-crontab}"

# Cross-platform user-home resolution (mirrors pipeline-cadence's
# resolve_user_home, HIMMEL-645). On Windows Git-Bash $HOME can be the MSYS home
# (/home/<user>) while Claude Code's config (~/.claude) lives under the Windows
# user profile, so prefer USERPROFILE via cygpath BEFORE $HOME. POSIX hosts have
# USERPROFILE unset and fall straight through to $HOME. /tmp is the last-resort
# floor when both are unset.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home (.bat on Windows, .sh on POSIX) — NOT mktemp: these
# tasks recur daily and %TEMP% / /tmp are subject to cleanup sweeps that would
# silently kill the cadence (same rationale as pipeline-cadence's BAT_DIR).
BAT_DIR="${GRAPHMAP_BAT_DIR:-$(resolve_user_home)/.claude/graphmap-cadence}"

# Resolve the himmel root from this script's own location (scripts/luna/..),
# so the runner fires the shipped refresh-graph-map.sh by absolute path.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
REFRESH_SCRIPT="$HIMMEL_ROOT/scripts/graphify/refresh-graph-map.sh"
# Structural (AST) pair (HIMMEL-1948 CR r1b): routes through the promote-lock
# wrapper, by absolute path, same rationale as REFRESH_SCRIPT above -- see
# ast-update.sh's own header for why (HIMMEL-910 lock, shared graphify-out).
AST_UPDATE_SCRIPT="$HIMMEL_ROOT/scripts/graphify/ast-update.sh"

# Runner-format version stamp (HIMMEL-588): emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner so a stale-format armed cadence
# is detectable. Reused from the shared lib (same as pipeline-cadence).
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/observability-registry.sh"

# Off-peak defaults for the WEEKLY semantic legs (see the header for the
# Sunday 13:00 / 13:20 local rationale; HIMMEL-1948 changed daily -> weekly,
# same times/stagger).
LUNA_TIME="13:00"
HIMMEL_TIME="13:20"
# Weekly day-of-week, semantic legs only (HIMMEL-1948). Sunday: quiet, low odds
# of colliding with weekday operator work; ONE fixed day shared by both legs
# (the 20-min stagger still separates them within that day).
WEEKLY_DAY_XML="Sunday"    # schtasks XML <DaysOfWeek> element name
WEEKLY_DAY_CRON="0"        # cron day-of-week field (0 = Sunday)

# Structural (AST) legs: free, no bank, no claude session (HIMMEL-1948 Task 3).
# Fixed offsets, not operator flags — there's no cost/off-peak reason to make
# these configurable (see the header's WHY :05/:15); 10 minutes apart so the two
# corpora's `graphify update` calls never start in the same instant.
#
# CADENCE IS ASYMMETRIC (HIMMEL-1960, operator decision (a)): himmel fires
# HOURLY, luna only DAILY. Both legs are free either way — the asymmetry is
# about the artifact, not the cost. luna is a live personal vault with an
# auto-committer, so an hourly in-place `graphify update` meant ~24 commits a
# day of graph churn in it; himmel has no auto-committer (/graph-publish owns
# shipping its graph), so nothing accumulates there. For luna these times are
# a time-of-day; for himmel AST_HIMMEL_TIME is the hourly repetition's
# start-of-day anchor, so its minute is what actually recurs.
AST_LUNA_TIME="00:05"
AST_HIMMEL_TIME="00:15"

# Default vault resolution (cross-platform; mirrors pipeline-cadence). Honors
# LUNA_VAULT_PATH first, else <home>/Documents/luna. Explicit --vault overrides.
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}
VAULT="$(default_vault)"
FORCE=0
DRY_RUN=0
# --ast-only (HIMMEL-2071): arm/dedup-check ONLY the free structural (AST)
# pair, leaving the weekly semantic pair (and its backend credential
# requirement) untouched/absent. Lets the free legs re-arm independently of
# an operator ruling on the semantic pair's backend/egress. arm-only flag;
# ignored by status/disarm (both already report/remove per-task).
AST_ONLY=0

# Fixed per-corpus map identity (titles/slugs/tags). ASCII-only: the .bat is
# parsed by cmd.exe under the OEM codepage where UTF-8 punctuation mojibakes.
LUNA_TITLE="Graphify Luna Map"
LUNA_SLUG="graphify-luna-map"
LUNA_TAG="luna"
HIMMEL_TITLE="Graphify Himmel Map"
HIMMEL_SLUG="graphify-himmel-map"
HIMMEL_TAG="himmel"
# HIMMEL-1948 (invert the cadence): the semantic legs now run WEEKLY, off the
# interactive Anthropic bank entirely. The old claude-cli backend (HIMMEL-1049)
# shelled the local `claude` CLI, which draws the SAME 5h/weekly subscription
# bank as interactive use (HIMMEL-1748, measured 2026-08-11/12) — a semantic
# refresh on that bucket is exactly what silently starved the free structural
# layer for weeks (bank hit 87%, bank-preflight refused, every scheduled
# refresh no-opped, nobody noticed until HIMMEL-1948). BACKEND is now `kimi`
# (graphify's literal for Moonshot; the fence maps kimi -> moonshot by
# effective endpoint via _map_kimi_endpoint, API-key-only, zero interactive-
# bank draw). Egress authorization (verified 2026-08-19, do not re-litigate):
# `luna-personal x moonshot x extraction` = allow+log, operator-ratified
# 2026-08-12 (HIMMEL-1748); `himmel-code x *` = allow (wildcard;
# public-propagated code/docs). Already-armed tasks keep their baked-in
# --backend until re-armed with this default.
BACKEND="kimi"

# Resolved by validate_arm_inputs (both arm paths call it): `graphify` itself,
# and its directory. BOTH the semantic legs (refresh-graph-map.sh shells
# graphify with --backend $BACKEND) and the structural legs (ast-update.sh
# shells `graphify update`, HIMMEL-1948 Task 3 / CR r1b) need it on PATH at fire time
# — the scheduler's minimal PATH carries neither node nor graphify by default.
# Both runner formats prepend the directory to PATH — see the HIMMEL-1070 note
# in validate_arm_inputs (that note predates the HIMMEL-1948 backend switch,
# which is why this resolves `graphify`, not `claude`: claude-cli's shelled
# `claude` CLI is no longer in the picture on any task this script arms).
GRAPHIFY_BIN=""
GRAPHIFY_DIR=""

usage() {
    cat <<'EOF'
Usage: graphmap-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring graphify graph cadence (HIMMEL-829,
inverted HIMMEL-1948): an HOURLY free structural (AST) refresh per corpus
(`graphify update <corpus> --force`, via the promote-lock wrapper — no bank, no claude session) AND a
WEEKLY semantic refresh per corpus (fence-safe incremental extraction +
curated-MOC republish, `bash refresh-graph-map.sh ...` on the kimi/Moonshot
backend — off the interactive Anthropic bank). Neither pair ever opens a
claude session.

Subcommands:
  arm      Register all four tasks. Dedup-guarded: refuses (rc=3) if any
           HIMMEL-GraphMap-* task already exists; --force replaces.
  status   Show which cadence tasks are armed (+ next run time).
  disarm   Remove all four tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --luna-time <HH:MM>    Weekly luna-map time, 24h local   (default 13:00,
                         semantic leg only)
  --himmel-time <HH:MM>  Weekly himmel-map time, 24h local (default 13:20,
                         semantic leg only; staggered 20min after luna to
                         reduce the chance of the two extraction jobs
                         overlapping — different corpora/out-dirs, so no
                         shared lock serializes them)
  --vault <PATH>         Luna vault root (default: $LUNA_VAULT_PATH if set,
                         else <user-profile>/Documents/luna). The vault's
                         60-Maps/ is where the curated MOCs are published.
  --force                Replace existing HIMMEL-GraphMap-* tasks
  --dry-run              Print what would happen, touch nothing
                         (honored by arm AND disarm)
  --ast-only             Arm/dedup-check ONLY the free structural (AST) pair
                         (HIMMEL-2071) -- the weekly semantic pair is left
                         absent/untouched and its backend credential is not
                         required. Re-arm without --ast-only later to add the
                         semantic pair back in (--force to replace).

The structural (AST) pair's offsets (luna daily 00:05, himmel hourly at :15)
are NOT flags — see WEEKLY_DAY_*/AST_*_TIME in this script.

WHY Sunday 13:00 / 13:20 local for the semantic pair: a quiet day/time
default, staggered 20min to reduce the chance of the two extraction jobs
overlapping (not a guarantee — they use different corpora/out-dirs, so no
shared lock serializes them). The kimi backend has no provider off-peak
window, so the times are not cost-driven. The extraction backend is NOT a
flag here — it is fixed as BACKEND in this script (kimi); edit it there and
re-arm to change it.
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR graphmap-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR graphmap-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --luna-time)     LUNA_TIME="${2:-}"; shift 2 ;;
        --luna-time=*)   LUNA_TIME="${1#--luna-time=}"; shift ;;
        --himmel-time)   HIMMEL_TIME="${2:-}"; shift 2 ;;
        --himmel-time=*) HIMMEL_TIME="${1#--himmel-time=}"; shift ;;
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --vault=*)       VAULT="${1#--vault=}"; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --ast-only)      AST_ONLY=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR graphmap-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Platform detect (same matrix as pipeline-cadence.sh).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    windows)
        command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
            echo "ERR graphmap-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR graphmap-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR graphmap-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

# MSYS_NO_PATHCONV=1 per call: without it gitbash mangles /query, /create etc.
# into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Dedup listing: every scheduled task named HIMMEL-GraphMap-*. Fail-CLOSED if
# the query tool itself errors (mirrors pipeline-cadence list_existing).
list_existing() {
    local err_file out rc
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    out=$(run_schtasks /query /fo CSV /nh 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        # Fail-CLOSED: any nonzero rc is fatal UNLESS it matches the one trusted
        # empty-scheduler signature — rc=1 with EMPTY stderr (schtasks returns
        # rc=1 on a completely empty scheduler; real errors carry stderr).
        if [ "$rc" -ne 1 ] || [ -s "$err_file" ]; then
            echo "ERR graphmap-cadence: schtasks /query failed (rc=$rc) — refusing to treat as empty scheduler:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # shellcheck disable=SC1003  # strips both quote and the literal backslash schtasks prefixes task names with
    # First narrow to candidates carrying either prefix (cheap pre-filter),
    # then require an EXACT match against one of the four owned names
    # (TASK_MATCH_RE, HIMMEL-1948 CR r2) — a task merely starting with
    # "HIMMEL-GraphMap" (an operator's own unrelated task) must not be treated
    # as ours, or --force would delete it and a plain arm would false-dedup-block.
    printf '%s\n' "$out" \
        | grep -o '"\\\?HIMMEL-GraphMap[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u \
        | grep -xE "$TASK_MATCH_RE" || true
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "graphmap-cadence: deleted scheduled task: $name"
    else
        echo "ERR graphmap-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Known not-found stderr signatures for `/query /tn <name>` (mirrors
# pipeline-cadence). Real schtasks always emits one of these on a missing task,
# so rc=1 WITHOUT a match (silent rc=1 included) is a real query failure.
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_one <name>: rc 0 = armed (QUERY_OUT set), rc 1 = trusted not-found,
# rc 2 = query failed (stderr already printed).
QUERY_OUT=""
query_one() {
    local name="$1" rc err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        rm -f "$err_file"
        return 0
    fi
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"
        return 1
    fi
    echo "ERR graphmap-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a localized 'task does not exist' message, the task may simply" >&2
    echo "    not be armed. Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

task_summary() {
    case "$1" in
        "$TASK_LUNA")       printf ' -> refresh-graph-map luna (weekly, semantic, kimi)' ;;
        "$TASK_HIMMEL")     printf ' -> refresh-graph-map himmel (weekly, semantic, kimi)' ;;
        "$TASK_AST_LUNA")   printf ' -> graphify update luna (daily, structural, free)' ;;
        "$TASK_AST_HIMMEL") printf ' -> graphify update himmel (hourly, structural, free)' ;;
    esac
}

status_one() {
    local name="$1" next qrc=0
    query_one "$name" || qrc=$?
    case "$qrc" in
        0)
            next=$(printf '%s\n' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 \
                | sed 's/^[^:]*:[[:space:]]*//' || true)
            cadence_registered_status "$name" "${next:+ (next run: $next)}$(task_summary "$name")" || return 2
            ;;
        1)  echo "not armed  $name$(task_summary "$name")" ;;
        *)
            echo "QUERY ERR  $name (see stderr above)"
            return 2
            ;;
    esac
}

# Runaway summary for one run log (HIMMEL-1901 ask 3). Prints ONE line, or
# nothing when the file carries none of the three markers (not a graphify run
# log, or a run that died before its first chunk).
#
# Why post-hoc from the log instead of "emit tokens: on abnormal termination":
# graphify accumulates the token counters in memory and prints its `tokens:`
# line only on the normal write path, so a run killed by the run deadline --
# or by the 2026-08-17 reboot -- leaves no token totals ANYWHERE. The numbers
# do not exist to be emitted, by us or by the runner. What the log does carry,
# line by line as it happens, is the runaway's own signature: every hollow
# response graphify reclassifies as truncation so adaptive retry bisects the
# chunk. Counting those alongside the last chunk-progress line reconstructs
# the storm after ANY termination mode -- including the one where no shell of
# ours survives to print anything -- which is what "visible without reading
# the whole log" needs. Emitting real totals on an abnormal exit, and not
# treating hollow as truncation in the first place, are upstream
# (Graphify-Labs/graphify#2880; this repo has read-only access there).
log_summary() {
    # Logs are written by a Windows .bat, so every line carries a trailing CR.
    # STORM threshold: one chunk bisecting to graphify's max_retry_depth=3 cap
    # issues at most 15 calls, so >15 hollow responses is more than a single
    # bad chunk -- i.e. the sustained storm this ticket exists to catch.
    awk '
        { sub(/\r$/, "") }
        /returned a hollow response/ { hollow++ }
        /[[:space:]]tokens:[[:space:]]/ { tok = substr($0, index($0, "tokens:") + 8) }
        /chunk [0-9]+\/[0-9]+ done/ {
            if (match($0, /chunk [0-9]+\/[0-9]+/)) chunk = substr($0, RSTART, RLENGTH)
        }
        END {
            if (hollow == 0 && tok == "" && chunk == "") exit 0
            out = (tok != "" ? tok : "NO tokens summary (run did not finish)")
            if (chunk != "") out = out " | last " chunk
            # Coerced on its own line: concatenating hollow + 0 inline leans on
            # concatenation binding looser than +, which POSIX awk does but is
            # not worth betting the mawk run on the public mirror against.
            n = hollow + 0
            out = out " | " n " hollow responses"
            if (hollow > 15) out = out " -- HOLLOW-BISECT STORM (HIMMEL-1901)"
            print out
        }
    ' "$1" 2>/dev/null || true
}

# Surface fire-time evidence: each runner writes its output to a .log next to the
# runner (rotated per fire), so "armed but never succeeding" is visible here.
status_log() {
    local log="$1" mtime last summary
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        summary=$(log_summary "$log")
        if [ -n "$summary" ]; then
            echo "             run summary: $summary"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        summary=$(log_summary "$log.prev")
        if [ -n "$summary" ]; then
            echo "             run summary: $summary"
        fi
    fi
}

cmd_status() {
    local status_rc=0
    echo "graphmap-cadence status:"
    status_one "$TASK_LUNA" || status_rc=2
    status_log "$BAT_DIR/graphmap-luna.log"
    status_one "$TASK_HIMMEL" || status_rc=2
    status_log "$BAT_DIR/graphmap-himmel.log"
    status_one "$TASK_AST_LUNA" || status_rc=2
    status_log "$BAT_DIR/graphmap-ast-luna.log"
    status_one "$TASK_AST_HIMMEL" || status_rc=2
    status_log "$BAT_DIR/graphmap-ast-himmel.log"
    return "$status_rc"
}

cmd_disarm() {
    local name found=0 qrc
    for name in "$TASK_LUNA" "$TASK_HIMMEL" "$TASK_AST_LUNA" "$TASK_AST_HIMMEL"; do
        qrc=0
        query_one "$name" || qrc=$?
        case "$qrc" in
            0)
                found=1
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY graphmap-cadence: would delete $name"
                else
                    delete_task "$name"
                fi
                ;;
            1)  : ;;
            *)  exit 2 ;;
        esac
    done
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/graphmap-luna.bat" "$BAT_DIR/graphmap-himmel.bat" \
              "$BAT_DIR/graphmap-ast-luna.bat" "$BAT_DIR/graphmap-ast-himmel.bat"
        rm -f "$BAT_DIR/graphmap-luna.vbs" "$BAT_DIR/graphmap-himmel.vbs" \
              "$BAT_DIR/graphmap-ast-luna.vbs" "$BAT_DIR/graphmap-ast-himmel.vbs"
        observability_unregister_cadence graphmap-luna "$TASK_LUNA"
        observability_unregister_cadence graphmap-himmel "$TASK_HIMMEL"
        observability_unregister_cadence graphmap-ast-luna "$TASK_AST_LUNA"
        observability_unregister_cadence graphmap-ast-himmel "$TASK_AST_HIMMEL"
    fi
    if [ "$found" -eq 0 ]; then
        echo "graphmap-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY graphmap-cadence: no changes made"
    else
        echo "graphmap-cadence: cadence disarmed"
    fi
}

# Build the argv the .bat hands to bash: the refresh-graph-map.sh path + its
# flags. All interpolated path values are already cmd-escaped by the caller;
# name/slug/tag/backend are fixed ASCII literals.
bat_payload() {
    local script_esc="$1" name="$2" corpus_esc="$3" maps_esc="$4" title="$5" slug="$6" tag="$7"
    printf '"%s" --name %s --corpus-root "%s" --maps-dir "%s" --title "%s" --slug %s --backend %s --corpus-tag %s' \
        "$script_esc" "$name" "$corpus_esc" "$maps_esc" "$title" "$slug" "$BACKEND" "$tag"
}

# Structural (AST) payload builder (HIMMEL-1948 Task 3, routed through the
# promote-lock wrapper as of CR r1b): fires ast-update.sh by absolute path
# with the corpus root as its sole argument. No --backend/--maps-dir/--title/
# --slug: `update` publishes no curated MOC, just the local structural
# re-parse. --force stays but is no longer on THIS command line -- it is
# baked into ast-update.sh itself (kept, HIMMEL-1938 -- see that script's
# header). ast-update.sh is a bash script, so (unlike the old bare `graphify`
# call) it needs the bash prefix the caller adds, same as bat_payload's
# refresh-graph-map.sh call. GRAPHIFY_DECLARED_BACKEND (luna leg only, see
# emit_bat's declare_ollama arg) satisfies the fence's LLM-free-subcommand
# backend-declaration requirement out of band; it is never part of this
# command line.
ast_bat_payload() {
    local script_esc="$1" corpus_esc="$2"
    printf '"%s" "%s"' "$script_esc" "$corpus_esc"
}

# Emit the .bat body for one cadence task: stamp the format version, rotate the
# run log (one prior run kept as .log.prev), stamp the fire time, cd into the
# himmel root (a failing cd aborts + is logged, instead of firing from the wrong
# CWD), then fire the payload with its stdout+stderr captured to the rotating
# log. NO claude SESSION, NO stdin redirect, on EITHER pair (HIMMEL-1948): the
# runner IS the payload, and `graphify` itself (semantic pair, via
# refresh-graph-map.sh; structural pair, via ast-update.sh) must be resolvable
# on the scheduler's minimal PATH -- hence the PATH prepend below.
emit_bat() {
    # No bash-path parameter: the interpreter is already baked into $payload by
    # the caller (cmd-escaped, HIMMEL-1281). There used to be a $2 carrying the
    # RAW bash_win that this body never read — dead weight, and the one raw
    # value left sitting among escaped ones, which is exactly how an unescaped
    # path gets used by accident later. Dropped rather than fed an escaped
    # value nothing reads.
    local himmel_win_esc="$1" payload="$2" log_win_esc="$3" graphify_dir_win_esc="${4:-}" git_bin_esc="${5:-}" declare_ollama="${6:-0}"
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    # Prepend Git's usr\bin + bin so a NON-LOGIN bash.exe finds GNU coreutils
    # ahead of their System32 namesakes (HIMMEL-1672); then the npm-global bin
    # dir pins `graphify` itself (HIMMEL-1070, updated HIMMEL-1948: graphify,
    # not claude -- neither pair shells claude any more). schtasks fires with a
    # minimal PATH that carries neither by default. Git's dirs come FIRST (GNU
    # tools must win over System32); graphify_dir is appended when present.
    local path_prefix="$git_bin_esc"
    [ -n "$path_prefix" ] && [ -n "$graphify_dir_win_esc" ] && path_prefix="$path_prefix;$graphify_dir_win_esc"
    [ -n "$path_prefix" ] || path_prefix="$graphify_dir_win_esc"
    if [ -n "$path_prefix" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$path_prefix"
    fi
    # Luna's structural leg only (HIMMEL-1948 Task 3): the fence refuses an
    # undeclared backend on graphify's LLM-free `update` for the luna-personal
    # corpus (it cannot see which cloud key graphify would auto-detect).
    # GRAPHIFY_DECLARED_BACKEND=ollama satisfies that declaration in-policy
    # (fence maps ollama -> local-ollama, luna-personal x local-ollama = allow,
    # zero egress) without adding any bypass.
    if [ "$declare_ollama" -eq 1 ]; then
        printf 'set "GRAPHIFY_DECLARED_BACKEND=ollama"\r\n'
    fi
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$himmel_win_esc" "$log_win_esc"
    # `call` (HIMMEL-1389, mirroring #1454's fix in drift-fix-cadence.sh): the
    # payload leads with an absolute interpreter path, and if that ever resolves
    # to a .cmd/.bat shim cmd.exe transfers control into it and never returns —
    # the .bat's own exit path (and anything a later change appends after this
    # line) would silently never run. bash.exe is an .exe today, so this is
    # consistency + future-proofing, not a live outage.
    printf 'call %s >> "%s" 2>&1\r\n' "$payload" "$log_win_esc"
}

# --- schtasks task XML (StartWhenAvailable) --------------------------------
#
# schtasks /create has no flag for StartWhenAvailable ("run as soon as possible
# after a missed scheduled start"), so a daily 13:00 run is SILENTLY SKIPPED if
# the machine was off/asleep at 13:00. The only CLI route is `schtasks /create
# /xml`; we keep the per-task .bat as the Exec Command and wrap it in XML that
# carries StartWhenAvailable=true (same approach as pipeline-cadence, HIMMEL-362).

# Escape the three XML-significant characters for element-body text (the Exec
# <Command> path — a BAT_DIR path may legally contain `&`). `&` first so the `&`
# in the &lt;/&gt; entities isn't re-escaped. sed (not bash ${//}) for a
# version-independent literal-ampersand replacement.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Weekly schedule fragment (semantic pair, HIMMEL-1948): one fixed day/week,
# the given <DaysOfWeek> element name (WEEKLY_DAY_XML, e.g. "Sunday").
schedule_weekly_xml() {
    local day="$1"
    printf '      <ScheduleByWeek>\n        <WeeksInterval>1</WeeksInterval>\n        <DaysOfWeek>\n          <%s/>\n        </DaysOfWeek>\n      </ScheduleByWeek>' "$day"
}

# Hourly-forever schedule fragment (structural/AST pair, HIMMEL-1948 Task 3):
# a daily CalendarTrigger (fires once at StartBoundary's time-of-day, then
# restarts every day). The re-fire-every-hour Repetition lives in
# repetition_xml() below, NOT here — it belongs at the base-type position in
# the trigger (see repetition_xml's comment), earlier than this ScheduleByX
# fragment.
schedule_hourly_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

# Repetition fragment (structural/AST pair only, HIMMEL-1948 CR fix): re-fires
# every hour (PT1H) for a full day (Duration P1D) — the standard Task Scheduler
# XML idiom for "hourly, forever" (schtasks has no bare /sc HOURLY equivalent
# reachable from /xml). StopAtDurationEnd=false: the repetition itself re-arms
# with the next day's CalendarTrigger fire, so the task keeps firing hourly
# indefinitely.
#
# Position matters: calendarTriggerType EXTENDS triggerBaseType, whose
# sequence is Enabled?, StartBoundary?, EndBoundary?, Repetition?,
# ExecutionTimeLimit? — THEN the extension appends RandomDelay? followed by
# the ScheduleByDay|ScheduleByWeek|... choice. Repetition is a base-type
# element and must precede the ScheduleByX fragment in the emitted trigger, or
# `schtasks /create /xml` can reject it. emit_task_xml splices this ahead of
# schedule_xml for that reason. Weekly (semantic) tasks pass no repetition.
repetition_xml() {
    printf '      <Repetition>\n        <Interval>PT1H</Interval>\n        <Duration>P1D</Duration>\n        <StopAtDurationEnd>false</StopAtDurationEnd>\n      </Repetition>'
}

# Emit one task XML: a CalendarTrigger at the given local time, daily schedule,
# StartWhenAvailable=true, and the .bat runner as the Exec Command. StartBoundary
# date is a fixed past sentinel — the schedule fragment (not the date) governs
# firing. repetition_xml (from repetition_xml(), empty for weekly tasks) is
# spliced BEFORE schedule_xml — the base-type element order the CalendarTrigger
# schema requires (see repetition_xml's comment). Declared UTF-16 (what
# schtasks /create /xml expects) but the bytes are plain ASCII — keep it
# ASCII-only (a non-ASCII byte would need a real UTF-16LE+BOM file; declaring
# UTF-8 is rejected on Win11).
emit_task_xml() {
    local bat_win="$1" start_time="$2" schedule_xml="$3" repetition="${4:-}" vbs_win vbs_args
    # HIMMEL-1753: Exec is a `wscript //B <shim>.vbs` wrapper around the .bat.
    # The earlier hidden-powershell wrapper (-WindowStyle Hidden) was MEASURED to
    # still allocate visible consoles; wscript //B hosting the .vbs shim (which
    # runs the .bat hidden via WScript.Shell.Run and forwards its exit code via
    # WScript.Quit) allocates zero consoles. The shim path is derived from the
    # .bat path through cadence_vbs_path — the SAME helper cmd_arm writes the
    # file with — so the referenced path and the written file can never disagree.
    # //B is the WSH batch-mode flag (no error/prompt UI); the path is quoted so
    # a BAT_DIR with spaces survives, then xml_escaped like any element text.
    # WScript.Quit in the shim preserves HIMMEL-1706 exit-code fidelity (rc=42
    # re-arm survives — proven in test-cadence-format.sh).
    vbs_win=$(cadence_vbs_path "$bat_win")
    vbs_args=$(xml_escape "//B \"${vbs_win}\"")
    # Join repetition + schedule_xml with a real newline BEFORE the heredoc:
    # heredoc bodies get parameter expansion but not ANSI-C ($'\n') quote
    # processing, so building the joined newline here (a plain assignment,
    # where $'\n' works normally) keeps the emitted XML one-element-per-line
    # instead of gluing `</Repetition>` and `<ScheduleByDay>` onto one line.
    local trigger_body="$schedule_xml"
    [ -n "$repetition" ] && trigger_body="${repetition}"$'\n'"${schedule_xml}"
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel graphmap-cadence (HIMMEL-829)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2020-01-01T${start_time}:00</StartBoundary>
      <Enabled>true</Enabled>
${trigger_body}
    </CalendarTrigger>
  </Triggers>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>${vbs_args}</Arguments>
    </Exec>
  </Actions>
</Task>
XML
}

# Create one task from an XML definition (so StartWhenAvailable applies). Mirrors
# pipeline-cadence's schtasks_create_xml: self-contained error handling, returns
# the schtasks rc so callers keep the failure/rollback flow.
schtasks_create_xml() {
    local name="$1" schedule_xml="$2" start_time="$3" bat_win="$4" err_file="$5" repetition="${6:-}"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t graphmap-cadence.xml.XXXXXX 2>"$err_file"); then
        return 1
    fi
    emit_task_xml "$bat_win" "$start_time" "$schedule_xml" "$repetition" > "$xml_file"
    if ! xml_win=$(cygpath -w "$xml_file" 2>"$err_file"); then
        rm -f "$xml_file"
        return 1
    fi
    set +e
    run_schtasks /create /tn "$name" /xml "$xml_win" /f 2>"$err_file"
    rc=$?
    set -e
    rm -f "$xml_file"
    return "$rc"
}

# Input validation shared by the schtasks and cron arm paths.
validate_arm_inputs() {
    if ! [[ "$LUNA_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --luna-time must be HH:MM (24h), got: $LUNA_TIME" >&2
        exit 1
    fi
    if ! [[ "$HIMMEL_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --himmel-time must be HH:MM (24h), got: $HIMMEL_TIME" >&2
        exit 1
    fi
    if [ ! -d "$VAULT" ]; then
        echo "ERR graphmap-cadence: --vault is not a directory: $VAULT" >&2
        exit 1
    fi
    if [ ! -f "$REFRESH_SCRIPT" ]; then
        echo "ERR graphmap-cadence: refresh-graph-map.sh not found at $REFRESH_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$AST_UPDATE_SCRIPT" ]; then
        echo "ERR graphmap-cadence: ast-update.sh not found at $AST_UPDATE_SCRIPT" >&2
        exit 2
    fi
    # FAIL FAST on a missing `graphify` (HIMMEL-1070, updated HIMMEL-1948). ALL
    # FOUR tasks need graphify itself on PATH at fire time — the semantic pair
    # via refresh-graph-map.sh (which shells it with --backend $BACKEND), the
    # structural pair via ast-update.sh (`graphify update ...`, CR r1b). Neither pair shells
    # `claude` any more (BACKEND is kimi, not claude-cli). Resolving graphify
    # HERE, at arm time, is what makes the failure visible: cron and schtasks
    # fire with a MINIMAL PATH (no npm-global/cargo bin dir), so without this
    # the arm "succeeds" and the first unattended fire dies in a log nobody
    # reads with "graphify: command not found". The resolved directory is
    # prepended to PATH in BOTH generated runner formats (.sh/.bat).
    if ! GRAPHIFY_BIN=$(command -v graphify 2>/dev/null); then
        {
            echo "ERR graphmap-cadence: 'graphify' not on PATH at arm time, but every armed task shells it at fire time."
            echo "    The scheduler fires with a minimal PATH, so this must resolve HERE — arming now would"
            echo "    produce a cadence that fails on every fire. Install graphify (or put it on PATH)"
            echo "    and re-arm."
        } >&2
        exit 2
    fi
    # `command -v` resolves more than on-PATH executables: a shell FUNCTION or
    # ALIAS resolves to its own name/definition, and a relative PATH entry
    # resolves to a relative path. Either would make GRAPHIFY_DIR meaningless in
    # a runner that has cd'd elsewhere and runs under a different PATH — the
    # exact failure this check exists to prevent, silently reintroduced
    # (CodeRabbit-major on HIMMEL-1070). Demand a real, absolute, executable
    # file (Windows: the `.exe`/`.cmd` a POSIX -x test still accepts under MSYS).
    case "$GRAPHIFY_BIN" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *)
            echo "ERR graphmap-cadence: 'graphify' resolved to a non-absolute path ('$GRAPHIFY_BIN') — a shell function/alias or a relative PATH entry cannot be pinned into a scheduled runner. Install it on PATH as a real executable and re-arm." >&2
            exit 2 ;;
    esac
    if [ ! -f "$GRAPHIFY_BIN" ] || [ ! -x "$GRAPHIFY_BIN" ]; then
        echo "ERR graphmap-cadence: 'graphify' resolved to '$GRAPHIFY_BIN', which is not an executable file — refusing to pin it into a scheduled runner." >&2
        exit 2
    fi
    GRAPHIFY_DIR=$(dirname "$GRAPHIFY_BIN")
    # --ast-only (HIMMEL-2071): the semantic pair is not being armed, so its
    # backend credential is irrelevant here -- requiring it would defeat the
    # whole point of the flag (arm the free legs without the semantic pair's
    # egress/credential ruling).
    [ "$AST_ONLY" -eq 1 ] || validate_backend_credential
}

# FAIL FAST on a missing backend credential (HIMMEL-1960). Sibling of the
# graphify check above and there for the same reason: HIMMEL-1948 switched the
# semantic pair to the `kimi` backend, but nothing verified the credential that
# backend needs, so `arm` could succeed while EVERY weekly semantic run then
# died unattended. An armed-and-inert cadence is worse than a refused arm -- it
# reports ARMED in `status` while producing nothing.
#
# WHAT COUNTS AS PROOF is the whole subtlety here (CR codex-1). A key exported
# into the ARMING shell proves nothing about fire time: cron and Task Scheduler
# start with a minimal environment, and the generated runners deliberately carry
# no secrets (refresh-graph-map.sh re-resolves the key itself when it fires).
# The only source that survives to fire time on its own is the primary
# checkout's .env -- which is the fallback refresh-graph-map.sh already uses. So
# .env is what this checks, in a SUBSHELL with the variable unset, because
# load_dotenv deliberately does not clobber a live non-empty value and would
# otherwise report the arming shell's own export back to us.
#
# A live env var is NOT accepted, on either scheduler. Earlier revisions took
# it with a warning on schtasks, since Task Scheduler does inherit a PERSISTENT
# user/system variable -- but bash cannot tell that apart from a transient
# `export`, and a gate whose only job is to stop a SILENT unattended failure
# must not rest on an unverifiable guess. .env costs the operator one line, in
# the file this repo already keeps such keys in. Env-only -> refuse; nothing at
# all -> refuse.
#
# Only backends that need a key are checked. The structural pair needs none
# (it never calls a model), so this gates the semantic pair alone.
#
# GRAPHMAP_DOTENV_ROOT is a TEST SEAM (sibling of GRAPHMAP_SCHTASKS /
# GRAPHMAP_CRONTAB / GRAPHMAP_BAT_DIR): it pins which .env is consulted so the
# suite can assert both outcomes without depending on whether the operator's
# real .env happens to carry the key. It is honoured ONLY alongside a fake
# scheduler, so a real arm can never reach it; set in production it is ignored
# and says so.
validate_backend_credential() {
    local key_var=""
    # Every backend refresh-graph-map.sh can be handed, classified. `BACKEND`
    # is a fixed constant in this script today (kimi) with no flag to change
    # it, so only that row is live -- but the default branch used to `return 0`
    # SILENTLY, which meant a future one-word edit to BACKEND would have
    # switched the gate off without a word (CR r3 codex-1). An unclassified
    # backend now says so instead of quietly passing: this whole check exists
    # because a credential problem that stays silent becomes an armed-and-inert
    # cadence.
    case "$BACKEND" in
        kimi|moonshot) key_var="MOONSHOT_API_KEY" ;;
        glm|zai-glm)   key_var="ZAI_API_KEY" ;;
        deepseek)      key_var="DEEPSEEK_API_KEY" ;;
        # Subscription/local backends need no API key at arm time: claude-cli
        # uses the operator's own Claude Code auth, ollama is local.
        claude|claude-cli|ollama) return 0 ;;
        # Fail CLOSED on anything unclassified (CR r4). A warning here would be
        # read at arm time and forgotten; the cadence it permits fails silently
        # weeks later, which is the whole failure mode this gate exists for. A
        # refusal instead forces whoever changes BACKEND to classify the new
        # provider in the same edit — the cost today is zero, because the only
        # value BACKEND can hold is classified above.
        *)
            {
                echo "ERR graphmap-cadence: backend '$BACKEND' is not classified by the arm-time credential check, so arming cannot verify it will reach its provider unattended."
                echo "    Add it to validate_backend_credential (with its API-key variable, or as credential-free) and re-arm."
            } >&2
            exit 2 ;;
    esac

    if credential_in_dotenv "$key_var"; then
        return 0
    fi

    # A live env var is NOT accepted as proof, on EITHER scheduler (CR r5).
    # Earlier revisions of this check tried to be clever about it: accept it
    # with a warning on schtasks (Task Scheduler DOES inherit persistent
    # user/system variables) and refuse on cron (which does not). But "is this
    # export persistent?" is exactly the question bash cannot answer here, and
    # a gate whose whole purpose is to stop a SILENT unattended failure must
    # not itself rest on an unverifiable guess.
    #
    # .env needs no guessing: refresh-graph-map.sh loads it at fire time on
    # both platforms (that is where its own MOONSHOT_API_KEY fallback reads
    # from), so a key present there provably reaches the run. An operator who
    # keeps the key in a persistent environment variable loses nothing by also
    # putting it in .env, which is where this repo keeps such keys anyway --
    # a one-line workaround against a failure that would otherwise surface
    # weeks later, in a log nobody reads.
    {
        echo "ERR graphmap-cadence: the semantic pair runs on the '$BACKEND' backend, which needs $key_var, but it is not in the primary checkout's .env."
        echo "    Arming now would register tasks that report ARMED while every weekly semantic run fails unattended."
        echo "    A value exported in THIS shell is deliberately not accepted: the schedulers start with their own"
        echo "    environment and the generated runners carry no secrets, so it cannot be shown to reach the run."
        echo "    Put $key_var in .env — the source refresh-graph-map.sh reads at fire time — and re-arm."
        echo "    The structural/AST pair needs no credential."
    } >&2
    exit 2
}

# True when <key> is readable from the .env that will still be there at fire
# time. Runs in a SUBSHELL with the key unset so load_dotenv's non-clobbering
# behaviour cannot mistake this shell's own export for a .env hit, and so the
# probe never leaks a value into the arming shell. The value is never printed.
credential_in_dotenv() {
    local key_var="$1"
    # A seam that can satisfy a SAFETY gate must never do so silently (CR r7).
    # GRAPHMAP_DOTENV_ROOT points this check at a different .env than the one
    # scheduled runs read, so with it set an arm can pass while the real
    # primary-checkout credential is missing -- the precise armed-and-inert
    # outcome this gate exists to prevent, reached through the gate's own test
    # hook. It stays (the suite needs both outcomes deterministically), but it
    # announces itself, so a redirected verdict can never be mistaken for a
    # verified one.
    # The seam is honoured ONLY inside the hermetic suite (CR r8). Warning was
    # not enough: an unrestricted override that can satisfy this gate IS the
    # armed-and-inert failure, just with a note attached. A real arm registers
    # against the real scheduler, so it never sets GRAPHMAP_SCHTASKS or
    # GRAPHMAP_CRONTAB; requiring one of those present makes the redirect
    # unreachable in production while leaving the suite (which always sets one)
    # exactly as deterministic as before. Set in production it is IGNORED, and
    # says so -- never silently obeyed, never silently dropped.
    local dotenv_root=""
    if [ -n "${GRAPHMAP_DOTENV_ROOT:-}" ]; then
        # THREE conditions, none of which a production arm sets (CR r11/r12).
        # Presence of a scheduler seam was too weak (GRAPHMAP_SCHTASKS=schtasks
        # names the REAL scheduler and would register real tasks); requiring it
        # to be a file on disk was better but an absolute path to the real
        # scheduler, or a forwarding wrapper, still satisfies it. So the
        # redirect also needs GRAPHMAP_TEST_MODE=1 -- a variable whose only
        # purpose is to say "this is the hermetic suite", which nothing else
        # sets and no legitimate value coincides with.
        #
        # This bounds MISTAKES, which is what the gate is for: no forgotten
        # credential slips through because a variable happened to be set. An
        # operator who deliberately exports three variables to defeat their own
        # arm-time check still can, and no environment-variable scheme fixes
        # that -- it is out of scope, stated rather than papered over.
        if [ "${GRAPHMAP_TEST_MODE:-}" = "1" ] \
           && { [ -f "${GRAPHMAP_SCHTASKS:-}" ] || [ -f "${GRAPHMAP_CRONTAB:-}" ]; }; then
            dotenv_root="$GRAPHMAP_DOTENV_ROOT"
        else
            echo "WARN graphmap-cadence: GRAPHMAP_DOTENV_ROOT is set but IGNORED -- it is a test seam, honoured only alongside a fake scheduler (GRAPHMAP_SCHTASKS/GRAPHMAP_CRONTAB). The credential check is reading the primary checkout's .env, as a real arm must." >&2
        fi
    fi
    (
        unset "$key_var"
        # shellcheck source=../lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh" >/dev/null 2>&1 || exit 1
        if [ -n "$dotenv_root" ]; then
            load_dotenv --root "$dotenv_root" "$key_var" >/dev/null 2>&1 || exit 1
        else
            load_dotenv "$key_var" >/dev/null 2>&1 || exit 1
        fi
        [ -n "${!key_var:-}" ]
    )
}

cmd_arm() {
    validate_arm_inputs
    cadence_require_wsh "graphmap-cadence" || exit 2

    # Resolve bash to an absolute Windows path so the .bat invokes the Git-Bash
    # interpreter directly — NOT the bare `bash` that resolves to the WSL
    # System32 stub in a fresh cmd.exe.
    local bash_posix bash_win
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR graphmap-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR graphmap-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi

    # bash consumes these paths (POSIX/mixed C:/ form via cygpath -m, which
    # Git-Bash reads); the himmel cd target is a Windows path.
    local script_mixed ast_script_mixed vault_mixed maps_mixed himmel_mixed himmel_win
    if ! script_mixed=$(cygpath -m "$REFRESH_SCRIPT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for refresh script: $script_mixed" >&2
        exit 4
    fi
    if ! ast_script_mixed=$(cygpath -m "$AST_UPDATE_SCRIPT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for ast-update script: $ast_script_mixed" >&2
        exit 4
    fi
    if ! vault_mixed=$(cygpath -m "$VAULT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for vault path: $vault_mixed" >&2
        exit 4
    fi
    if ! maps_mixed=$(cygpath -m "$VAULT/60-Maps" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for maps dir: $maps_mixed" >&2
        exit 4
    fi
    if ! himmel_mixed=$(cygpath -m "$HIMMEL_ROOT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for himmel root: $himmel_mixed" >&2
        exit 4
    fi
    if ! himmel_win=$(cygpath -w "$HIMMEL_ROOT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for himmel root: $himmel_win" >&2
        exit 4
    fi
    # Same trailing-separator normalization as pipeline-cadence.sh's vault path
    # (public-PR CR, secondary site) — see the long note there for why this is
    # done at the source rather than in the shared cadence_cmd_escape, and for
    # the measurement showing cmd.exe does NOT consume the `\"` as an escape.
    # Lower probability here: HIMMEL_ROOT is resolved via `cd … && pwd`, which
    # does not produce a trailing separator. Normalized anyway so the two `cd /d`
    # emitters answer the question identically instead of one of them relying on
    # its input happening to be well-shaped.
    # A DRIVE ROOT keeps its separator: `cd /d "C:\"` is the root of C:, while
    # `cd /d "C:"` is the current directory on C:.
    while :; do
        case "$himmel_win" in
            [A-Za-z]:\\) break ;;
            *\\)         himmel_win="${himmel_win%\\}" ;;
            *)           break ;;
        esac
    done

    # Dedup guard — never double-register the cadence. --ast-only (HIMMEL-2071)
    # scopes both the dedup check AND --force's replacement to the two AST
    # tasks only — an already-armed semantic pair must survive an --ast-only
    # (re-)arm untouched, never dedup-blocked on and never deleted by it.
    local existing
    existing=$(list_existing)
    if [ "$AST_ONLY" -eq 1 ]; then
        existing=$(printf '%s\n' "$existing" | grep -xE "(${TASK_AST_LUNA}|${TASK_AST_HIMMEL})" || true)
    fi
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "graphmap-cadence: --force set; replacing existing task(s):" >&2
            local marker
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "  $marker" >&2
                if [ "$DRY_RUN" -eq 0 ]; then
                    delete_task "$marker"
                else
                    echo "DRY graphmap-cadence: would delete $marker"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR graphmap-cadence: HIMMEL-GraphMap-* task(s) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/graphmap-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    # cmd-escape the path values interpolated into each .bat payload.
    local script_esc ast_script_esc vault_esc maps_esc himmel_esc himmel_win_esc graphify_dir_win graphify_dir_win_esc
    if ! graphify_dir_win=$(cygpath -w "$GRAPHIFY_DIR" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for graphify dir: $graphify_dir_win" >&2
        exit 4
    fi
    graphify_dir_win_esc=$(cadence_cmd_escape "$graphify_dir_win")
    script_esc=$(cadence_cmd_escape "$script_mixed")
    ast_script_esc=$(cadence_cmd_escape "$ast_script_mixed")
    vault_esc=$(cadence_cmd_escape "$vault_mixed")
    maps_esc=$(cadence_cmd_escape "$maps_mixed")
    himmel_esc=$(cadence_cmd_escape "$himmel_mixed")
    himmel_win_esc=$(cadence_cmd_escape "$himmel_win")

    # Per-corpus payloads. NOTE the asymmetric --corpus-root: the luna map
    # extracts the VAULT ($vault_esc); the himmel map extracts the HIMMEL REPO
    # ($himmel_esc, so its derived graphify-out stays repo-local + gitignored) —
    # but BOTH publish their curated MOC into the luna vault's 60-Maps ($maps_esc).
    # The luna vault is the single home for every map; the cross-corpus mix here
    # is intentional, not a copy-paste bug (HIMMEL-829 wiring decision).
    local payload_luna payload_himmel
    payload_luna=$(bat_payload "$script_esc" luna "$vault_esc" "$maps_esc" "$LUNA_TITLE" "$LUNA_SLUG" "$LUNA_TAG")
    payload_himmel=$(bat_payload "$script_esc" himmel "$himmel_esc" "$maps_esc" "$HIMMEL_TITLE" "$HIMMEL_SLUG" "$HIMMEL_TAG")
    # Both .bats get the bash exe prepended; assemble the full exec line.
    # bash_win is cmd-escaped like every other interpolated value (HIMMEL-1281
    # CR round 1). It used to go in raw — a documented divergence from the qmd
    # sibling, but the wrong side of it: a `%` anywhere in the resolved
    # interpreter path would be expanded by cmd.exe at fire time instead of
    # taken literally, and it is inside quotes exactly like the rest.
    local bash_win_esc
    bash_win_esc=$(cadence_cmd_escape "$bash_win")
    payload_luna="\"$bash_win_esc\" $payload_luna"
    payload_himmel="\"$bash_win_esc\" $payload_himmel"
    # Structural (AST) payloads (HIMMEL-1948 Task 3, routed through the
    # promote-lock wrapper as of CR r1b): ast-update.sh IS a bash script, so
    # (unlike the old bare `graphify` call) it gets the same bash prefix as
    # the semantic pair. Same asymmetric corpus roots as the semantic pair:
    # luna = vault, himmel = repo.
    local payload_ast_luna payload_ast_himmel
    payload_ast_luna=$(ast_bat_payload "$ast_script_esc" "$vault_esc")
    payload_ast_himmel=$(ast_bat_payload "$ast_script_esc" "$himmel_esc")
    payload_ast_luna="\"$bash_win_esc\" $payload_ast_luna"
    payload_ast_himmel="\"$bash_win_esc\" $payload_ast_himmel"
    # Git's usr\bin + bin, derived from the bash.exe path above (HIMMEL-1672):
    # prepended to PATH in emit_bat so the non-login bash.exe finds GNU coreutils
    # ahead of System32. Empty for a non-Git bash → emit_bat then omits the line.
    local git_bin_esc
    git_bin_esc=$(cadence_cmd_escape "$(cadence_git_bin_path_win "$bash_win")")

    local bat_luna="$BAT_DIR/graphmap-luna.bat"
    local bat_himmel="$BAT_DIR/graphmap-himmel.bat"
    local bat_ast_luna="$BAT_DIR/graphmap-ast-luna.bat"
    local bat_ast_himmel="$BAT_DIR/graphmap-ast-himmel.bat"
    # wscript //B shims (HIMMEL-1753) live beside their .bats; disarm removes
    # both together. Derived from the .bat Windows path through cadence_vbs_path
    # — the same helper emit_task_xml derives the referenced path with.
    local vbs_luna="$BAT_DIR/graphmap-luna.vbs"
    local vbs_himmel="$BAT_DIR/graphmap-himmel.vbs"
    local vbs_ast_luna="$BAT_DIR/graphmap-ast-luna.vbs"
    local vbs_ast_himmel="$BAT_DIR/graphmap-ast-himmel.vbs"

    # Fire-time run logs live next to the .bats (cmd-escaped for the `>>` target).
    local bat_dir_win log_luna_esc log_himmel_esc log_ast_luna_esc log_ast_himmel_esc
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    log_luna_esc=$(cadence_cmd_escape "$bat_dir_win\\graphmap-luna.log")
    log_himmel_esc=$(cadence_cmd_escape "$bat_dir_win\\graphmap-himmel.log")
    log_ast_luna_esc=$(cadence_cmd_escape "$bat_dir_win\\graphmap-ast-luna.log")
    log_ast_himmel_esc=$(cadence_cmd_escape "$bat_dir_win\\graphmap-ast-himmel.log")

    # The .bat runner is the task's Exec Command. cygpath -w is a pure string
    # transform (the .bat need not exist yet), so resolve the win paths before
    # the dry-run preview too.
    local bat_luna_win bat_himmel_win bat_ast_luna_win bat_ast_himmel_win
    if ! bat_luna_win=$(cygpath -w "$bat_luna" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_luna_win" >&2
        exit 4
    fi
    if ! bat_himmel_win=$(cygpath -w "$bat_himmel" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_himmel_win" >&2
        exit 4
    fi
    if ! bat_ast_luna_win=$(cygpath -w "$bat_ast_luna" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_ast_luna_win" >&2
        exit 4
    fi
    if ! bat_ast_himmel_win=$(cygpath -w "$bat_ast_himmel" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_ast_himmel_win" >&2
        exit 4
    fi

    local sched_semantic sched_ast rep_ast
    sched_semantic=$(schedule_weekly_xml "$WEEKLY_DAY_XML")
    sched_ast=$(schedule_hourly_xml)
    rep_ast=$(repetition_xml)

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$AST_ONLY" -eq 1 ]; then
            echo "DRY graphmap-cadence: --ast-only set; the semantic pair ($TASK_LUNA / $TASK_HIMMEL) is skipped entirely"
        else
            echo "DRY graphmap-cadence: would write $bat_luna:"
            emit_bat "$himmel_win_esc" "$payload_luna" "$log_luna_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 | sed 's/^/    /'
            echo "DRY graphmap-cadence: would write $vbs_luna:"
            cadence_vbs_wrapper "$bat_luna_win" | sed 's/^/    /'
            echo "DRY graphmap-cadence: would write $bat_himmel:"
            emit_bat "$himmel_win_esc" "$payload_himmel" "$log_himmel_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 | sed 's/^/    /'
            echo "DRY graphmap-cadence: would write $vbs_himmel:"
            cadence_vbs_wrapper "$bat_himmel_win" | sed 's/^/    /'
            echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_LUNA /xml <weekly $WEEKLY_DAY_XML $LUNA_TIME, StartWhenAvailable=true> /f"
            emit_task_xml "$bat_luna_win" "$LUNA_TIME" "$sched_semantic" | sed 's/^/    /'
            echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_HIMMEL /xml <weekly $WEEKLY_DAY_XML $HIMMEL_TIME, StartWhenAvailable=true> /f"
            emit_task_xml "$bat_himmel_win" "$HIMMEL_TIME" "$sched_semantic" | sed 's/^/    /'
        fi
        echo "DRY graphmap-cadence: would write $bat_ast_luna:"
        emit_bat "$himmel_win_esc" "$payload_ast_luna" "$log_ast_luna_esc" "$graphify_dir_win_esc" "$git_bin_esc" 1 | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $vbs_ast_luna:"
        cadence_vbs_wrapper "$bat_ast_luna_win" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $bat_ast_himmel:"
        emit_bat "$himmel_win_esc" "$payload_ast_himmel" "$log_ast_himmel_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $vbs_ast_himmel:"
        cadence_vbs_wrapper "$bat_ast_himmel_win" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_AST_LUNA /xml <daily at $AST_LUNA_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_ast_luna_win" "$AST_LUNA_TIME" "$sched_ast" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_AST_HIMMEL /xml <hourly from $AST_HIMMEL_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_ast_himmel_win" "$AST_HIMMEL_TIME" "$sched_ast" "$rep_ast" | sed 's/^/    /'
        echo "graphmap-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Atomic runner publication (HIMMEL-1753 round 2, glm-3): every runner .bat
    # and .vbs shim is emitted to a staged temp BESIDE its final path (same dir
    # -> same filesystem -> `mv` is an atomic rename, not a copy) and promoted
    # only once complete, mirroring codex-sweep-cadence's publish discipline.
    # Redirecting straight onto the FINAL path let a task firing concurrently
    # with a re-arm read a half-written shim; after the rename the final path
    # only ever holds a complete file (old or new). Shims promote first (an
    # already-armed task can safely run a new shim against the still-current
    # .bat mid-replacement), and every promotion is CHECKED — a failed one
    # aborts the arm BEFORE any task is registered, with the staged temps
    # cleaned. A non-regular final path is refused too: `mv` onto a directory
    # squatting on a runner name "succeeds" by moving the staged file INSIDE
    # it, arming a task at a path that is not a file.
    local tmp_luna_bat tmp_himmel_bat tmp_luna_vbs tmp_himmel_vbs
    local tmp_ast_luna_bat tmp_ast_himmel_bat tmp_ast_luna_vbs tmp_ast_himmel_vbs
    tmp_ast_luna_bat=$(mktemp "$BAT_DIR/.graphmap-ast-luna.bat.XXXXXX")
    tmp_ast_himmel_bat=$(mktemp "$BAT_DIR/.graphmap-ast-himmel.bat.XXXXXX")
    tmp_ast_luna_vbs=$(mktemp "$BAT_DIR/.graphmap-ast-luna.vbs.XXXXXX")
    tmp_ast_himmel_vbs=$(mktemp "$BAT_DIR/.graphmap-ast-himmel.vbs.XXXXXX")
    emit_bat "$himmel_win_esc" "$payload_ast_luna" "$log_ast_luna_esc" "$graphify_dir_win_esc" "$git_bin_esc" 1 > "$tmp_ast_luna_bat"
    emit_bat "$himmel_win_esc" "$payload_ast_himmel" "$log_ast_himmel_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 > "$tmp_ast_himmel_bat"
    cadence_vbs_wrapper "$bat_ast_luna_win" > "$tmp_ast_luna_vbs"
    cadence_vbs_wrapper "$bat_ast_himmel_win" > "$tmp_ast_himmel_vbs"
    local promote_src promote_dst idx
    promote_src=("$tmp_ast_luna_vbs" "$tmp_ast_himmel_vbs" "$tmp_ast_luna_bat" "$tmp_ast_himmel_bat")
    promote_dst=("$vbs_ast_luna" "$vbs_ast_himmel" "$bat_ast_luna" "$bat_ast_himmel")
    # --ast-only (HIMMEL-2071): the semantic pair's runner files are neither
    # built nor promoted — leaving them absent (or untouched, on a re-arm that
    # left an earlier semantic pair's files on disk) is exactly "the semantic
    # tasks stay absent/disabled": no orphaned runner ever gets registered as
    # a task, and any PRE-EXISTING semantic runner keeps serving its own
    # still-armed task undisturbed.
    if [ "$AST_ONLY" -eq 0 ]; then
        tmp_luna_bat=$(mktemp "$BAT_DIR/.graphmap-luna.bat.XXXXXX")
        tmp_himmel_bat=$(mktemp "$BAT_DIR/.graphmap-himmel.bat.XXXXXX")
        tmp_luna_vbs=$(mktemp "$BAT_DIR/.graphmap-luna.vbs.XXXXXX")
        tmp_himmel_vbs=$(mktemp "$BAT_DIR/.graphmap-himmel.vbs.XXXXXX")
        emit_bat "$himmel_win_esc" "$payload_luna" "$log_luna_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 > "$tmp_luna_bat"
        emit_bat "$himmel_win_esc" "$payload_himmel" "$log_himmel_esc" "$graphify_dir_win_esc" "$git_bin_esc" 0 > "$tmp_himmel_bat"
        cadence_vbs_wrapper "$bat_luna_win" > "$tmp_luna_vbs"
        cadence_vbs_wrapper "$bat_himmel_win" > "$tmp_himmel_vbs"
        promote_src+=("$tmp_luna_vbs" "$tmp_himmel_vbs" "$tmp_luna_bat" "$tmp_himmel_bat")
        promote_dst+=("$vbs_luna" "$vbs_himmel" "$bat_luna" "$bat_himmel")
    fi
    for idx in "${!promote_dst[@]}"; do
        if [ -e "${promote_dst[$idx]}" ] && [ ! -f "${promote_dst[$idx]}" ]; then
            echo "ERR graphmap-cadence: ${promote_dst[$idx]} exists and is not a regular file — refusing to publish" >&2
            rm -f "${promote_src[@]}"
            exit 4
        fi
        if ! mv -f "${promote_src[$idx]}" "${promote_dst[$idx]}"; then
            echo "ERR graphmap-cadence: failed to publish runner to ${promote_dst[$idx]} — NO task armed" >&2
            rm -f "${promote_src[@]}"
            exit 4
        fi
    done

    # Create the AST tasks always, the semantic pair only without --ast-only.
    # Rolls back every task that DID register if a later /create fails
    # (generalized from the original 2-task hand-rolled rollback so
    # status/dedup stay truthful no matter which task fails, HIMMEL-1948
    # Task 3; --ast-only, HIMMEL-2071, just shrinks the array to two).
    local create_names=("$TASK_AST_LUNA" "$TASK_AST_HIMMEL")
    local create_scheds=("$sched_ast" "$sched_ast")
    local create_times=("$AST_LUNA_TIME" "$AST_HIMMEL_TIME")
    local create_bats=("$bat_ast_luna_win" "$bat_ast_himmel_win")
    # HIMMEL-1960 (operator decision (a)): only the HIMMEL corpus gets the
    # hourly Repetition. luna's AST leg keeps the same daily CalendarTrigger
    # with NO repetition, i.e. it fires once a day instead of 24 times. Both
    # AST legs share sched_ast (a plain ScheduleByDay) -- hourliness lives
    # entirely in rep_ast, so "lower cadence for luna" is the absence of it.
    local create_reps=("" "$rep_ast")
    if [ "$AST_ONLY" -eq 0 ]; then
        create_names=("$TASK_LUNA" "$TASK_HIMMEL" "${create_names[@]}")
        create_scheds=("$sched_semantic" "$sched_semantic" "${create_scheds[@]}")
        create_times=("$LUNA_TIME" "$HIMMEL_TIME" "${create_times[@]}")
        create_bats=("$bat_luna_win" "$bat_himmel_win" "${create_bats[@]}")
        create_reps=("" "" "${create_reps[@]}")
    fi
    local created=() ci err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    for ci in "${!create_names[@]}"; do
        if ! schtasks_create_xml "${create_names[$ci]}" "${create_scheds[$ci]}" "${create_times[$ci]}" "${create_bats[$ci]}" "$err_file" "${create_reps[$ci]}"; then
            echo "ERR graphmap-cadence: schtasks /create ${create_names[$ci]} failed:" >&2
            cat "$err_file" >&2
            local rb
            # ${created[@]+"${created[@]}"} -- empty-array guard: under
            # `set -u` on bash < 4.4 (this repo's floor is 3.2, HIMMEL-1948
            # CR), expanding "${created[@]}" when created is still empty
            # (the FIRST /create failed, so nothing was ever appended) is an
            # unbound-variable error that aborts this rollback path before
            # `rm -f "$err_file"` and before the deliberate `exit 4` below --
            # surfacing the wrong exit code and leaking the temp file.
            for rb in "${created[@]+"${created[@]}"}"; do
                if ! run_schtasks /delete /tn "$rb" /f >/dev/null 2>&1; then
                    echo "WARN: rollback of $rb failed — run disarm" >&2
                fi
            done
            rm -f "$err_file"
            exit 4
        fi
        if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
        created+=("${create_names[$ci]}")
    done
    rm -f "$err_file"

    # HIMMEL-1680: register every task this arm actually created so absence
    # (a silently vanished scheduled task) is detectable via the registry's
    # expected-but-absent report. AST pair is unconditional (created on
    # every arm, --ast-only or not); the semantic pair only when this arm
    # created it.
    if [ "$AST_ONLY" -eq 0 ]; then
        # weekly (604800s), not daily -- these are the semantic pair (codex-1,
        # HIMMEL-1680 CR): a wrong cadence here would make future
        # cadence-based staleness tooling flag a healthy weekly job as
        # stalled every day it hasn't fired.
        observability_register_cadence graphmap-luna 604800 "$TASK_LUNA"
        observability_register_cadence graphmap-himmel 604800 "$TASK_HIMMEL"
    fi
    observability_register_cadence graphmap-ast-luna 86400 "$TASK_AST_LUNA"
    observability_register_cadence graphmap-ast-himmel 3600 "$TASK_AST_HIMMEL"

    local semantic_lines arming_note
    if [ "$AST_ONLY" -eq 1 ]; then
        # codex-1, HIMMEL-2071 CR round 1: an --ast-only (re-)arm never
        # touches the semantic pair, but it can already be armed from an
        # EARLIER full arm — report its REAL scheduler state, not a blanket
        # "NOT armed" that would be a false negative in that case.
        # codex-1, CR round 2 (Suggestion): don't restate this arm's $BACKEND/
        # $LUNA_TIME/$HIMMEL_TIME for a task this run never touched — a
        # pre-existing task may have been armed with different values (e.g.
        # a since-changed BACKEND). Point at `status` for its real config
        # instead of guessing.
        local luna_qrc=0 himmel_qrc=0 luna_line himmel_line
        query_one "$TASK_LUNA" || luna_qrc=$?
        if [ "$luna_qrc" -eq 0 ]; then
            luna_line="  $TASK_LUNA       already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            luna_line="  $TASK_LUNA       NOT armed (--ast-only)"
        fi
        query_one "$TASK_HIMMEL" || himmel_qrc=$?
        if [ "$himmel_qrc" -eq 0 ]; then
            himmel_line="  $TASK_HIMMEL     already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            himmel_line="  $TASK_HIMMEL     NOT armed (--ast-only)"
        fi
        semantic_lines="$luna_line
$himmel_line"
        arming_note="  --ast-only arms/replaces only the free structural pair; a pre-existing
  semantic pair (if shown above) is left byte-identical. Re-arm without
  --ast-only to add a missing semantic pair (--force to replace)."
    else
        semantic_lines="  $TASK_LUNA       weekly $WEEKLY_DAY_XML $LUNA_TIME   -> refresh-graph-map luna (semantic, $BACKEND)
  $TASK_HIMMEL     weekly $WEEKLY_DAY_XML $HIMMEL_TIME   -> refresh-graph-map himmel (semantic, $BACKEND)"
        arming_note="  Arming = weekly semantic graphify extraction on the $BACKEND backend
  (off the interactive Anthropic bank) + free structural refresh
  (himmel hourly, luna daily);"
    fi
    cat <<EOF

================================================================
  GRAPHMAP CADENCE ARMED (HIMMEL-829, inverted HIMMEL-1948)
$semantic_lines
  $TASK_AST_LUNA    daily $AST_LUNA_TIME   -> graphify update luna (structural, free)
  $TASK_AST_HIMMEL  hourly from $AST_HIMMEL_TIME   -> graphify update himmel (structural, free)
  Vault: $VAULT   (maps -> 60-Maps/)
  Himmel: $HIMMEL_ROOT
  Runner .bats: $BAT_DIR

  No task ever opens a claude session. StartWhenAvailable=true: a run
  missed because the PC was off/asleep fires when the PC is next on.
$arming_note
  disarm anytime with:
      bash scripts/luna/graphmap-cadence.sh disarm
================================================================
EOF
}

# --- POSIX (cron) implementation -------------------------------------------
#
# Same arm/status/disarm contract as the schtasks path, against the user
# crontab. Both cadence entries live in ONE crontab rewrite (snapshot -> filter
# -> append -> install), so there is no half-armed state to roll back. Runner
# .sh files mirror the .bat runners: log rotation, fire stamp, cd-into-himmel,
# then bash + refresh-graph-map.sh.

CRON_RUNNER_LUNA="$BAT_DIR/graphmap-luna.sh"
CRON_RUNNER_HIMMEL="$BAT_DIR/graphmap-himmel.sh"
CRON_RUNNER_AST_LUNA="$BAT_DIR/graphmap-ast-luna.sh"
CRON_RUNNER_AST_HIMMEL="$BAT_DIR/graphmap-ast-himmel.sh"

# Shell-quote a value for a cron command line (mirrors pipeline-cadence
# cron_escape): printf %q survives the /bin/sh re-parse; the extra % -> \% pass
# is cron(5) syntax. Control characters are rejected (rc=2).
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR graphmap-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into CRON_TAB. Fail-CLOSED like list_existing.
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR graphmap-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
            cat "$err_file" >&2
            echo "    Non-vixie crons (busybox, Solaris) phrase 'no crontab yet' differently;" >&2
            echo "    if that is what tripped this, install an empty crontab to unblock:" >&2
            echo "        crontab - </dev/null" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
}

# Install a new crontab from the given file. Returns 4 on failure; the rejected
# tab is kept for forensics.
cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR graphmap-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    rejected crontab left at: $tab_file" >&2
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged cadence lines in the current CRON_TAB (empty if none). Every
# entry this script writes carries a trailing "# <task-name>" comment (see
# entry_luna et al below); matching on that comment anchored at end-of-line
# against TASK_MATCH_RE (the four owned names, HIMMEL-1948 CR r2) means an
# operator's own unrelated "# HIMMEL-GraphMap*" entry is never swept up.
cron_existing() {
    printf '%s\n' "$CRON_TAB" | grep -E "# ${TASK_MATCH_RE}\$" || true
}

# Build the argv the runner .sh hands to /bin/sh: bash + refresh-graph-map.sh +
# flags. bash/script/corpus/maps/title arrive pre-quoted (printf %q);
# name/slug/tag/backend are fixed ASCII literals.
cron_payload() {
    local q_bash="$1" q_script="$2" name="$3" q_corpus="$4" q_maps="$5" q_title="$6" slug="$7" tag="$8"
    printf '%s %s --name %s --corpus-root %s --maps-dir %s --title %s --slug %s --backend %s --corpus-tag %s' \
        "$q_bash" "$q_script" "$name" "$q_corpus" "$q_maps" "$q_title" "$slug" "$BACKEND" "$tag"
}

# Structural (AST) payload builder, POSIX form (HIMMEL-1948 Task 3, routed
# through the promote-lock wrapper as of CR r1b): bash + ast-update.sh +
# corpus-root. q_bash/q_script/q_corpus arrive pre-quoted (printf %q).
# Mirrors ast_bat_payload's rationale -- --force now lives INSIDE
# ast-update.sh, not on this command line.
ast_cron_payload() {
    local q_bash="$1" q_script="$2" q_corpus="$3"
    printf '%s %s %s' "$q_bash" "$q_script" "$q_corpus"
}

# Emit the runner .sh body for one cadence task: stamp the format version,
# rotate the run log, stamp the fire time, cd into the himmel root, then fire the
# payload with output captured to the log. PATH prepends for nvm-managed node
# (refresh-graph-map.sh calls node, semantic pair only — q_node_dir is empty
# for the structural pair) and for `graphify` itself (updated HIMMEL-1948:
# every task needs graphify on PATH; neither pair shells claude any more)
# under cron's minimal PATH. The two dirs are frequently the same bin dir — a
# duplicate PATH entry is harmless, so they are emitted independently rather
# than deduped.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh
emit_runner() {
    local name="$1" payload="$2" q_log="$3" q_himmel="$4" q_node_dir="${5:-}" q_graphify_dir="${6:-}" declare_ollama="${7:-0}"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by graphmap-cadence.sh arm (HIMMEL-829)\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    if [ -n "$q_node_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_node_dir"
    fi
    if [ -n "$q_graphify_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_graphify_dir"
    fi
    # Luna's structural leg only (HIMMEL-1948 Task 3) — see emit_bat's identical
    # rationale: satisfies the fence's LLM-free-subcommand backend declaration
    # requirement in-policy (ollama -> local-ollama, luna-personal x
    # local-ollama = allow, zero egress).
    if [ "$declare_ollama" -eq 1 ]; then
        printf 'export GRAPHIFY_DECLARED_BACKEND=ollama\n'
    fi
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    printf '    _rc=0; %s || _rc=$?\n' "$payload"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
}

cron_status() {
    cron_read
    echo "graphmap-cadence status:"
    local name log entry sched
    for name in "$TASK_LUNA" "$TASK_HIMMEL" "$TASK_AST_LUNA" "$TASK_AST_HIMMEL"; do
        case "$name" in
            "$TASK_LUNA")       log="$BAT_DIR/graphmap-luna.log" ;;
            "$TASK_HIMMEL")     log="$BAT_DIR/graphmap-himmel.log" ;;
            "$TASK_AST_LUNA")   log="$BAT_DIR/graphmap-ast-luna.log" ;;
            "$TASK_AST_HIMMEL") log="$BAT_DIR/graphmap-ast-himmel.log" ;;
        esac
        entry=$(printf '%s\n' "$CRON_TAB" | grep -E "# ${name}\$" | head -1 || true)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            echo "ARMED      $name (cron: $sched)$(task_summary "$name")"
        else
            echo "not armed  $name$(task_summary "$name")"
        fi
        status_log "$log"
    done
}

cron_disarm() {
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL" "$CRON_RUNNER_AST_LUNA" "$CRON_RUNNER_AST_HIMMEL"
        fi
        echo "graphmap-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY graphmap-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY graphmap-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vE "# ${TASK_MATCH_RE}\$" > "$newtab" || true
    # Install must succeed BEFORE the runners are removed — a failed install
    # leaves the entries live and they must keep pointing at existing runners.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL" "$CRON_RUNNER_AST_LUNA" "$CRON_RUNNER_AST_HIMMEL"
    observability_unregister_cadence graphmap-luna "$TASK_LUNA"
    observability_unregister_cadence graphmap-himmel "$TASK_HIMMEL"
    observability_unregister_cadence graphmap-ast-luna "$TASK_AST_LUNA"
    observability_unregister_cadence graphmap-ast-himmel "$TASK_AST_HIMMEL"
    echo "graphmap-cadence: cadence disarmed"
}

cron_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute path so the runner doesn't depend on cron's
    # minimal PATH. Capture node's directory so the runner can prepend it (nvm
    # node won't be in cron's PATH; refresh-graph-map.sh needs node).
    local bash_bin node_dir node_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR graphmap-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then
        node_dir=$(dirname "$node_bin")
    fi

    # Dedup guard — never double-register the cadence. --ast-only (HIMMEL-2071)
    # scopes both the dedup check AND --force's replacement to the two AST
    # entries only — a pre-existing semantic pair survives an --ast-only
    # (re-)arm untouched.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ "$AST_ONLY" -eq 1 ]; then
        existing=$(printf '%s\n' "$existing" | grep -E "# (${TASK_AST_LUNA}|${TASK_AST_HIMMEL})\$" || true)
    fi
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "graphmap-cadence: --force set; replacing existing cadence entries:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY graphmap-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR graphmap-cadence: HIMMEL-GraphMap-* crontab entries already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/graphmap-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_bash q_script q_ast_script q_node_dir q_graphify_dir q_vault q_himmel q_maps q_luna_title q_himmel_title q_log_luna q_log_himmel q_log_ast_luna q_log_ast_himmel
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$REFRESH_SCRIPT")
    q_ast_script=$(printf '%q' "$AST_UPDATE_SCRIPT")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')
    q_graphify_dir=$(printf '%q' "$GRAPHIFY_DIR")
    q_vault=$(printf '%q' "$VAULT")
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_maps=$(printf '%q' "$VAULT/60-Maps")
    q_luna_title=$(printf '%q' "$LUNA_TITLE")
    q_himmel_title=$(printf '%q' "$HIMMEL_TITLE")
    q_log_luna=$(printf '%q' "$BAT_DIR/graphmap-luna.log")
    q_log_himmel=$(printf '%q' "$BAT_DIR/graphmap-himmel.log")
    q_log_ast_luna=$(printf '%q' "$BAT_DIR/graphmap-ast-luna.log")
    q_log_ast_himmel=$(printf '%q' "$BAT_DIR/graphmap-ast-himmel.log")

    local payload_luna payload_himmel payload_ast_luna payload_ast_himmel
    payload_luna=$(cron_payload "$q_bash" "$q_script" luna "$q_vault" "$q_maps" "$q_luna_title" "$LUNA_SLUG" "$LUNA_TAG")
    payload_himmel=$(cron_payload "$q_bash" "$q_script" himmel "$q_himmel" "$q_maps" "$q_himmel_title" "$HIMMEL_SLUG" "$HIMMEL_TAG")
    # Structural (AST) payloads (HIMMEL-1948 Task 3, routed through the
    # promote-lock wrapper as of CR r1b): same asymmetric corpus roots as the
    # semantic pair (luna = vault, himmel = repo).
    payload_ast_luna=$(ast_cron_payload "$q_bash" "$q_ast_script" "$q_vault")
    payload_ast_himmel=$(ast_cron_payload "$q_bash" "$q_ast_script" "$q_himmel")

    local luna_hh luna_mm himmel_hh himmel_mm
    luna_hh="${LUNA_TIME%:*}"; luna_mm="${LUNA_TIME#*:}"
    himmel_hh="${HIMMEL_TIME%:*}"; himmel_mm="${HIMMEL_TIME#*:}"
    local ast_luna_hh ast_luna_mm ast_himmel_mm
    ast_luna_hh="${AST_LUNA_TIME%:*}"; ast_luna_mm="${AST_LUNA_TIME#*:}"
    ast_himmel_mm="${AST_HIMMEL_TIME#*:}"
    local q_runner_luna q_runner_himmel q_runner_ast_luna q_runner_ast_himmel
    q_runner_luna=$(cron_escape "$CRON_RUNNER_LUNA")
    q_runner_himmel=$(cron_escape "$CRON_RUNNER_HIMMEL")
    q_runner_ast_luna=$(cron_escape "$CRON_RUNNER_AST_LUNA")
    q_runner_ast_himmel=$(cron_escape "$CRON_RUNNER_AST_HIMMEL")
    local entry_luna entry_himmel entry_ast_luna entry_ast_himmel
    # Weekly (semantic pair, HIMMEL-1948): day-of-week field pinned to
    # WEEKLY_DAY_CRON instead of "*".
    entry_luna="$luna_mm $luna_hh * * $WEEKLY_DAY_CRON $q_runner_luna # $TASK_LUNA"
    entry_himmel="$himmel_mm $himmel_hh * * $WEEKLY_DAY_CRON $q_runner_himmel # $TASK_HIMMEL"
    # Structural pair (HIMMEL-1948 Task 3): himmel hourly (fixed minute, every
    # hour); luna DAILY at its full HH:MM (HIMMEL-1960, operator decision (a)).
    entry_ast_luna="$ast_luna_mm $ast_luna_hh * * * $q_runner_ast_luna # $TASK_AST_LUNA"
    entry_ast_himmel="$ast_himmel_mm * * * * $q_runner_ast_himmel # $TASK_AST_HIMMEL"

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$AST_ONLY" -eq 1 ]; then
            echo "DRY graphmap-cadence: --ast-only set; the semantic pair ($TASK_LUNA / $TASK_HIMMEL) is skipped entirely"
        else
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_LUNA:"
            emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" "$q_graphify_dir" | sed 's/^/    /'
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_HIMMEL:"
            emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" "$q_graphify_dir" | sed 's/^/    /'
        fi
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_AST_LUNA:"
        emit_runner "$TASK_AST_LUNA" "$payload_ast_luna" "$q_log_ast_luna" "$q_himmel" "" "$q_graphify_dir" 1 | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_AST_HIMMEL:"
        emit_runner "$TASK_AST_HIMMEL" "$payload_ast_himmel" "$q_log_ast_himmel" "$q_himmel" "" "$q_graphify_dir" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would add crontab entries:"
        if [ "$AST_ONLY" -eq 0 ]; then
            echo "    $entry_luna"
            echo "    $entry_himmel"
        fi
        echo "    $entry_ast_luna"
        echo "    $entry_ast_himmel"
        echo "graphmap-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runners at temp paths and promote (mv) them only after the
    # crontab install succeeds: writing them in place first would let a failed
    # install (exit 4) leave the OLD crontab live while the runner files already
    # carry the NEW config — a silent half-state under --force re-arm.
    # --ast-only (HIMMEL-2071): the semantic runners are neither built nor
    # promoted, and their entries never enter $own_match_re below, so a
    # PRE-EXISTING semantic pair's crontab lines and runner files survive an
    # --ast-only (re-)arm untouched.
    local tmp_ast_luna="$CRON_RUNNER_AST_LUNA.tmp.$$" tmp_ast_himmel="$CRON_RUNNER_AST_HIMMEL.tmp.$$"
    emit_runner "$TASK_AST_LUNA" "$payload_ast_luna" "$q_log_ast_luna" "$q_himmel" "" "$q_graphify_dir" 1 > "$tmp_ast_luna"
    emit_runner "$TASK_AST_HIMMEL" "$payload_ast_himmel" "$q_log_ast_himmel" "$q_himmel" "" "$q_graphify_dir" > "$tmp_ast_himmel"
    chmod +x "$tmp_ast_luna" "$tmp_ast_himmel"
    local own_match_re="(${TASK_AST_LUNA}|${TASK_AST_HIMMEL})"
    local new_entries="$entry_ast_luna"$'\n'"$entry_ast_himmel"
    local tmp_luna="" tmp_himmel=""
    if [ "$AST_ONLY" -eq 0 ]; then
        tmp_luna="$CRON_RUNNER_LUNA.tmp.$$"; tmp_himmel="$CRON_RUNNER_HIMMEL.tmp.$$"
        emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" "$q_graphify_dir" > "$tmp_luna"
        emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" "$q_graphify_dir" > "$tmp_himmel"
        chmod +x "$tmp_luna" "$tmp_himmel"
        own_match_re="$TASK_MATCH_RE"
        new_entries="$entry_luna"$'\n'"$entry_himmel"$'\n'"$new_entries"
    fi

    # Single atomic rewrite: everything that isn't ours (scoped by
    # own_match_re, which is AST-only or all-four per --ast-only above), then
    # this arm's own entries.
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vE "# ${own_match_re}\$" || true
        fi
        printf '%s\n' "$new_entries"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        rm -f "$tmp_luna" "$tmp_himmel" "$tmp_ast_luna" "$tmp_ast_himmel"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    if [ -n "$tmp_luna" ]; then
        mv -f "$tmp_luna" "$CRON_RUNNER_LUNA"
        mv -f "$tmp_himmel" "$CRON_RUNNER_HIMMEL"
        # weekly (604800s), not daily -- these are the semantic pair (codex-1,
        # HIMMEL-1680 CR): a wrong cadence here would make future
        # cadence-based staleness tooling flag a healthy weekly job as
        # stalled every day it hasn't fired.
        observability_register_cadence graphmap-luna 604800 "$TASK_LUNA"
        observability_register_cadence graphmap-himmel 604800 "$TASK_HIMMEL"
    fi
    mv -f "$tmp_ast_luna" "$CRON_RUNNER_AST_LUNA"
    mv -f "$tmp_ast_himmel" "$CRON_RUNNER_AST_HIMMEL"
    observability_register_cadence graphmap-ast-luna 86400 "$TASK_AST_LUNA"
    observability_register_cadence graphmap-ast-himmel 3600 "$TASK_AST_HIMMEL"

    local semantic_lines arming_note
    if [ "$AST_ONLY" -eq 1 ]; then
        # codex-1, HIMMEL-2071 CR round 1 (same fix as cmd_arm): report the
        # semantic pair's REAL post-install crontab state, not a blanket
        # "NOT armed" — an --ast-only (re-)arm never touches it, but it can
        # already be armed from an earlier full arm.
        # codex-1, CR round 2 (Suggestion, same fix as cmd_arm): don't
        # restate this arm's $BACKEND/$LUNA_TIME/$HIMMEL_TIME for a task this
        # run never touched — point at `status` for its real config instead
        # of guessing.
        cron_read
        local luna_line himmel_line
        if printf '%s\n' "$CRON_TAB" | grep -q -E "# ${TASK_LUNA}\$"; then
            luna_line="  $TASK_LUNA       already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            luna_line="  $TASK_LUNA       NOT armed (--ast-only)"
        fi
        if printf '%s\n' "$CRON_TAB" | grep -q -E "# ${TASK_HIMMEL}\$"; then
            himmel_line="  $TASK_HIMMEL     already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            himmel_line="  $TASK_HIMMEL     NOT armed (--ast-only)"
        fi
        semantic_lines="$luna_line
$himmel_line"
        arming_note="  No task ever opens a claude session. --ast-only arms/replaces only the
  free structural pair; a pre-existing semantic pair (if shown above) is
  left byte-identical. Re-arm without --ast-only to add a missing
  semantic pair (--force to replace). Disarm anytime with:"
    else
        semantic_lines="  $TASK_LUNA       weekly (dow $WEEKLY_DAY_CRON) $LUNA_TIME   -> refresh-graph-map luna (semantic, $BACKEND)
  $TASK_HIMMEL     weekly (dow $WEEKLY_DAY_CRON) $HIMMEL_TIME   -> refresh-graph-map himmel (semantic, $BACKEND)"
        arming_note="  No task ever opens a claude session. Arming = weekly semantic graphify
  extraction on the $BACKEND backend (off the interactive Anthropic bank)
  + free structural refresh (himmel hourly, luna daily); disarm anytime:"
    fi
    cat <<EOF

================================================================
  GRAPHMAP CADENCE ARMED (HIMMEL-829, cron; inverted HIMMEL-1948)
$semantic_lines
  $TASK_AST_LUNA    daily at $AST_LUNA_TIME   -> graphify update luna (structural, free)
  $TASK_AST_HIMMEL  hourly at :$ast_himmel_mm   -> graphify update himmel (structural, free)
  Vault: $VAULT   (maps -> 60-Maps/)
  Himmel: $HIMMEL_ROOT
  Runner .sh: $BAT_DIR

$arming_note
      bash scripts/luna/graphmap-cadence.sh disarm
================================================================
EOF
}

# Runtime preflight on the ARM path only (HIMMEL-1991): arming hands this
# machine's runtime to an unattended schedule that will re-run for weeks with
# nobody reading the output, so drift gets named at the one moment a human is
# still here. status/disarm change nothing and stay silent. Advisory by default;
# HIMMEL_RUNTIME_PREFLIGHT=strict refuses, =0 silences.
if [ "$SUBCMD" = "arm" ]; then
    # shellcheck source=../lib/runtime-preflight.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/runtime-preflight.sh"
    runtime_preflight "graphmap-cadence arm" || exit 1
fi

case "$SUBCMD" in
    arm)    if [ "$PLATFORM" = "windows" ]; then cmd_arm;    else cron_arm;    fi ;;
    status) if [ "$PLATFORM" = "windows" ]; then cmd_status; else cron_status; fi ;;
    disarm) if [ "$PLATFORM" = "windows" ]; then cmd_disarm; else cron_disarm; fi ;;
esac
