#!/usr/bin/env bash
# check-update-available.sh — SessionStart hook: nudge the operator when the
# himmel checkout is behind its upstream (HIMMEL-413).
#
# WHY this exists: himmel updates (hooks, commands, CLAUDE.md) only land via
# git pull — autoUpdate never covers them (see docs/setup/updating.md). Without
# a session-start nudge the operator may run stale code for days without
# noticing. This hook announces the gap once per throttle interval so the cost
# stays low (one git fetch at most every 4 h per machine).
#
# Fail OPEN on everything: no git repo, no upstream, offline, git error, stat
# error, any other unexpected state → exit 0, empty stdout. Never block.
#
# NON-GIT INSTALLS (HIMMEL-3247): a tarball / native-package install has no .git
# for the checks above to read, and used to fall out at "no git repo" — silent,
# so the install rotted unannounced. When THIS script's own install root has no
# .git, it compares VERSION against the latest release tag instead (see
# scripts/lib/release-check.sh) using the same cache-then-detached-refresh shape.
# Still fail OPEN — never blocks — but "the check could not run" is NOT allowed to
# look like "up to date": once no check has succeeded for UPDATE_CHECK_STALE
# seconds the nudge says so, with the reason.
#
# Throttle model (mirrors auto-arm-on-cap.sh):
#   - State dir: UPDATE_CHECK_STATE_DIR, else the himmelctl cache dir
#     (HIMMELCTL_CACHE_DIR, default ~/.claude/himmel — the same resolution
#     himmelctl and scripts/uninstall.sh use, so uninstall removes what this
#     writes). NOT /tmp/claude (HIMMEL-3260): the non-git "could not check" line
#     below measures from a first-attempt stamp, and a reboot clears /tmp — an
#     offline machine that reboots inside the stale window would never reach it
#     and would stay silent, which is the state this check exists to end. A
#     stamp left in /tmp/claude by an older version is ignored (never read, never
#     deleted): the window simply starts fresh here.
#   - Stamp file: <state-dir>/himmel-update-check-last  (mtime = last check).
#   - Interval: UPDATE_CHECK_INTERVAL seconds (default 14400 = 4 h).
#   - IMPORTANT: stamp is written / touch'd BEFORE the network fetch so a
#     hung git fetch never wedges future checks (operator restarts a session,
#     hung job from the previous run holds the interval open).
#   - The fetch itself is DETACHED (HIMMEL-1844): the count is read from the
#     LOCAL remote-tracking refs, and the fetch only refreshes them for the
#     NEXT check. Nothing here touches the network on the session-start path,
#     so this hook can no longer be killed mid-run by the harness timeout.
#     First run on a fresh clone therefore sees pre-fetch refs and is silent.
#
# Env knobs (all optional):
#   UPDATE_CHECK_DISABLE=1           kill switch
#   UPDATE_CHECK_INTERVAL            seconds between checks (default 14400)
#   UPDATE_CHECK_STATE_DIR           state dir override (test seam; default
#                                    $HIMMELCTL_CACHE_DIR or ~/.claude/himmel)
#   UPDATE_CHECK_STALE               non-git only: seconds without a successful release
#                                    check before saying so (default 604800 = 7 days)
#
# Stdout contract (SessionStart):
#   Exit 0 + any stdout → injected as additional context for Claude.
#   Exit non-zero → blocks the session (we never do this; always exit 0).
#
# Bash 3.2 compatible.

set -euo pipefail

# Always exit clean; never block a session.
trap 'exit 0' ERR

# ─── kill switch ────────────────────────────────────────────────────────────
[ "${UPDATE_CHECK_DISABLE:-0}" = "1" ] && exit 0

# ─── config ─────────────────────────────────────────────────────────────────
STATE_DIR="${UPDATE_CHECK_STATE_DIR:-${HIMMELCTL_CACHE_DIR:-${HOME:-/tmp}/.claude/himmel}}"
INTERVAL="${UPDATE_CHECK_INTERVAL:-14400}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=14400 ;; esac
STALE="${UPDATE_CHECK_STALE:-604800}"
case "$STALE" in ''|*[!0-9]*) STALE=604800 ;; esac

STAMP="$STATE_DIR/himmel-update-check-last"

# ─── mtime helper (Bash 3.2 + macOS BSD stat + GNU stat) ────────────────────
# Returns the mtime as epoch seconds, or empty on error.
# Pattern taken from scripts/statusline/bin/statusline.sh.
_mtime() {
    local f="$1" t=""
    # GNU stat
    t=$(stat -c %Y "$f" 2>/dev/null) && printf '%s' "$t" && return
    # BSD stat (macOS)
    t=$(stat -f %m "$f" 2>/dev/null) && printf '%s' "$t" && return
    # date -r fallback (macOS / some BSDs)
    t=$(date -r "$f" +%s 2>/dev/null) && printf '%s' "$t" && return
}

