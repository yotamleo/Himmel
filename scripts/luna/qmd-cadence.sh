#!/usr/bin/env bash
# qmd-cadence.sh — arm/status/disarm the recurring qmd reindex cadence
# (HIMMEL-568).
#
# WHY: the qmd index goes stale SILENTLY. During HIMMEL-564 Phase A the luna
# collection sat five days stale (lastUpdated 2026-06-22, needsEmbedding 0) while
# notes written that week were simply not searchable — every qmd-backed workflow
# answered off a stale index and nothing signalled it. scripts/luna/qmd-reindex.sh
# is the RUNNER that refreshes it (`qmd update` + `qmd embed` + a completeness
# assert); what was missing is the scheduler. This is that layer: one daily
# OS-scheduler task that fires the runner off-peak.
#
# DESIGN: modelled on the sibling graphmap-cadence.sh (HIMMEL-829), NOT on
# pipeline-cadence.sh. pipeline-cadence fires interactive `claude "<prompt>" < NUL`
# bounded sessions, each wired with a --settings auto-approve fragment. THIS
# scheduler fires a DETERMINISTIC SCRIPT — `bash <himmel>/scripts/luna/
# qmd-reindex.sh --qmd-bin <qmd>` — so it has NO claude SESSION, NO NUL-stdin, NO
# settings fragment and NO auto-approve hook. `qmd update` / `qmd embed` are plain
# CLI calls, so the deterministic shape is the correct precedent.
#
# HIMMEL-128 (headless-claude billing) does NOT apply here, not even indirectly.
# The graphmap sibling carries that caveat because its graphify backend shells the
# `claude` CLI underneath; nothing in the qmd path invokes claude at all.
#
# ONE task is registered:
#   HIMMEL-Qmd-Reindex   daily (default 05:00 local)
#       bash <himmel>/scripts/luna/qmd-reindex.sh --qmd-bin <qmd>
#
# WITH --ship-to <host> (HIMMEL-1286) the SAME single task fires the ship
# runner instead:
#       bash <himmel>/scripts/luna/ship-index.sh --qmd-bin <qmd> --host <host>
#
# Still ONE task, not two. ship-index.sh's step 1 IS qmd-reindex.sh — the
# transport was built to ship AFTER a successful local reindex, so a separate
# ship task on a later clock would push whatever happened to be on disk and
# reintroduce the race the design avoids. This is the "host pushes on a cadence"
# half of HIMMEL-1286's transport decision: the receiving station embeds ~50x
# slower than the host, so it RECEIVES and never builds, and nothing but this
# cadence gets an index there without a human remembering.
#
# WHY 05:00 LOCAL: it lands AFTER the whole pipeline-cadence chain has finished
# writing to the vault (HIMMEL-Pipeline-Harvest 02:00, -Synthesize 03:00,
# -Health 04:00), so the reindex actually picks up what those legs just wrote
# instead of racing them — a reindex scheduled before them would index the
# previous day's vault. It is also clear of the graphmap slots (13:00 / 13:20)
# and the 17:00 codex orphan sweep. Cost basis for daily: a full local refresh
# measured 2026-07-25 ran in 16s (update) + 24s (embed) — daily is cheap, and
# daily is what bounds the observed five-day staleness to under 24h.
#
# WHY THE qmd BINARY IS PINNED AT ARM TIME: schtasks and cron fire with a MINIMAL
# PATH that does not carry the bun bin dir where qmd installs (~/.bun/bin here).
# Resolving it HERE, at arm time, is what makes the failure visible — otherwise
# the arm "succeeds" and every unattended fire dies in a log nobody reads. The
# resolved ABSOLUTE invocation is passed to the runner as --qmd-bin (+ --qmd-js).
# Unlike the graphmap sibling (which must PATH-prepend, because graphify spawns
# `claude` itself), we invoke qmd directly, so passing the path is both simpler
# and stricter. Verified 2026-07-25: qmd runs correctly under a bare
# PATH=C:\Windows\system32, so no PATH surgery is needed.
#
# HOW it is resolved, and why that matters (HIMMEL-1283): via
# scripts/lib/qmd-bin.sh's qmd_pinned_invocation, NOT a bare `command -v qmd`.
# The bare lookup finds the broken Claude-plugin stub
# (~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) that shadows the bun shim on Git
# Bash $PATH inside a Claude Code session — which is exactly where an operator
# arms this from — and bakes THAT into the runner, so every fire dies with
# `Module not found "...plugins/cache/qmd/.../dist/cli/qmd.js"`. The shared
# resolver prefers the bun-served install, whose canonical invocation is
# `bun <…/dist/cli/qmd.js>`: TWO tokens, neither of them a `qmd` executable —
# which is why the runner grew a --qmd-js flag rather than the pin being
# squeezed into one path. (qmd_cmd itself is NOT usable here: it INVOKES, and a
# cadence needs a pinnable absolute invocation.)
#
# And the pin is LIVENESS-checked, not existence-checked: the resolved
# invocation is actually RUN once (`collection list`, which opens the index —
# `--version` does not, so it passes on an install whose better-sqlite3 binding
# is broken) and must exit 0 before it is written into a runner. An
# existence-only test passes on the broken stub, which is the whole failure
# class this closes.
#
# WITH --hourly (HIMMEL-2111) the SAME single task fires every hour instead of
# once daily. Windows keeps the daily CalendarTrigger anchored at --time and
# layers graphmap-cadence's Repetition fragment on top
# (<Interval>PT1H</Interval><Duration>P1D</Duration><StopAtDurationEnd>false
# </StopAtDurationEnd>) — the same "hourly forever" idiom HIMMEL-1948
# established for graphmap's AST-himmel task, since schtasks has no bare
# /sc HOURLY reachable from /xml. The POSIX/cron path emits `MM * * * *`
# instead of `MM HH * * *`, using --time's minute as the fixed :MM past every
# hour — --time's hour is then irrelevant for scheduling, but the flag still
# validates as a full HH:MM so one flag serves both cadences.
#
# OPERATOR FLIP: this NEVER auto-arms. `arm` registers the task only when
# explicitly invoked, exactly like graphmap-cadence — arming is the operator's
# decision, not a side effect of installing the harness.
#
# Usage:
#   bash scripts/luna/qmd-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash scripts/luna/qmd-cadence.sh status
#   bash scripts/luna/qmd-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-qmd-cadence.sh):
#   QMD_CADENCE_SCHTASKS  — command invoked instead of `schtasks` (Windows)
#   QMD_CADENCE_CRONTAB   — command invoked instead of `crontab` (POSIX)
#   QMD_CADENCE_BAT_DIR   — where the persistent runner (.bat/.sh) lives
#
# Exit codes (mirrors graphmap-cadence.sh / pipeline-cadence.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no schtasks/crontab; unknown platform; runner or qmd
#      missing; query tool errored)
#   3  dedup block — a HIMMEL-Qmd-* task is already armed; use --force
#   4  scheduler invocation failed (/create, /delete, crontab rewrite,
#      path conversion)
set -euo pipefail

