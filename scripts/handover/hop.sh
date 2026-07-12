#!/usr/bin/env bash
# hop.sh — invocable mid-session jump to a fresh claude session (HIMMEL-130).
#
# Sibling of scripts/handover/arm-resume.sh. arm-resume is *cron-armed*
# (schtasks ONCE at a future time, operator chooses the time, dedup-
# guarded). hop is *operator-invoked NOW* — used when the current
# session approaches the context-window budget (typically 75-80%) and
# the operator wants to /exit and pick up in a clean session without
# losing state.
#
# Two execution modes, both produce + save a snapshot handover file
# first:
#
#   --schedule [--delay <minutes>]  (DEFAULT)
#       Hand off to arm-resume.sh --time <now+delay> --force, which
#       spawns the new claude via the OS scheduler. Default delay is 2
#       minutes — gives the operator time to /exit the current session
#       cleanly before the new one fires. Reuses arm-resume's tested
#       cd-into-repo + dedup + MSYS_NO_PATHCONV path (PRs #137, #139).
#
#   --print
#       Don't schedule anything. Just write the snapshot + print the
#       claude command the operator should run in a fresh terminal.
#       Use this when the operator wants to start the new session
#       interactively in a separate terminal tab/window.
#
# Snapshot:
#   Written to <handover-root>/context-hop-<UTC-timestamp>.md. Includes
#   only the metadata + the cold-start prompt — the operator is
#   expected to update the snapshot with the current todo state before
#   hopping (the slash command at .claude/commands/context-hop.md
#   prompts for this). If --message <text> is passed, the text is
#   embedded into the snapshot body.
#
# Usage:
#   bash scripts/handover/hop.sh [--message "what to pick up"] [--delay 2] [--print] [--dry-run]
#
# Optional:
#   --handover-root <dir>  Override snapshot destination. Default: the shared
#                          resolver (HANDOVER_DIR Mode B, else <repo>/handovers)
#                          joined to your USER_SLUG.
#   --message <text>       Text embedded into the snapshot body.
#                          Use this for "load this todo list" handoffs.
#   --delay <minutes>      Schedule mode only. Default 2.
#   --print                Don't schedule; print command to run manually.
#   --dry-run              Print what would be written + the command,
#                          touch no files.
#   --force                Pass --force through to arm-resume.sh
#                          (replace an existing HIMMEL-Resume-* job).
#
# Exit codes:
#   0  hop initiated (snapshot written + scheduled/printed)
#   1  usage / input error
#   2  env unusable (no claude on PATH, no handover root resolvable)
#   3  dedup block (existing HIMMEL-Resume-* and --force not passed)
#   4  scheduler invocation failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
# shellcheck source=../lib/user-slug.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/user-slug.sh"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

# HIMMEL-335: pull HANDOVER_DIR / USER_SLUG from <repo>/.env when the
# launching shell didn't export them (a live env value still wins). Makes
# .env a real config source for the handover root instead of a hardcode.
load_dotenv HANDOVER_DIR USER_SLUG

MESSAGE=""
DELAY_MINUTES=2
MODE=schedule
DRY_RUN=0
FORCE=0
HANDOVER_ROOT=""

# Capture ORIGIN repo BEFORE any work — this is the repo claude should
# run from in the relaunched session. The snapshot lives under the
# handover root (often a separate state repo), but arm-resume's default
# RESUME_CWD derivation would land claude in that repo (wrong repo). Pass
# through arm-resume's --cwd flag to override.
if ! ORIGIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null); then
    ORIGIN_REPO="$(pwd)"
fi

