#!/usr/bin/env bash
# auto-action.sh <op> <arg> <time> — privileged remote auto-action executor (HIMMEL-424 B2).
#
# The TRUSTED Telegram bridge invokes this DIRECTLY (argv array) after parsing a
# structured `/arm` command; the spawned `claude` agent is never in the trust path.
# This script owns the privileged half: resolve a ticket|path to a resume handover,
# then shell arm-resume.sh. It runs in the real himmel shell environment (.env,
# handover-path.sh, py-armor, schtasks) — "inherit the system".
#
# Exit-code namespace (kept DISTINCT from arm-resume's own rc space so a dedup/
# already-armed result doesn't collide with a resolution failure):
#   0  armed
#   1  bad input (missing args / bad time)
#   2  unknown op (closed op allow-list, defense-in-depth)
#   3  no resume handover / bad path / path outside handover_root
#   4  ambiguous (>1 genuine handover — never silently pick)
#   5  already armed (arm-resume dedup rc=3)
#   6  arm-resume failed (any other non-zero)
#
# Args ALWAYS land as the VALUE of `arm-resume --handover`, never a bare positional
# (so a path like `--force` can't be misread as a flag). Test seam:
# AUTO_ACTION_ARM_CMD overrides the arm command (default the real arm-resume.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OP="${1:-}"; ARG="${2:-}"; TIME="${3:-}"
if [ -z "$OP" ] || [ -z "$ARG" ] || [ -z "$TIME" ]; then
    echo "ERR auto-action: usage: auto-action.sh <op> <arg> <time>" >&2
    exit 1
fi

# Closed op allow-list (defense-in-depth vs the bridge parse layer).
case "$OP" in
    arm-resume) ;;
    *) echo "ERR auto-action: unknown op: $OP" >&2; exit 2 ;;
esac

# Validate time FIRST (identical regex to arm-resume's HH:MM, so the early reject
# can't diverge from the real validator).
case "$TIME" in
    smart|auto) ;;
    *)
        if ! printf '%s' "$TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
            echo "ERR auto-action: bad time '$TIME' (expected HH:MM, 'auto', or 'smart')" >&2
            exit 1
        fi
        ;;
esac

# Resolve the handover root via the shared resolver (subtree hard rule: never
# hardcode ./handovers/ — source handover-path.sh + call handover_root).
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
if ! ROOT=$(handover_root); then
    echo "ERR auto-action: handover_root unresolved (set HANDOVER_DIR or create handovers/)" >&2
    exit 3
fi
ROOT=$(realpath "$ROOT" 2>/dev/null) || ROOT=$(cd "$ROOT" && pwd)

RESOLVED=""
if printf '%s' "$ARG" | grep -Eq '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    # Ticket: case-insensitive match (files are lowercase, the arg is upper),
    # EXCLUDE anything under a specs/ path (design/plan docs are not resume
    # targets), then PREFER files carrying `type: handover` frontmatter.
    _matches=()
    while IFS= read -r _f; do
        [ -n "$_f" ] && _matches+=("$_f")
    done < <(find "$ROOT" -type f -iname "*$ARG*.md" 2>/dev/null | grep -v '/specs/' | sort)
    if [ "${#_matches[@]}" -eq 0 ]; then
        echo "ERR auto-action: no resume handover for $ARG" >&2
        exit 3
    fi
    _preferred=()
    for _f in "${_matches[@]}"; do
        if head -20 "$_f" 2>/dev/null | grep -qiE '^type:[[:space:]]*handover[[:space:]]*$'; then
            _preferred+=("$_f")
        fi
    done
    _pool=("${_matches[@]}")
    [ "${#_preferred[@]}" -gt 0 ] && _pool=("${_preferred[@]}")
    if [ "${#_pool[@]}" -gt 1 ]; then
        # Never silently pick among genuine handovers — list basenames and refuse.
        _list=""
        for _f in "${_pool[@]}"; do _list="${_list:+$_list, }$(basename "$_f")"; done
        echo "$_list" >&2
        exit 4
    fi
    RESOLVED="${_pool[0]}"
else
    # Path: must exist AND canonicalize UNDER handover_root (containment, fix I3 —
    # blocks /etc/passwd and ../../x, which arm-resume would otherwise read
    # resume_cwd/resume_worktree frontmatter from). Fail closed if realpath is
    # unavailable (can't verify containment).
    if [ ! -e "$ARG" ]; then
        echo "ERR auto-action: path not found: $ARG" >&2
        exit 3
    fi
    if ! _real=$(realpath "$ARG" 2>/dev/null) || [ -z "$_real" ]; then
        echo "ERR auto-action: could not canonicalize path (containment unverifiable): $ARG" >&2
        exit 3
    fi
    case "$_real" in
        "$ROOT"/*) RESOLVED="$_real" ;;
        *) echo "ERR auto-action: path outside handover_root: $ARG" >&2; exit 3 ;;
    esac
fi

# Machine-readable line the bridge parses for the audit + reply.
echo "resolved=$(basename "$RESOLVED")"

# Invoke arm-resume.sh with the resolved handover as the --handover VALUE. Strip the
# bot token (and TELEGRAM_OWN_POLLER) from the child env (M3 — arm doesn't need them).
# Default per-handover dedup; no --force, no --dedup-any (remote arms can't force/clobber).
ARM_CMD="${AUTO_ACTION_ARM_CMD:-bash $SCRIPT_DIR/../handover/arm-resume.sh}"
# ARM_CMD is an intentional command+args split — word-splitting wanted.
# shellcheck disable=SC2086
out=$(TELEGRAM_BOT_TOKEN="" TELEGRAM_OWN_POLLER="" $ARM_CMD --handover "$RESOLVED" --time "$TIME" 2>&1)
arm_rc=$?

case "$arm_rc" in
    0) exit 0 ;;
    3) echo "ERR auto-action: already armed for $(basename "$RESOLVED")" >&2; exit 5 ;;
    *) echo "ERR auto-action: arm-resume failed (rc=$arm_rc): $(printf '%s' "$out" | tail -1)" >&2; exit 6 ;;
esac