TASK_PREFIX="HIMMEL-Qmd-"
TASK_REINDEX="${TASK_PREFIX}Reindex"
SCHTASKS_BIN="${QMD_CADENCE_SCHTASKS:-schtasks}"
CRONTAB_BIN="${QMD_CADENCE_CRONTAB:-crontab}"

# Cross-platform user-home resolution (mirrors graphmap-cadence's, HIMMEL-645).
# On Windows Git-Bash $HOME can be the MSYS home (/home/<user>) while Claude
# Code's config (~/.claude) lives under the Windows user profile, so prefer
# USERPROFILE via cygpath BEFORE $HOME. POSIX hosts have USERPROFILE unset and
# fall straight through to $HOME. /tmp is the last-resort floor.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home (.bat on Windows, .sh on POSIX) — NOT mktemp: this task
# recurs daily and %TEMP% / /tmp are subject to cleanup sweeps that would
# silently kill the cadence (same rationale as the sibling cadences' BAT_DIR).
BAT_DIR="${QMD_CADENCE_BAT_DIR:-$(resolve_user_home)/.claude/qmd-cadence}"

# Resolve the himmel root from this script's own location (scripts/luna/..), so
# the runner fires the shipped qmd-reindex.sh by absolute path.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
REINDEX_SCRIPT="$HIMMEL_ROOT/scripts/luna/qmd-reindex.sh"
SHIP_SCRIPT="$HIMMEL_ROOT/scripts/luna/ship-index.sh"
# --ship-to <host> (HIMMEL-1286): arm the SHIP runner instead of the bare
# reindex. It is ONE task either way, not two, because ship-index.sh's step 1 IS
# qmd-reindex.sh — the transport was designed to ship AFTER a successful local
# reindex rather than on a blind clock, so a second task fired 30 minutes later
# would ship whatever happened to be on disk and reintroduce exactly the race the
# design avoids. RUNNER_SCRIPT is resolved from this after arg parsing.
SHIP_TO=""
RUNNER_SCRIPT="$REINDEX_SCRIPT"

# Runner-format version stamp (HIMMEL-588): emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into the runner so a stale-format armed cadence
# is detectable. Shared lib, same as the sibling cadences.
# Shared qmd resolver (HIMMEL-1283): qmd_pinned_invocation returns the absolute
# tokens qmd_cmd would choose, so the cadence pins the SAME install every other
# consumer resolves instead of whatever `command -v qmd` happens to hit first.
# shellcheck source=../lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-bin.sh"

# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# Off-peak default (see the header for the 05:00 rationale).
REINDEX_TIME="05:00"
FORCE=0
DRY_RUN=0
# --hourly (HIMMEL-2111): fire every hour instead of once daily. See the
# header for the Windows Repetition / POSIX cron-line mechanics.
HOURLY=0
# Set when a --force arm has actually DELETED a previously armed task, so a
# subsequent create failure can tell the operator the machine is now unarmed.
REPLACED_EXISTING=0

# Resolved by validate_arm_inputs: the absolute qmd invocation handed to the
# runner. QMD_BIN is the executable (--qmd-bin); QMD_JS is the optional script
# argument (--qmd-js), set only when the bun-served install wins the resolver's
# preference order — there the canonical invocation is `bun <…/dist/cli/qmd.js>`,
# two tokens, neither of which is a `qmd` executable (HIMMEL-1283). See the
# header for why this is pinned at arm time.
QMD_BIN=""
QMD_JS=""

usage() {
    cat <<'EOF'
Usage: qmd-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring qmd reindex cadence (HIMMEL-568):
one daily `qmd update` + `qmd embed` + completeness assert over ALL
configured collections, fired as a DETERMINISTIC script
(bash qmd-reindex.sh ...) — NO claude session.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if a
           HIMMEL-Qmd-* task already exists; --force replaces.
  status   Show whether the cadence is armed (+ next run time + run log).
  disarm   Remove the task (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Anchor time, 24h local (default 05:00). Daily cadence
                  (the default): fires once, at this time, every day. With
                  --hourly, only the minute is used — it becomes the fixed
                  :MM the hourly cadence fires past every hour.
  --hourly        Fire hourly instead of once daily (Windows: a Repetition
                  fragment re-fires every hour for 24h, the same idiom
                  graphmap-cadence uses for its AST-himmel task; POSIX: an
                  hourly crontab line `MM * * * *`).
  --ship-to <h>   Arm ship-index.sh --host <h> instead of the bare reindex,
                  so the host PUSHES the fresh index to a receiving station
                  on the same cadence (daily by default, or hourly with
                  --hourly). Still ONE task: ship-index.sh's step 1 IS
                  qmd-reindex.sh, so the ship follows a successful reindex
                  rather than a blind clock.
  --force         Replace an existing HIMMEL-Qmd-* task
  --dry-run       Print what would happen, touch nothing
                  (honored by arm AND disarm)

WHY 05:00 local: it runs AFTER the pipeline-cadence legs that WRITE to the
vault (Harvest 02:00, Synthesize 03:00, Health 04:00), so the reindex picks
up what they wrote rather than racing them; and it is clear of the graphmap
slots (13:00/13:20). A full refresh measured 16s + 24s, so daily is cheap.

Collection scope is ALL configured collections — `qmd update` / `qmd embed`
default to everything and take -c only to narrow, so nothing is hardcoded
here and a collection added later needs no edit.

This never auto-arms: arming is an explicit operator flip, and disarm is
always available:
    bash scripts/luna/qmd-cadence.sh disarm
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR qmd-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR qmd-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

# Shared by BOTH --ship-to spellings (space and `=`), so the two can never drift
# apart — the drift is what let `--ship-to=` through as a silent no-op while
# `--ship-to ""` was correctly refused.
#
# Rejects two shapes, for the same reason in both cases: the operator asked for a
# ship cadence, and anything that quietly yields "no ship" is worse than an error.
#   empty       — an unset var expanded to nothing; would arm reindex-ONLY.
#   flag-shaped — `--ship-to --dry-run` takes "--dry-run" as the HOSTNAME, so
#                 --dry-run is CONSUMED, DRY_RUN stays 0, and a command written
#                 as a rehearsal arms the task for real against a garbage host.
validate_ship_to() {
    if [ -z "$1" ]; then
        echo "ERR qmd-cadence: --ship-to requires a value (ssh host)" >&2
        usage >&2
        exit 1
    fi
    case "$1" in
        -*)
            echo "ERR qmd-cadence: --ship-to needs an ssh host, got the flag '$1'" >&2
            usage >&2
            exit 1 ;;
    esac
    # REFUSE anything outside an ssh-target grammar. This value is the ONE
    # operator-supplied string that gets baked into a PERSISTENT scheduled .bat,
    # and cadence_cmd_escape's own header states the rule it has to obey:
    #
    #   "Do not extend this function to a value that can carry an arbitrary
    #    quote — refuse instead."
    #
    # It says that because backslash does NOT escape a quote for cmd.exe, so a
    # host containing `"` would terminate the quoted argument and expose command
    # metacharacters — turning a scheduled task into arbitrary execution under
    # the operator's account on every fire. Every other value that escaper sees
    # is a Windows path, where `"` is illegal by construction; --ship-to was the
    # first one that could carry one, so the refusal belongs here.
    #
    # The allowed set covers real ssh targets — hostnames, ~/.ssh/config
    # aliases, IPv4, and user@host — and nothing else. A target this rejects is
    # still reachable: put it in ~/.ssh/config and arm the alias.
    case "$1" in
        *[!A-Za-z0-9._@-]*)
            echo "ERR qmd-cadence: --ship-to '$1' is not a plain ssh host — allowed: letters, digits, . _ - @" >&2
            echo "    (this value is baked into a scheduled runner; a quote or shell metacharacter there is arbitrary execution)" >&2
            echo "    For a target needing more, define a Host alias in ~/.ssh/config and pass the alias." >&2
            exit 1 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            # Demand a real operand: a trailing `--time` would otherwise make
            # `shift 2` fail under set -e and exit with no message at all.
            if [ $# -lt 2 ]; then
                echo "ERR qmd-cadence: --time requires a value (HH:MM)" >&2
                usage >&2
                exit 1
            fi
            REINDEX_TIME="$2"; shift 2 ;;
        --time=*)   REINDEX_TIME="${1#--time=}"; shift ;;
        --hourly)   HOURLY=1; shift ;;
        --ship-to)
            if [ $# -lt 2 ]; then
                echo "ERR qmd-cadence: --ship-to requires a value (ssh host)" >&2
                usage >&2
                exit 1
            fi
            validate_ship_to "$2"
            SHIP_TO="$2"; shift 2 ;;
        --ship-to=*)
            # The `=` form gets the SAME validation as the space form. Without
            # it `--ship-to=` (an unset var expanding to nothing is the common
            # way to get here) set SHIP_TO empty and silently armed
            # reindex-ONLY — the operator asked for a ship cadence and got a
            # scheduler that never ships, with no error to notice. The --time=
            # sibling survives the same shape only because a later HH:MM regex
            # rejects the empty value; --ship-to has no such downstream check,
            # so it must reject here.
            _ship_to_val="${1#--ship-to=}"
            validate_ship_to "$_ship_to_val"
            SHIP_TO="$_ship_to_val"; unset _ship_to_val; shift ;;
        --force)    FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo "ERR qmd-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Resolve which runner the task will fire (HIMMEL-1286). Done ONCE here so the