usage() {
    cat <<'EOF'
Usage: hop.sh [--message <text>] [--delay <minutes>] [--print] [--dry-run] [--force]
              [--handover-root <dir>]

Mid-session jump to a fresh claude session. Writes a context-hop
snapshot then either schedules a relaunch via arm-resume.sh (default)
or prints the command to run manually (--print).

Default: writes the snapshot under the resolved handover root
(<HANDOVER_DIR or repo/handovers>/<USER_SLUG>/context-hop-<ts>.md), then
schedules a relaunch in 2 minutes via arm-resume.sh.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --message)         MESSAGE="${2:-}"; shift 2 ;;
        --message=*)       MESSAGE="${1#--message=}"; shift ;;
        --delay)           DELAY_MINUTES="${2:-}"; shift 2 ;;
        --delay=*)         DELAY_MINUTES="${1#--delay=}"; shift ;;
        --print)           MODE=print; shift ;;
        --schedule)        MODE=schedule; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --force)           FORCE=1; shift ;;
        --handover-root)   HANDOVER_ROOT="${2:-}"; shift 2 ;;
        --handover-root=*) HANDOVER_ROOT="${1#--handover-root=}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo "ERR hop: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$DELAY_MINUTES" =~ ^[0-9]+$ ]] || [ "$DELAY_MINUTES" -lt 1 ] || [ "$DELAY_MINUTES" -gt 60 ]; then
    echo "ERR hop: --delay must be an integer in [1, 60], got: $DELAY_MINUTES" >&2
    exit 1
fi

# Resolve handover root. Priority:
#   1. --handover-root flag (explicit override; used verbatim)
#   2. shared resolver (HANDOVER_DIR Mode B, else <repo>/handovers inline)
#      joined to the operator's user slug — <state-root> = <root>/<slug>.
if [ -z "$HANDOVER_ROOT" ]; then
    if ! _hop_root=$(handover_root); then
        echo "ERR hop: cannot resolve handover root." >&2
        echo "    Set HANDOVER_DIR (in .env or the launching shell) or pass" >&2
        echo "    --handover-root <existing-dir>." >&2
        exit 2
    fi
    if ! _hop_slug=$(user_slug); then
        echo "ERR hop: cannot resolve USER_SLUG (set it in .env or the" >&2
        echo "    launching shell), or pass --handover-root <existing-dir>." >&2
        exit 2
    fi
    HANDOVER_ROOT="$_hop_root/$_hop_slug"
fi
if [ ! -d "$HANDOVER_ROOT" ]; then
    echo "ERR hop: handover root does not exist: $HANDOVER_ROOT" >&2
    echo "    Set HANDOVER_DIR or pass --handover-root <existing-dir>." >&2
    exit 2
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "ERR hop: 'claude' not on PATH" >&2
    exit 2
fi

# UTC timestamp for the snapshot filename. Avoid colons (Windows-hostile).
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAPSHOT="$HANDOVER_ROOT/context-hop-$TS.md"
RESUME_PROMPT="load $SNAPSHOT context-hop mode"

write_snapshot() {
    local target="$1"
    {
        printf -- '---\n'
        printf -- 'session_kind: context-hop snapshot\n'
        printf -- 'created_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf -- 'created_from_cwd: %s\n' "$(pwd)"
        printf -- 'hop_mode: %s\n' "$MODE"
        printf -- 'delay_minutes: %s\n' "$DELAY_MINUTES"
        printf -- '---\n\n'
        printf -- '# Context-hop snapshot\n\n'
        printf -- 'The previous session hopped here because its context window\n'
        printf -- 'was approaching the soft budget. Pick up from the message\n'
        printf -- 'below + the live state in this repo.\n\n'
        printf -- '## Operator message (passed via --message)\n\n'
        if [ -n "$MESSAGE" ]; then
            printf -- '%s\n\n' "$MESSAGE"
        else
            printf -- '_(none — operator did not pass --message; ask them what to pick up)_\n\n'
        fi
        printf -- '## Origin\n\n'
        printf -- '- Hopped from: %s\n' "$(pwd)"
        printf -- '- Origin repo (relaunch cwd): %s\n' "$ORIGIN_REPO"
        printf -- '- Git state: %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo not-a-git-repo) @ $(git rev-parse --short HEAD 2>/dev/null || echo no-head)"
        # shellcheck disable=SC2016  # backticks here are inline markdown, not shell substitution
        printf -- '- Open PRs: query via `gh pr list --author @me`\n'
        # shellcheck disable=SC2016
        printf -- '- See `%s/next-session-resume.md` for the persistent next-session plan.\n\n' "$HANDOVER_ROOT"
        printf -- '## Cold-start prompt for the hopped session\n\n'
        printf -- '```\n'
        printf -- 'Cold-start context-hop. Read this snapshot top-to-bottom.\n'
        printf -- 'Pick up from the operator message above. Your cwd is the\n'
        printf -- 'origin repo recorded in the Origin section. Active state\n'
        printf -- 'of the origin session is in\n'
        printf -- '%s/next-session-resume.md.\n' "$HANDOVER_ROOT"
        printf -- '```\n'
    } > "$target"
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY hop: would write snapshot to $SNAPSHOT"
    echo "DRY hop: snapshot body:"
    write_snapshot /dev/stdout | sed 's/^/    /'
    case "$MODE" in
        schedule)
            local_hh_mm=$(date -d "+$DELAY_MINUTES minutes" +%H:%M 2>/dev/null \
                || date -v "+${DELAY_MINUTES}M" +%H:%M 2>/dev/null \
                || echo "now+${DELAY_MINUTES}m")
            # FORCE defaults to "0" (non-empty), so `${FORCE:+ --force}`
            # always expands — use an explicit integer check.
            force_flag=""
            [ "$FORCE" -eq 1 ] && force_flag=" --force"
            echo "DRY hop: would invoke: bash scripts/handover/arm-resume.sh --time $local_hh_mm --handover '$SNAPSHOT' --cwd '$ORIGIN_REPO'$force_flag"
            ;;
        print)
            echo "DRY hop: would print operator command:"
            echo "    claude \"$RESUME_PROMPT\""
            ;;
    esac
    exit 0