# ─── throttle gate ──────────────────────────────────────────────────────────
now=$(date +%s 2>/dev/null) || exit 0
if [ -f "$STAMP" ]; then
    last=$(_mtime "$STAMP")
    if [ -n "$last" ] && [ $((now - last)) -lt "$INTERVAL" ]; then
        exit 0
    fi
fi

# Write stamp BEFORE network fetch so a hang doesn't wedge future checks.
mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$STAMP" 2>/dev/null || true

# ─── non-git install: compare VERSION against the latest release (HIMMEL-3247) ─
# Keyed on THIS script's own install root, not CLAUDE_PROJECT_DIR (that is the
# operator's current project, which is usually some other git repo).
SELF_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || SELF_ROOT=""
if [ -n "$SELF_ROOT" ] && [ ! -e "$SELF_ROOT/.git" ]; then
    ROUTE="update through the package manager that installed it (Arch: pacman -Syu himmel), or download the next release tarball from the releases page, verify its sha256 checksum and extract it into a fresh directory (or remove $SELF_ROOT first) — extracting over the existing tree keeps files the new release deleted"
    FIRST="$STATE_DIR/himmel-update-check-first"   # mtime = the first check ever made here
    CACHE="$STATE_DIR/himmel-latest-release"      # mtime = last DEFINITE answer; one line
    [ -f "$FIRST" ] || touch "$FIRST" 2>/dev/null || true

    # shellcheck source=scripts/lib/release-check.sh disable=SC1091
    if ! { [ -r "$SELF_ROOT/scripts/lib/release-check.sh" ] && . "$SELF_ROOT/scripts/lib/release-check.sh"; } 2>/dev/null; then
        printf '<system-reminder>\nhimmel could not check for updates: %s/scripts/lib/release-check.sh is missing or unreadable (broken install). This install is not a git checkout — %s.\n</system-reminder>\n' "$SELF_ROOT" "$ROUTE"
        exit 0
    fi
    # shellcheck source=scripts/lib/detach.sh disable=SC1091
    . "$SELF_ROOT/scripts/lib/detach.sh" 2>/dev/null || true

    # Take the reading BEFORE the refresh is spawned (same reason as the git path
    # below): a fast refresh would otherwise replace the answer, its age and the
    # failure reason before this run reads them, so what a run reports would
    # depend on who won the race. This run reports the PREVIOUS check's result.
    # Re-validate what was cached: STATE_DIR is an overridable path (the seam can
    # point at a shared one), and only a strict release tag may ever reach the
    # emitted context.
    latest=""; cache_ref=""; reason=""
    if [ -s "$CACHE" ]; then
        IFS= read -r latest < "$CACHE" || true
        if [ "$latest" != "none" ] && ! release_tag_parts "$latest" >/dev/null 2>&1; then latest=""; fi
        cache_ref=$(_mtime "$CACHE")
    fi
    first_ref=$(_mtime "$FIRST")
    if [ -f "$CACHE.fail" ] && [ -r "$CACHE.fail" ]; then IFS= read -r reason < "$CACHE.fail" || true; fi

    # Refresh OUT OF BAND, unconditionally (same reasoning as the git path: a
    # gate on "behind" would let a current-looking install never look again).
    if command -v detach_run >/dev/null 2>&1; then
        detach_run bash "$SELF_ROOT/scripts/lib/release-check.sh" --refresh "$CACHE"
    fi

    installed=$(release_installed_version "$SELF_ROOT") || installed=""
    if [ -z "$installed" ]; then
        printf '<system-reminder>\nhimmel could not check for updates: no readable VERSION file in %s. This install is not a git checkout — %s.\n</system-reminder>\n' "$SELF_ROOT" "$ROUTE"
        exit 0
    fi

    if [ -n "$latest" ] && [ "$latest" != "none" ] && release_is_older "$installed" "$latest"; then
        cat <<EOF
<system-reminder>
himmel $installed is behind the latest release $latest. This install is not a git checkout, so /himmel-update cannot pull it — $ROUTE.
(This check won't repeat for another ${INTERVAL}s.)
</system-reminder>
EOF
        exit 0
    fi

    # No newer release known. That is only "up to date" if the answer is FRESH: age
    # of the last definite answer, or — if there never was one — of our first try.
    if [ -n "$latest" ]; then ref="$cache_ref"; else ref="$first_ref"; fi
    case "$ref" in ''|*[!0-9]*) exit 0 ;; esac
    age=$((now - ref))
    if [ "$age" -gt "$STALE" ]; then
        case "$reason" in
            no-curl|network|bad-response|http-[0-9][0-9][0-9]) ;;
            *) reason="unknown" ;;
        esac
        cat <<EOF