# schtasks and cron emitters below stay identical apart from their escaping —
# the two payload sites already diverged into cmd_escape vs printf %q, and
# branching on SHIP_TO in both would be a third place to keep in sync by hand.
RUNNER_DESC="qmd update + qmd embed"
if [ -n "$SHIP_TO" ]; then
    RUNNER_SCRIPT="$SHIP_SCRIPT"
    # The success banner has to say what was actually armed. Reporting
    # "qmd update + qmd embed" after arming a SHIP cadence tells the operator
    # the destination was ignored, which is the one thing they would want to
    # catch at arm time rather than discover from a stale receiver days later.
    RUNNER_DESC="reindex + SHIP to $SHIP_TO (ship-index.sh)"
fi
# The banners' "the task fires bash + <script>" line is derived from the SAME
# resolution, not spelled out again: both emitters used to hard-code
# "qmd-reindex.sh" there, so an armed SHIP cadence described itself as a plain
# reindex two lines under a banner that had just said otherwise — and the one
# thing that sentence exists to answer is which script actually runs.
RUNNER_NAME=$(basename "$RUNNER_SCRIPT")
# The banner's schedule line has to say hourly when it is (HIMMEL-2111) —
# derived independently of RUNNER_DESC above, since --hourly changes how
# often the task fires, not what it runs.
CADENCE_DESC="daily $REINDEX_TIME"
if [ "$HOURLY" -eq 1 ]; then
    CADENCE_DESC="hourly, :${REINDEX_TIME#*:} past the hour"
fi

# Platform detect (same matrix as the sibling cadences).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    windows)
        command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
            echo "ERR qmd-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR qmd-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR qmd-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