fi

# HIMMEL-143: best-effort flush pass before snapshot so cap-resume
# hand-off cannot leave un-pushed handover state. Failures inside
# flush.sh are absorbed (`|| true`) — hop must never fail because of
# a flush-layer issue. The snapshot write below is the load-bearing
# step.
flush_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/flush.sh"
if [ -f "$flush_script" ]; then
    echo "hop: running handover-flush sweep before snapshot..."
    bash "$flush_script" 2>&1 | sed 's/^/hop (flush): /' || true
fi

write_snapshot "$SNAPSHOT"
echo "hop: wrote snapshot: $SNAPSHOT"

case "$MODE" in
    schedule)
        # Compute now+delay in HH:MM. date -d works on GNU coreutils
        # (Linux, Git Bash); date -v works on BSD (macOS).
        if hop_time=$(date -d "+$DELAY_MINUTES minutes" +%H:%M 2>/dev/null); then
            :
        elif hop_time=$(date -v "+${DELAY_MINUTES}M" +%H:%M 2>/dev/null); then
            :
        else
            echo "ERR hop: could not compute now+${DELAY_MINUTES}min via date -d or date -v" >&2
            exit 2
        fi
        echo "hop: scheduling relaunch at $hop_time (now + ${DELAY_MINUTES}min) via arm-resume.sh"
        echo "hop: relaunched session will cd into origin repo: $ORIGIN_REPO"
        arm_args=(--time "$hop_time" --handover "$SNAPSHOT" --cwd "$ORIGIN_REPO")
        [ "$FORCE" -eq 1 ] && arm_args+=(--force)
        if ! bash "$ORIGIN_REPO/scripts/handover/arm-resume.sh" "${arm_args[@]}"; then
            rc=$?
            echo "ERR hop: arm-resume.sh failed (rc=$rc) — snapshot written but no relaunch scheduled" >&2
            echo "    Snapshot is still at: $SNAPSHOT" >&2
            echo "    Resume manually: claude \"$RESUME_PROMPT\"" >&2
            exit "$rc"
        fi
        cat <<EOF

================================================================
  CONTEXT-HOP ARMED
  Snapshot: $SNAPSHOT
  Relaunch: $hop_time (now + ${DELAY_MINUTES}min)

  PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW.

  The scheduler will spawn a NEW claude process at the scheduled
  time. Closing now gives the next session a clean prompt cache
  and avoids two concurrent claude processes operating on the
  same handover state.
================================================================
EOF
        ;;
    print)
        cat <<EOF

================================================================
  CONTEXT-HOP SNAPSHOT WRITTEN
  Snapshot: $SNAPSHOT

  No relaunch was scheduled (--print mode). To pick up in a fresh
  terminal:

      claude "$RESUME_PROMPT"

  PLEASE /exit YOUR CURRENT CLAUDE SESSION BEFORE STARTING THE
  NEW ONE so they don't compete on the same handover state.
================================================================
EOF
        ;;
esac

exit 0