<system-reminder>
himmel could not check for updates: no successful release check in $((age / 86400)) day(s) (last error: $reason). This install is not a git checkout, so the git-based nudge does not apply — check $HIMMEL_RELEASES_PAGE, or $ROUTE.
(This check won't repeat for another ${INTERVAL}s.)
</system-reminder>
EOF
    fi
    exit 0
fi

# ─── locate repo root ────────────────────────────────────────────────────────
# Prefer CLAUDE_PROJECT_DIR (set by the harness), fall back to git discovery
# from this script's directory.
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$ROOT" ]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
[ -d "$ROOT/.git" ] || exit 0

# ─── upstream branch + behind count, from the LOCAL refs ────────────────────
# Read BEFORE the refresh below is spawned. Both commands are local — nothing
# here touches the network — and taking the reading first is what makes this
# run's answer deterministic: a fetch racing the count would report the previous
# check's refs or this one's depending on who won, which is a coin flip in the
# hook and a flaky assertion in its suite.
upstream=$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=""
behind=""
if [ -n "$upstream" ]; then
    behind=$(git -C "$ROOT" rev-list --count "HEAD..$upstream" 2>/dev/null) || behind=""
fi

# ─── refresh the remote refs OUT OF BAND (HIMMEL-1844) ──────────────────────
# Those remote-tracking refs ARE the cache; this detached fetch is its
# out-of-band refresh. So the count above is the one the PREVIOUS check fetched
# (at most INTERVAL old, and a commit count is not a signal that turns over in
# four hours) and the NEXT check sees today's. The synchronous fetch that used
# to sit ahead of it is what made this hook a timeout: an offline station, a VPN
# with a black-holed route, or a credential prompt blocked session start until
# the harness killed the hook at 15s — and a killed hook emits nothing, so the
# operator lost the nudge on exactly the runs that cost the most. Detached, its
# stdin is /dev/null (a prompt EOFs out instead of hanging) and its worst
# outcome is an unrefreshed ref set.
#
# UNCONDITIONAL past this point — in particular it runs on the up-to-date path,
# which is the common one. Gating it on `behind > 0` would mean a checkout that
# reads current never fetches again and so can never discover that it isn't.
# shellcheck source=scripts/lib/detach.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/detach.sh" 2>/dev/null || true
# No synchronous fallback when detach.sh is absent. A broken checkout is not a
# reason to put the network back on the session-start path — that would make the
# non-blocking contract conditional on a file this hook cannot verify, and the
# thing at stake is a NUDGE. This hook already fails open and silent on a dozen
# conditions (no repo, no upstream, offline); one more is in character.
if command -v detach_run >/dev/null 2>&1; then
    # Two bounds, for the two ways a detached fetch hangs forever instead of
    # merely failing:
    #   - a black-holed transfer — git's own abort, bail under 1KB/s for 60s.
    #     Covers https, which is what himmel clones use; an ssh remote falls back
    #     to the transport's own timeouts.
    #   - a credential prompt — stdin is already /dev/null, but git opens
    #     /dev/tty directly to ask, so a clone whose token expired would park on
    #     a question nobody will ever answer. This does NOT disable the
    #     credential HELPER: that would break the nudge outright on a private
    #     clone, which is the case this hook exists for.
    # No total wall-clock deadline: a portable one needs a killer process, and
    # coreutils `timeout` is the Windows SLEEP trap qmd-staleness-notice.sh
    # documents at length. What is left (DNS, connect) is bounded by the OS
    # stack, and the throttle above bounds how many can ever be in flight.
    detach_run env GIT_TERMINAL_PROMPT=0 \
        git -C "$ROOT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
        fetch --quiet origin
fi

# ─── verdict ─────────────────────────────────────────────────────────────────
# No upstream, no readable count, or not behind → silent, exactly as before.
[ -n "$behind" ] || exit 0
# Validate: must be a non-negative integer.
case "$behind" in ''|*[!0-9]*) exit 0 ;; esac
[ "$behind" -gt 0 ] || exit 0

# ─── emit nudge ──────────────────────────────────────────────────────────────
cat <<EOF
<system-reminder>
himmel is $behind commit(s) behind $upstream. Run /himmel-update to pull the latest fixes and hooks.
(This check won't repeat for another ${INTERVAL}s.)
</system-reminder>
EOF

exit 0
