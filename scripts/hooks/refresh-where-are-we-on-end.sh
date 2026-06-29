#!/usr/bin/env bash
# refresh-where-are-we-on-end.sh — SessionEnd hook: refresh the where-are-we
# ledger at session end so the NEXT session opens fresh (HIMMEL-572, L2 of epic
# HIMMEL-514).
#
# This is the END-of-session counterpart to inject-where-are-we.sh (SessionStart):
#   - SessionStart RENDERS synchronously from the existing ledger and spawns a
#     DETACHED refresh only when the ledger is already stale (next-session-warmup).
#     - SessionEnd (here) refreshes the ledger reflecting the work just done, so the
#     next session's SessionStart render is already current and its stale-spawn is
#     redundant. It runs collect.mjs DETACHED (setsid/double-fork via lib/detach.sh)
#     so session exit is not blocked; HIMMEL-576 proved such a child survives the
#     hook's process-group teardown. The detached child stamps the freshness marker
#     (mtime) the SessionStart render reads ONLY on success, so "refreshed Nh ago"
#     reflects this end-of-session refresh.
#
# Same gate + bypass model as inject-where-are-we.sh: HIMMEL_WHERE_ARE_WE must be
# set truthy in the shell that LAUNCHED Claude (a per-call prefix does NOT reach
# the hook). Default OFF (adopters see no change). Advisory only — it renders no
# context and touches no permissions.
#
# Wiring: himmel-ops plugin hooks.json SessionEnd (exec-if-exists), like
# inject-where-are-we.sh — editing .claude/settings.json directly is a HARD-vetoed
# self-mod. Coexists with any user-level SessionEnd hook (e.g. end-session-wiki);
# Claude Code runs all registered SessionEnd hooks.
#
# Test seams (used only by test-refresh-where-are-we-on-end.sh):
#   WHERE_ARE_WE_STATE_DIR            override the state dir (default $root/.where-are-we)
#   HIMMEL_WHERE_ARE_WE_COLLECT_CMD   override the refresh command (default node collect.mjs)
#   HIMMEL_WHERE_ARE_WE_TEST_DELAY    sleep N seconds at the START of the detached
#                                     child body. Proves the full-body detach keeps
#                                     the PARENT fast: a regression that un-detaches
#                                     the body would make this delay block teardown,
#                                     failing the fast-return assertion (Case 5).

set -euo pipefail

# Always exit clean; never block session teardown on our own bug.
trap 'exit 0' ERR

# --- Full-body detach (HIMMEL-636) ------------------------------------------
# Re-exec ourselves DETACHED and return 0 instantly so the synchronous preamble
# below (git rev-parse, .env load, node resolution) runs in the detached child
# and can never race Claude Code's SessionEnd teardown timer — the residual
# "Hook cancelled" that HIMMEL-623/635 left behind by detaching only the collect
# sub-step while the preamble still ran in the foreground. The child writes only
# files (ledger + freshness marker), so deferring it loses no operator-visible
# surface; HIMMEL-576 proved such a child survives the hook's process-group
# teardown.
if [ "${1:-}" != "__himmel_detached" ]; then
    # Drain stdin (SessionEnd pipes a JSON payload) so the contract doesn't break.
    if [ -t 0 ]; then :; else cat >/dev/null 2>&1 || true; fi
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/detach.sh"
    detach_run bash "$0" __himmel_detached
    exit 0
fi

# === Detached child: the real refresh (parent already returned 0) ===========

# Test-only preamble-latency seam (see header). if-guarded, not `&& sleep`, so an
# unset value can't trip `set -e` + the ERR trap into a premature exit 0.
if [ -n "${HIMMEL_WHERE_ARE_WE_TEST_DELAY:-}" ]; then
    sleep "$HIMMEL_WHERE_ARE_WE_TEST_DELAY"
fi

# --- Resolve the himmel root (never trust CWD) ------------------------------
_wa_root="${HIMMEL_REPO:-}"
if [ -z "$_wa_root" ]; then
    _wa_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null) || _wa_root=""
fi
[ -n "$_wa_root" ] || exit 0

# Source the clone's .env for the gate vars (non-clobbering; process env wins).
if [ -f "$_wa_root/.env" ]; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh"
    load_dotenv --root "$_wa_root" HIMMEL_WHERE_ARE_WE HIMMEL_WHERE_ARE_WE_STALE_HOURS || true
fi

# --- Gate: OFF unless HIMMEL_WHERE_ARE_WE is truthy -------------------------
_wa_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ""|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
_wa_truthy "${HIMMEL_WHERE_ARE_WE:-}" || exit 0

# --- Resolve node at runtime (PATH-less GUI launch safe) --------------------
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve-node.sh"
_wa_node="$(resolve_node)" || exit 0

# --- Paths ------------------------------------------------------------------
_wa_dir="${WHERE_ARE_WE_STATE_DIR:-$_wa_root/.where-are-we}"
_wa_ledger="$_wa_dir/ledger.jsonl"
_wa_marker="$_wa_dir/.refreshed-at"
mkdir -p "$_wa_dir" 2>/dev/null || exit 0

# --- Refresh DETACHED; the child stamps the marker only on success ----------
# Previously this blocked session exit (synchronous) because a detached job was
# assumed to risk being reaped. HIMMEL-576 proved a setsid/double-fork child
# survives the hook's process-group teardown, so we detach here too (consistent
# with the SessionStart hook, which already spawns its refresh detached) and exit
# immediately. The detached child runs `<collect> && touch marker`, so a failed
# collect (jira/gh/git unreachable) still leaves the marker untouched -> the
# ledger reads stale and SessionStart retries next time.
if [ -n "${HIMMEL_WHERE_ARE_WE_COLLECT_CMD:-}" ]; then
    _wa_refresh="$HIMMEL_WHERE_ARE_WE_COLLECT_CMD"
else
    _wa_refresh="$(printf '%q %q --ledger %q >/dev/null 2>&1' \
        "$_wa_node" "$_wa_root/scripts/where-are-we/collect.mjs" "$_wa_ledger")"
fi
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/detach.sh"
detach_run sh -c "$_wa_refresh && touch $(printf '%q' "$_wa_marker")"

exit 0