# MSYS_NO_PATHCONV=1 per call: without it gitbash mangles /query, /create etc.
# into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Dedup listing: every scheduled task named HIMMEL-Qmd-*. Fail-CLOSED if the
# query tool itself errors (mirrors the sibling cadences' list_existing).
list_existing() {
    local err_file out rc
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    set +e
    out=$(run_schtasks /query /fo CSV /nh 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        # Fail-CLOSED: any nonzero rc is fatal UNLESS it matches the one trusted
        # empty-scheduler signature — rc=1 with EMPTY stderr (schtasks returns
        # rc=1 on a completely empty scheduler; real errors carry stderr).
        if [ "$rc" -ne 1 ] || [ -s "$err_file" ]; then
            echo "ERR qmd-cadence: schtasks /query failed (rc=$rc) — refusing to treat as empty scheduler:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # shellcheck disable=SC1003  # strips both quote and the literal backslash schtasks prefixes task names with
    printf '%s\n' "$out" \
        | grep -o '"\\\?HIMMEL-Qmd-[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u || true
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "qmd-cadence: deleted scheduled task: $name"
    else
        echo "ERR qmd-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Known not-found stderr signatures for `/query /tn <name>` (mirrors the sibling
# cadences). Real schtasks always emits one of these on a missing task, so rc=1
# WITHOUT a match (silent rc=1 included) is a real query failure.
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_one <name>: rc 0 = armed (QUERY_OUT set), rc 1 = trusted not-found,
# rc 2 = query failed (stderr already printed).
QUERY_OUT=""
query_one() {
    local name="$1" rc err_file
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
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
    echo "ERR qmd-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
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
        "$TASK_REINDEX") printf ' -> qmd-reindex (update + embed, all collections, daily)' ;;
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

# Surface fire-time evidence: the runner writes its output to a .log next to
# itself (rotated per fire), so "armed but never succeeding" is visible here.
status_log() {
    local log="$1" mtime last
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        # Same macOS-compatible fallback chain as the primary log above: BSD
        # `date` has no -r, so without the `stat -f` leg this would always
        # print '?' on macOS while the primary log resolved fine.
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    fi
}

cmd_status() {
    local status_rc=0
    echo "qmd-cadence status:"
    status_one "$TASK_REINDEX" || status_rc=2
    status_log "$BAT_DIR/qmd-reindex.log"
    return "$status_rc"
}

# Disarm every HIMMEL-Qmd-* task, not just the canonical TASK_REINDEX name.
# `arm`'s dedup guard blocks on the PREFIX (list_existing), so a disarm that
# only knew the exact name could leave an operator wedged: arm refuses with
# "already armed", disarm answers "nothing armed", and nothing short of a manual
# schtasks /delete breaks the tie. The POSIX path already disarms by prefix
# (cron_existing greps TASK_PREFIX) — this brings the Windows path in line.
# list_existing is fail-CLOSED, so a broken /query still exits 2 here rather
# than reporting a false no-op.
cmd_disarm() {
    local found=0 existing name
    existing=$(list_existing)
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        found=1
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY qmd-cadence: would delete $name"
        else
            delete_task "$name"
        fi
    done <<< "$existing"
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/qmd-reindex.bat"
        rm -f "$BAT_DIR/qmd-reindex.vbs"
    fi
    if [ "$found" -eq 0 ]; then
        echo "qmd-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY qmd-cadence: no changes made"
    else
        echo "qmd-cadence: cadence disarmed"
    fi
}

# Emit the .bat body: stamp the format version, rotate the run log (one prior run
# kept as .log.prev), stamp the fire time, cd into the himmel root (a failing cd
# aborts + is logged instead of firing from the wrong CWD), then fire bash +
# qmd-reindex.sh with stdout+stderr captured to the rotating log. NO claude
# SESSION, NO stdin redirect: the runner IS the payload. The qmd BINARY path is
# still passed to the runner explicitly (see the header) — but Git's usr\bin + bin
# are prepended to PATH (HIMMEL-1672) so the NON-LOGIN bash.exe finds the GNU
# coreutils qmd-reindex.sh itself calls (sed/grep/date) ahead of System32.
emit_bat() {
    local himmel_win_esc="$1" payload="$2" log_win_esc="$3" git_bin_esc="${4:-}"
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    if [ -n "$git_bin_esc" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$git_bin_esc"
    fi
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$himmel_win_esc" "$log_win_esc"
    printf '%s >> "%s" 2>&1\r\n' "$payload" "$log_win_esc"
}

# --- schtasks task XML (StartWhenAvailable) --------------------------------
#
# schtasks /create has no flag for StartWhenAvailable ("run as soon as possible
# after a missed scheduled start"), so a daily 05:00 run is SILENTLY SKIPPED if
# the machine was off/asleep at 05:00 — which for a staleness-prevention cadence
# is the whole failure mode returning. The only CLI route is `schtasks /create
# /xml`; we keep the .bat as the Exec Command and wrap it in XML carrying
# StartWhenAvailable=true (same approach as the sibling cadences, HIMMEL-362).

# Escape the three XML-significant characters for element-body text (the Exec
# <Command> path — a BAT_DIR path may legally contain `&`). `&` first so the `&`
# in the &lt;/&gt; entities isn't re-escaped. sed (not bash ${//}) for a
# version-independent literal-ampersand replacement.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

# Repetition fragment (--hourly, HIMMEL-2111): re-fires every hour (PT1H) for a
# full day (Duration P1D) — the standard Task Scheduler XML idiom for "hourly,
# forever" (schtasks has no bare /sc HOURLY equivalent reachable from /xml).
# StopAtDurationEnd=false: the repetition itself re-arms with the next day's
# CalendarTrigger fire, so the task keeps firing hourly indefinitely. Same
# fragment graphmap-cadence.sh uses for its AST-himmel task (HIMMEL-1948) —
# see that script's repetition_xml for the base-type element-ordering
# rationale (Repetition must precede the ScheduleByX fragment in the emitted
# trigger, or `schtasks /create /xml` can reject it).
repetition_xml() {
    printf '      <Repetition>\n        <Interval>PT1H</Interval>\n        <Duration>P1D</Duration>\n        <StopAtDurationEnd>false</StopAtDurationEnd>\n      </Repetition>'
}

# Emit the task XML: a CalendarTrigger at the given local time, daily schedule,
# StartWhenAvailable=true, and the .bat runner as the Exec Command. StartBoundary
# date is a fixed past sentinel — the schedule fragment (not the date) governs
# firing. MultipleInstancesPolicy=IgnoreNew is what keeps the cadence from
# overlapping ITSELF (qmd-reindex.sh takes no lock of its own by design).
# Declared UTF-16 (what schtasks /create /xml expects) but the bytes are plain
# ASCII — keep it ASCII-only (a non-ASCII byte would need a real UTF-16LE +BOM
# file; declaring UTF-8 is rejected on Win11).
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
    # Join repetition + schedule_xml with a real newline BEFORE the heredoc
    # (mirrors graphmap-cadence's emit_task_xml): heredoc bodies get parameter
    # expansion but not ANSI-C ($'\n') quote processing, so building the
    # joined newline here keeps the emitted XML one-element-per-line instead
    # of gluing `</Repetition>` and `<ScheduleByDay>` onto one line.
    local trigger_body="$schedule_xml"
    [ -n "$repetition" ] && trigger_body="${repetition}"$'\n'"${schedule_xml}"
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel qmd-cadence (HIMMEL-568)</Description>
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

# Create the task from an XML definition (so StartWhenAvailable applies).
# Self-contained error handling; returns the schtasks rc so callers keep the
# failure flow.
schtasks_create_xml() {
    local name="$1" schedule_xml="$2" start_time="$3" bat_win="$4" err_file="$5" repetition="${6:-}"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t qmd-cadence.xml.XXXXXX 2>"$err_file"); then
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
    if ! [[ "$REINDEX_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR qmd-cadence: --time must be HH:MM (24h), got: $REINDEX_TIME" >&2
        exit 1
    fi
    if [ ! -f "$RUNNER_SCRIPT" ]; then
        echo "ERR qmd-cadence: runner not found at $RUNNER_SCRIPT" >&2
        exit 2
    fi
    # With --ship-to the armed runner is ship-index.sh, which invokes
    # qmd-reindex.sh as its own step 1 — so BOTH must exist, and the missing one
    # has to surface at arm time rather than at 05:00 in a log nobody reads.
    if [ -n "$SHIP_TO" ] && [ ! -f "$REINDEX_SCRIPT" ]; then
        echo "ERR qmd-cadence: ship-index.sh needs qmd-reindex.sh, not found at $REINDEX_SCRIPT" >&2
        exit 2
    fi
    # FAIL FAST on a missing `qmd`. The scheduler fires with a MINIMAL PATH that
    # does not carry qmd's bin dir (bun installs to ~/.bun/bin), so this must
    # resolve HERE — without it the arm "succeeds" and the first unattended fire
    # dies in a log nobody reads. The resolved absolute invocation is handed to
    # the runner as --qmd-bin (+ --qmd-js when the bun-served install wins).
    #
    # Resolve through the SHARED resolver's preference order, NOT a bare
    # `command -v qmd` (HIMMEL-1283). The bare lookup finds the broken
    # Claude-plugin stub (~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) that
    # shadows the bun shim on Git Bash $PATH inside a Claude Code session —
    # which is exactly where an operator arms this from — and bakes THAT into
    # the runner. Every unattended fire then dies with
    # `Module not found "...plugins/cache/qmd/.../dist/cli/qmd.js"`.
    # qmd_pinned_invocation is not qmd_cmd: qmd_cmd INVOKES (wrong shape for a
    # cadence, which needs a pinnable absolute invocation), this returns the
    # absolute tokens qmd_cmd would have chosen.
    local _resolved
    if ! _resolved=$(qmd_pinned_invocation 2>/dev/null); then
        {
            echo "ERR qmd-cadence: no usable qmd found at arm time, but the cadence runs it at fire time."
            echo "    The scheduler fires with a minimal PATH, so this must resolve HERE — arming now"
            echo "    would produce a cadence that fails on every fire. Install qmd (or put it on PATH)"
            echo "    and re-arm."
        } >&2
        exit 2
    fi
    QMD_BIN=$(printf '%s\n' "$_resolved" | sed -n '1p')
    QMD_JS=$(printf '%s\n' "$_resolved" | sed -n '2p')
    # `command -v` resolves more than on-PATH executables: a shell FUNCTION or
    # ALIAS resolves to its own name/definition, and a relative PATH entry
    # resolves to a relative path. Either would be meaningless in a runner that
    # has cd'd elsewhere under a different PATH — the exact failure this check
    # exists to prevent (same guard the graphmap sibling applies to `claude`).
    # Demand a real, absolute, executable file (Windows: the `.exe` an MSYS -x
    # test still accepts behind an extensionless path).
    case "$QMD_BIN" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *)
            echo "ERR qmd-cadence: 'qmd' resolved to a non-absolute path ('$QMD_BIN') — a shell function/alias or a relative PATH entry cannot be pinned into a scheduled runner. Install qmd on PATH as a real executable and re-arm." >&2
            exit 2 ;;
    esac
    if [ ! -f "$QMD_BIN" ] || [ ! -x "$QMD_BIN" ]; then
        echo "ERR qmd-cadence: 'qmd' resolved to '$QMD_BIN', which is not an executable file — refusing to pin it into a scheduled runner." >&2
        exit 2
    fi
    # The script arg gets the absolute + real-file discipline too. NOT the -x
    # test: it is a .js handed to an interpreter, never executed directly.
    if [ -n "$QMD_JS" ]; then
        case "$QMD_JS" in
            /*|[A-Za-z]:[/\\]*) : ;;
            *)
                echo "ERR qmd-cadence: qmd script path resolved non-absolute ('$QMD_JS') — cannot be pinned into a scheduled runner." >&2
                exit 2 ;;
        esac
        if [ ! -f "$QMD_JS" ]; then
            echo "ERR qmd-cadence: qmd script path '$QMD_JS' is not a file — refusing to pin it into a scheduled runner." >&2
            exit 2
        fi
    fi

    # LIVENESS, not existence (HIMMEL-1283). Everything above proves "a file
    # exists and is executable" — which the broken plugin stub also satisfies.
    # It is the exact class of failure the arm-time fail-fast was written to
    # prevent, reintroduced one layer up. So RUN the resolved invocation once
    # and require rc 0 before pinning it.
    #
    # `collection list` is the probe, deliberately NOT `--version`: --version
    # never opens the index, so it passes even when better-sqlite3's native
    # binding is missing or wrong-ABI (HIMMEL-928) — a qmd that answers
    # --version and then dies on every real op is precisely what must not get
    # armed. `collection list` opens the DB, which is what the cadence's
    # `update`/`embed` do. It is also the same probe the shared resolver's own
    # has_index() uses, so this agrees with the rest of the repo.
    # BOUNDED. A probe that HANGS is the third failure mode, and an unbounded
    # one would wedge `arm` forever with no output — a worse outcome than the
    # broken stub this check exists for, since the operator gets nothing to act
    # on. qmd opens a SQLite index that another process may hold, so a stall is
    # a live possibility, not a hypothetical. `timeout` is used when present and
    # the call degrades to a direct invocation when it is not (macOS ships no
    # coreutils `timeout` by default) — the same graceful-degrade convention
    # critic-panel.sh uses for its per-member cap.
    # Build the probe as ONE argv rather than branching timeout × QMD_JS into
    # four near-identical invocations — four copies of the same command line is
    # four places for a future change to half-land. The array is never empty
    # (QMD_BIN is always appended), so "${probe_cmd[@]}" is safe under set -u.
    local probe_out probe_rc=0 probe_timeout="${QMD_PROBE_TIMEOUT_SECS:-60}"
    local probe_cmd=()
    # `command -v timeout` is NOT enough on Git Bash (public-PR CR). Windows
    # ships C:\Windows\System32\timeout.exe, which is a SLEEP, not a command
    # runner: it has no -k and takes no subcommand. If PATH resolves to that one,
    # `timeout -k 5 60 qmd collection list` fails instantly, the probe reports a
    # perfectly healthy qmd as HUNG, and `arm` is blocked on a supported
    # platform — a false negative that sends the operator hunting an index lock
    # that does not exist.
    #
    # Only GNU coreutils names itself in --version (the Windows one answers with
    # an "Invalid value for timeout (/T)" error on stderr and nothing on stdout),
    # so that is the discriminator. Captured into a variable rather than piped
    # into grep -q: an early-exiting reader can SIGPIPE the producer, and under
    # `set -o pipefail` that would read as "not GNU" and silently drop the
    # bounded probe on the very hosts that have it.
    local _timeout_ver=""
    _timeout_ver="$(timeout --version 2>/dev/null || true)"
    case "$_timeout_ver" in
        *oreutils*) probe_cmd=(timeout -k 5 "$probe_timeout") ;;
        *)          : ;;   # absent, or Windows timeout.exe -> run the probe UNBOUNDED rather than break it
    esac
    probe_cmd+=("$QMD_BIN")
    [ -n "$QMD_JS" ] && probe_cmd+=("$QMD_JS")
    probe_out=$("${probe_cmd[@]}" collection list 2>&1) || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
        {
            # 124/137 are timeout's own codes — name that case, because "rc=124"
            # alone reads as a qmd error and sends the operator hunting the
            # wrong thing.
            case "$probe_rc" in
                124|137)
                    echo "ERR qmd-cadence: the resolved qmd HUNG (no answer in ${probe_timeout}s) — refusing to arm a cadence that would stall on every fire."
                    echo "    A hung probe usually means the index is locked by another qmd process"
                    echo "    (a resident 'qmd mcp' daemon, or a reindex still running)."
                    echo "    Raise the bound with QMD_PROBE_TIMEOUT_SECS if this machine is just slow."
                    ;;
                *)
                    echo "ERR qmd-cadence: the resolved qmd is NOT USABLE (rc=$probe_rc) — refusing to arm a cadence that would fail on every fire."
                    ;;
            esac
            echo "    invocation: $(qmd_invocation_desc)"
            echo "    probe:      <invocation> collection list"
            printf '%s\n' "$probe_out" | sed 's/^/    /'
            echo "    A qmd that exists but errors here is the whole point of this check: an"
            echo "    existence-only test passes on the broken Claude-plugin stub. Fix the install"
            echo "    (bash scripts/lib/qmd-bin.sh install) and re-arm."
        } >&2
        exit 2
    fi
}

# Human-readable form of the pinned invocation, for messages and status output.
# Thin alias for the shared qmd_bin_desc() in scripts/lib/qmd-bin.sh (public-PR
# CR): this and qmd-reindex.sh's qmd_desc() were byte-identical copies, so the
# format lived in two places. Kept as a local name so the three call sites read
# unchanged.
qmd_invocation_desc() { qmd_bin_desc; }

cmd_arm() {
    validate_arm_inputs
    cadence_require_wsh "qmd-cadence" || exit 2

    # Resolve bash to an absolute Windows path so the .bat invokes the Git-Bash
    # interpreter directly — NOT the bare `bash` that resolves to the WSL
    # System32 stub in a fresh cmd.exe.
    local bash_posix bash_win
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR qmd-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR qmd-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR qmd-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi

    # bash consumes these paths (POSIX/mixed C:/ form via cygpath -m, which
    # Git-Bash reads); the himmel cd target is a Windows path.
    local script_mixed qmd_mixed qmd_js_mixed="" himmel_win
    if ! script_mixed=$(cygpath -m "$RUNNER_SCRIPT" 2>&1); then
        echo "ERR qmd-cadence: cygpath -m failed for runner script: $script_mixed" >&2
        exit 4
    fi
    if ! qmd_mixed=$(cygpath -m "$QMD_BIN" 2>&1); then
        echo "ERR qmd-cadence: cygpath -m failed for qmd path: $qmd_mixed" >&2
        exit 4
    fi
    if [ -n "$QMD_JS" ] && ! qmd_js_mixed=$(cygpath -m "$QMD_JS" 2>&1); then
        echo "ERR qmd-cadence: cygpath -m failed for qmd script path: $qmd_js_mixed" >&2
        exit 4
    fi
    if ! himmel_win=$(cygpath -w "$HIMMEL_ROOT" 2>&1); then
        echo "ERR qmd-cadence: cygpath -w failed for himmel root: $himmel_win" >&2
        exit 4
    fi

    # Dedup guard — never double-register the cadence.
    local existing
    existing=$(list_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "qmd-cadence: --force set; replacing existing task(s):" >&2
            local marker
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "  $marker" >&2
                if [ "$DRY_RUN" -eq 0 ]; then
                    delete_task "$marker"
                    # Track that the OLD cadence is already gone, so a later
                    # create failure can say so plainly (see the exit-4 path).
                    REPLACED_EXISTING=1
                else
                    echo "DRY qmd-cadence: would delete $marker"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR qmd-cadence: HIMMEL-Qmd-* task(s) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/qmd-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    # cmd-escape EVERY path value interpolated into the .bat payload — the bash
    # interpreter path included. It is the least likely of the three to contain
    # a cmd metacharacter (typically C:\Program Files\Git\bin\bash.exe), but
    # "unlikely" is not "escaped": a `%` anywhere in the resolved path would be
    # expanded by cmd.exe at fire time instead of taken literally, and leaving
    # one of three interpolated values unescaped is the kind of asymmetry that
    # reads as intentional later. (The graphmap sibling used to leave its bash
    # path raw — HIMMEL-1281 closed that divergence in graphmap's favour of
    # this one, so all four emitters now escape every interpolated value.)
    local bash_win_esc script_esc qmd_esc himmel_win_esc qmd_js_esc="" git_bin_esc
    bash_win_esc=$(cadence_cmd_escape "$bash_win")
    # Git's usr\bin + bin, derived from the bash.exe path above (HIMMEL-1672):
    # prepended to PATH in emit_bat so the non-login bash.exe finds GNU coreutils
    # ahead of System32. Empty for a non-Git bash → emit_bat then omits the line.
    git_bin_esc=$(cadence_cmd_escape "$(cadence_git_bin_path_win "$bash_win")")
    script_esc=$(cadence_cmd_escape "$script_mixed")
    qmd_esc=$(cadence_cmd_escape "$qmd_mixed")
    himmel_win_esc=$(cadence_cmd_escape "$himmel_win")
    [ -n "$qmd_js_mixed" ] && qmd_js_esc=$(cadence_cmd_escape "$qmd_js_mixed")

    # --qmd-js rides along only when the bun-served install won the resolver
    # (HIMMEL-1283); a PATH-qmd pin emits the single-token form unchanged.
    local payload
    payload="\"$bash_win_esc\" \"$script_esc\" --qmd-bin \"$qmd_esc\""
    [ -n "$qmd_js_esc" ] && payload="$payload --qmd-js \"$qmd_js_esc\""
    # --ship-to (HIMMEL-1286): the runner is ship-index.sh, which takes the SAME
    # --qmd-bin/--qmd-js pin and forwards it to its own reindex leg — that
    # passthrough is what makes an unattended ship possible at all, since the
    # resolver needs bun on PATH and a scheduler has none. The host is escaped
    # like every other interpolated value (HIMMEL-1281 closed the divergence
    # where one emitter left a value raw).
    if [ -n "$SHIP_TO" ]; then
        local ship_to_esc
        ship_to_esc=$(cadence_cmd_escape "$SHIP_TO")
        payload="$payload --host \"$ship_to_esc\""
    fi

    local bat="$BAT_DIR/qmd-reindex.bat"
    # wscript //B shim (HIMMEL-1753) lives beside the .bat; disarm removes both.
    # Derived from the .bat Windows path through cadence_vbs_path — the same
    # helper emit_task_xml derives the referenced path with.
    local vbs="$BAT_DIR/qmd-reindex.vbs"

    # Fire-time run log lives next to the .bat (cmd-escaped for the `>>` target).
    local bat_dir_win log_esc
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR qmd-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    log_esc=$(cadence_cmd_escape "$bat_dir_win\\qmd-reindex.log")

    # The .bat runner is the task's Exec Command. cygpath -w is a pure string
    # transform (the .bat need not exist yet), so resolve the win path before the
    # dry-run preview too.
    local bat_win
    if ! bat_win=$(cygpath -w "$bat" 2>&1); then
        echo "ERR qmd-cadence: cygpath -w failed: $bat_win" >&2
        exit 4
    fi

    local sched rep
    sched=$(schedule_daily_xml)
    rep=""
    [ "$HOURLY" -eq 1 ] && rep=$(repetition_xml)

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY qmd-cadence: would write $bat:"
        emit_bat "$himmel_win_esc" "$payload" "$log_esc" "$git_bin_esc" | sed 's/^/    /'
        echo "DRY qmd-cadence: would write $vbs:"
        cadence_vbs_wrapper "$bat_win" | sed 's/^/    /'
        echo "DRY qmd-cadence: would schtasks /create /tn $TASK_REINDEX /xml <$CADENCE_DESC, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_win" "$REINDEX_TIME" "$sched" "$rep" | sed 's/^/    /'
        echo "qmd-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the .bat + .vbs shim and promote (mv) them only once complete —
    # the same discipline the POSIX path applies to its runner. Writing in
    # place would expose a half-written file to a task firing concurrently
    # with a re-arm; staging in the same directory makes each promotion an
    # atomic same-filesystem rename, so the FINAL paths only ever hold a
    # complete file (old or new). Staged files are cleaned on every path.
    local tmp_bat="$bat.tmp.$$" tmp_vbs="$vbs.tmp.$$"
    emit_bat "$himmel_win_esc" "$payload" "$log_esc" "$git_bin_esc" > "$tmp_bat"
    cadence_vbs_wrapper "$bat_win" > "$tmp_vbs"

    # HIMMEL-1753 (CR codex-1): publish the runner .bat AND its .vbs shim BEFORE
    # registering the task. These tasks carry StartWhenAvailable=true, so a run
    # missed while the PC was off can fire the moment the task is created — and
    # if the shim were still staged at that point the task would reference a
    # missing path (first arm) or the previous shim (re-arm). Promoting first
    # means the only failure mode is an unarmed task beside an unused runner,
    # which is inert; the reverse is an armed task pointing at nothing.
    # HIMMEL-1753 round 2 (codex-1): the promotions are CHECKED — an unchecked
    # mv that failed silently fell through to registering the task anyway, the
    # exact armed-at-nothing state the ordering above exists to prevent. A
    # non-regular final path is refused as well: `mv` onto a directory
    # "succeeds" by moving the staged file INSIDE it, so the rename alone
    # cannot catch a target the task could never run.
    local final
    for final in "$bat" "$vbs"; do
        if [ -e "$final" ] && [ ! -f "$final" ]; then
            echo "ERR qmd-cadence: $final exists and is not a regular file — refusing to publish" >&2
            rm -f "$tmp_bat" "$tmp_vbs"
            if [ "$REPLACED_EXISTING" -eq 1 ]; then
                echo "    WARNING: --force already removed the previously armed task — NO qmd cadence is armed now." >&2
            fi
            exit 4
        fi
    done
    if ! mv -f "$tmp_bat" "$bat"; then
        echo "ERR qmd-cadence: failed to promote staged runner to $bat — no task armed" >&2
        rm -f "$tmp_bat" "$tmp_vbs"
        if [ "$REPLACED_EXISTING" -eq 1 ]; then
            echo "    WARNING: --force already removed the previously armed task — NO qmd cadence is armed now." >&2
        fi
        exit 4
    fi
    if ! mv -f "$tmp_vbs" "$vbs"; then
        echo "ERR qmd-cadence: failed to promote staged shim to $vbs — no task armed" >&2
        rm -f "$tmp_vbs"
        if [ "$REPLACED_EXISTING" -eq 1 ]; then
            echo "    WARNING: --force already removed the previously armed task — NO qmd cadence is armed now." >&2
        fi
        exit 4
    fi

    local err_file
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_REINDEX" "$sched" "$REINDEX_TIME" "$bat_win" "$err_file" "$rep"; then
        echo "ERR qmd-cadence: schtasks /create $TASK_REINDEX failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    runner .bat + .vbs shim were published, but NO task was armed" >&2
        # Under --force the OLD task was already deleted above, so this failure
        # leaves the machine with NO cadence armed. Say so plainly: the .bat
        # line alone reads as "nothing changed", which is the opposite of true.
        if [ "$REPLACED_EXISTING" -eq 1 ]; then
            echo "    WARNING: --force already removed the previously armed task, and this" >&2
            echo "    create failed — NO qmd cadence is armed right now. Re-run:" >&2
            echo "        bash scripts/luna/qmd-cadence.sh arm" >&2
        fi
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file"

    cat <<EOF

================================================================
  QMD REINDEX CADENCE ARMED (HIMMEL-568)
  $TASK_REINDEX  $CADENCE_DESC  -> $RUNNER_DESC
  Scope:  all configured qmd collections
  qmd:    $(qmd_invocation_desc)
  Himmel: $HIMMEL_ROOT
  Runner .bat: $BAT_DIR

  The task fires bash + $RUNNER_NAME directly (no claude session).
  StartWhenAvailable=true: a run missed because the PC was off/asleep
  fires when the PC is next on. Disarm anytime with:
      bash scripts/luna/qmd-cadence.sh disarm
================================================================
EOF
}

# --- POSIX (cron) implementation -------------------------------------------
#
# Same arm/status/disarm contract as the schtasks path, against the user
# crontab. The runner .sh mirrors the .bat: log rotation, fire stamp,
# cd-into-himmel, then bash + qmd-reindex.sh.

CRON_RUNNER="$BAT_DIR/qmd-reindex.sh"

# Shell-quote a value for a cron command line (mirrors the sibling cadences'
# cron_escape): printf %q survives the /bin/sh re-parse; the extra % -> \% pass
# is cron(5) syntax. Control characters are rejected (rc=2).
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR qmd-cadence: cron_escape: argument contains control characters — rejected" >&2
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
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR qmd-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
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
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR qmd-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    rejected crontab left at: $tab_file" >&2
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged cadence lines in the current CRON_TAB (empty if none).
cron_existing() {
    printf '%s\n' "$CRON_TAB" | grep -F "$TASK_PREFIX" || true
}

# Emit the runner .sh body: stamp the format version, rotate the run log, stamp
# the fire time, cd into the himmel root, then fire the payload with output
# captured to the log. No PATH prepend is needed — unlike the graphmap sibling
# (whose graphify backend spawns `claude` and therefore needs it discoverable),
# we hand qmd's absolute path to the runner as --qmd-bin.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh
emit_runner() {
    local name="$1" payload="$2" q_log="$3" q_himmel="$4"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by qmd-cadence.sh arm (HIMMEL-568)\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    printf 'log=%s\n' "$q_log"
    # SELF-OVERLAP GUARD (cron only). The Windows task carries
    # MultipleInstancesPolicy=IgnoreNew, which is what lets the payload take no
    # lock of its own; cron has no equivalent, so this leg was unguarded — and
    # under --ship-to that is not merely a wasted double reindex: two ship runs
    # race on the receiver's single `<target>.preship` rollback copy, so one can
    # reap the other's rollback mid-swap and leave no recoverable index.
    # Acquired BEFORE the rotation below, which is itself destructive across
    # concurrent runs (the second run rotates the first run's live log away).
    # mkdir, not a lockfile: it is the one atomic create-or-fail primitive
    # available in POSIX sh with no flock dependency (absent on macOS).
    printf 'lock="$log.lock"\n'
    printf 'if ! mkdir "$lock" 2>/dev/null; then\n'
    # NO AUTOMATIC STALE-LOCK TAKEOVER — deliberately, after three attempts at
    # one. Recovering a stale lock in shell means reading an owner pid, judging
    # it dead, and then removing a directory you do not own; every version of
    # that has an identity window between the judgement and the removal, and
    # review found a distinct bug in each:
    #   1. non-atomic takeover — two contenders both saw the dead owner and both
    #      fired.
    #   2. `mv`-claim, treating pid-less as stale — stole the lock from a LIVE
    #      owner inside the un-stamped mkdir/pid window.
    #   3. `mv`-claim with a re-read — between reading a dead pid and the mv,
    #      another contender can complete its own takeover and install a live
    #      lock, which the mv then steals; and the EXIT trap removes whatever
    #      sits at $lock, not the instance this process created.
    # Each fix produced the next, which is what a lock at the wrong layer looks
    # like. The resource being protected lives on the RECEIVER, and only the
    # receiver can see every sender, so that is where real serialization belongs
    # (HIMMEL-1306).
    #
    # So: mkdir is the whole protocol. It is atomic, this process runs ONLY if
    # its own mkdir succeeded, and nothing ever removes a lock it did not
    # create — which also scopes the EXIT trap correctly by construction. The
    # cost is that a SIGKILLed run leaves a lock behind and the cadence stops
    # until a human removes it. That is the SAFE direction: it stops LOUDLY
    # (every fire logs it, and the exit code is non-zero so cron reports it),
    # whereas the alternative fails toward two concurrent ships destroying each
    # other's rollback. A stopped cadence is also exactly what the staleness
    # guard in this same ticket exists to notice downstream.
    # Read the owner FIRST. A pid-less lock is then re-read once after a beat,
    # because mkdir and the pid write cannot be one atomic step: an owner that
    # has just won the lock is briefly un-stamped, and judging it on that first
    # empty read would call a live run abandoned.
    printf '    _prev=$(cat "$lock/pid" 2>/dev/null || echo "")\n'
    printf '    if [ -z "$_prev" ]; then\n'
    printf '        sleep 1\n'
    printf '        _prev=$(cat "$lock/pid" 2>/dev/null || echo "")\n'
    printf '    fi\n'
    printf '    if [ -n "$_prev" ] && kill -0 "$_prev" 2>/dev/null; then\n'
    printf '        echo "[skipped $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): pid $_prev still running]" >> "$log" 2>&1\n'
    printf '        exit 0\n'
    printf '    fi\n'
    printf '    echo "[BLOCKED $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): stale lock $lock (owner ${_prev:-unknown} is gone); this run did NOT fire. Remove that directory to resume the cadence.]" >> "$log" 2>&1\n'
    printf '    exit 75\n'
    printf 'fi\n'
    # Trap FIRST, then stamp. We own the lock the moment mkdir succeeded, so the
    # release must be armed before anything that can fail — otherwise a failed
    # stamp exits leaving the directory behind.
    printf 'trap '\''rm -f "$lock/pid" 2>/dev/null; rmdir "$lock" 2>/dev/null'\'' EXIT\n'
    # A failed stamp used to be swallowed with `|| true`, which turned a LIVE
    # run into a false BLOCKED for the next contender: an un-stamped lock reads
    # as empty after the 1s re-read, the contender takes the stale branch, and
    # cron gets a hard rc-75 failure naming a lock nobody needs to remove. No
    # corruption — but a misleading alarm is its own cost in a cadence whose
    # whole job is to be believed. Fail here instead; the trap above releases
    # the lock on the way out, so the next fire starts clean.
    printf 'if ! echo $$ > "$lock/pid" 2>/dev/null; then\n'
    printf '    echo "[BLOCKED $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): could not write $lock/pid (read-only or full?); refusing to run un-stamped]" >> "$log" 2>&1\n'
    printf '    exit 75\n'
    printf 'fi\n'
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    printf '    _rc=0; %s || _rc=$?\n' "$payload"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # PROPAGATE the runner's exit code (CR finding [codex-1]). Without this the
    # script's status is that of the final `echo` inside the block — i.e. ALWAYS
    # 0 — so cron (and anything else keyed on exit status) reports success after
    # a failed reindex. That is precisely the silent-failure shape this ticket
    # exists to eliminate, and it also made the two runner formats disagree: the
    # .bat path already propagates, because its last line IS the payload.
    # Deliberate divergence from the graphmap sibling, which swallows it too.
    printf 'exit "$_rc"\n'
}

cron_status() {
    cron_read
    echo "qmd-cadence status:"
    local entry sched
    entry=$(printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_REINDEX" | head -1 || true)
    if [ -n "$entry" ]; then
        sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
        echo "ARMED      $TASK_REINDEX (cron: $sched)$(task_summary "$TASK_REINDEX")"
    else
        echo "not armed  $TASK_REINDEX$(task_summary "$TASK_REINDEX")"
    fi
    status_log "$BAT_DIR/qmd-reindex.log"
}

cron_disarm() {
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER"
        fi
        echo "qmd-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY qmd-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY qmd-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t qmd-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" > "$newtab" || true
    # Install must succeed BEFORE the runner is removed — a failed install leaves
    # the entry live and it must keep pointing at an existing runner.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER"
    echo "qmd-cadence: cadence disarmed"
}

cron_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute path so the runner doesn't depend on cron's
    # minimal PATH.
    local bash_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR qmd-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi

    # Dedup guard — never double-register the cadence.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "qmd-cadence: --force set; replacing existing cadence entry:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY qmd-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR qmd-cadence: HIMMEL-Qmd-* crontab entr(ies) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/qmd-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_bash q_script q_qmd q_himmel q_log q_qmd_js=""
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$RUNNER_SCRIPT")
    q_qmd=$(printf '%q' "$QMD_BIN")
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_log=$(printf '%q' "$BAT_DIR/qmd-reindex.log")
    [ -n "$QMD_JS" ] && q_qmd_js=$(printf '%q' "$QMD_JS")

    # Same two-token pin as the Windows path (HIMMEL-1283): --qmd-js only when
    # the bun-served install won the resolver.
    local payload
    payload="$q_bash $q_script --qmd-bin $q_qmd"
    [ -n "$q_qmd_js" ] && payload="$payload --qmd-js $q_qmd_js"
    # Mirror of the Windows branch above (HIMMEL-1286), differing only in the
    # escaping this path uses.
    if [ -n "$SHIP_TO" ]; then
        local q_ship_to
        q_ship_to=$(printf '%q' "$SHIP_TO")
        payload="$payload --host $q_ship_to"
    fi

    local hh mm
    hh="${REINDEX_TIME%:*}"; mm="${REINDEX_TIME#*:}"
    local q_runner entry
    q_runner=$(cron_escape "$CRON_RUNNER")
    if [ "$HOURLY" -eq 1 ]; then
        # Hourly forever: fixed minute, every hour — mirrors graphmap-cadence's
        # AST-himmel cron entry (HIMMEL-1948), the cron(5) idiom for "hourly"
        # since cron has no repetition construct to layer on top like schtasks.
        entry="$mm * * * * $q_runner # $TASK_REINDEX"
    else
        entry="$mm $hh * * * $q_runner # $TASK_REINDEX"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY qmd-cadence: would write $CRON_RUNNER:"
        emit_runner "$TASK_REINDEX" "$payload" "$q_log" "$q_himmel" | sed 's/^/    /'
        echo "DRY qmd-cadence: would add crontab entry:"
        echo "    $entry"
        echo "qmd-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runner at a temp path and promote (mv) it only after the crontab
    # install succeeds: writing it in place first would let a failed install
    # (exit 4) leave the OLD crontab live while the runner file already carries
    # the NEW config — a silent half-state under --force re-arm.
    local tmp_runner="$CRON_RUNNER.tmp.$$"
    emit_runner "$TASK_REINDEX" "$payload" "$q_log" "$q_himmel" > "$tmp_runner"
    chmod +x "$tmp_runner"

    # Single atomic rewrite: everything that isn't ours, then our entry.
    local newtab
    newtab=$(mktemp -t qmd-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        rm -f "$tmp_runner"
        echo "    existing runner file left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_runner" "$CRON_RUNNER"

    cat <<EOF

================================================================
  QMD REINDEX CADENCE ARMED (HIMMEL-568, cron)
  $TASK_REINDEX  $CADENCE_DESC  -> $RUNNER_DESC
  Scope:  all configured qmd collections
  qmd:    $(qmd_invocation_desc)
  Himmel: $HIMMEL_ROOT
  Runner .sh: $BAT_DIR

  The entry fires bash + $RUNNER_NAME directly (no claude session).
  Disarm anytime:
      bash scripts/luna/qmd-cadence.sh disarm
================================================================
EOF
}

case "$SUBCMD" in
    arm)    if [ "$PLATFORM" = "windows" ]; then cmd_arm;    else cron_arm;    fi ;;
    status) if [ "$PLATFORM" = "windows" ]; then cmd_status; else cron_status; fi ;;
    disarm) if [ "$PLATFORM" = "windows" ]; then cmd_disarm; else cron_disarm; fi ;;
esac
