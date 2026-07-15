#!/usr/bin/env bash
# inject-where-are-we.sh — SessionStart hook: inject the RELEVANT slice of the
# where-are-we ledger (HIMMEL-516, L2 of epic HIMMEL-514).
#
# A generative SessionStart SYNC, not a guard. It RENDERS synchronously from the
# existing ledger (no network → fast, within the hook timeout) and, when the
# ledger is stale, spawns a DETACHED background refresh (collect.mjs) so the NEXT
# session sees fresher data. Session start is therefore never blocked by network
# I/O. Relevance routing reuses the L1 contract (scripts/where-are-we/dock.mjs →
# query.mjs): on an active ticket-branch → that ticket's card; on main / detached
# HEAD / a Done-ticket branch → the global digest. NEVER randomly assigns a ticket.
#
# Gated by HIMMEL_WHERE_ARE_WE (must be set in the shell that LAUNCHED Claude —
# bypass convention per scripts/hooks/CLAUDE.md; a per-call prefix does NOT reach
# the hook). Default OFF (adopters see no change). Turn ON for us via .env:
#   HIMMEL_WHERE_ARE_WE=1
# Staleness threshold: HIMMEL_WHERE_ARE_WE_STALE_HOURS (default 6).
#
# This is ADVISORY injected context, not a permission change. It cannot widen
# what the hooks allow.
#
# Wiring (himmel-ops plugin hooks.json SessionStart, exec-if-exists) — editing
# .claude/settings.json directly is a HARD-vetoed self-mod, so this ships via the
# plugin like block-docker-privesc / block-merged-pr-commit.
#
# Test seams (used only by test-inject-where-are-we.sh):
#   WHERE_ARE_WE_STATE_DIR            override the state dir (default $root/.where-are-we)
#   HIMMEL_WHERE_ARE_WE_COLLECT_CMD   override the refresh command (default node collect.mjs)
#   WHERE_ARE_WE_BRANCH_OVERRIDE      override the branch handed to dock.mjs (default: git)

set -euo pipefail

# Always exit clean; never block session start.
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a payload.
if [ -t 0 ]; then :; else cat >/dev/null 2>&1 || true; fi

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
_wa_flag="$_wa_dir/.stale-flag"
mkdir -p "$_wa_dir" 2>/dev/null || exit 0

_wa_branch="${WHERE_ARE_WE_BRANCH_OVERRIDE:-$(git -C "$_wa_root" branch --show-current 2>/dev/null || true)}"

# --- Render synchronously (no network) --------------------------------------
_wa_out="$("$_wa_node" "$_wa_root/scripts/where-are-we/dock.mjs" \
    --ledger "$_wa_ledger" --marker "$_wa_marker" --branch "$_wa_branch" \
    --stale-hours "${HIMMEL_WHERE_ARE_WE_STALE_HOURS:-6}" \
    --stale-flag-file "$_wa_flag" 2>/dev/null || true)"

# --- Persist, then inject (pointer for the digest, inline for a card) --------
# The large global digest (dock.mjs's "# Where are we" route, ~250 ticket
# lines) is ~1-2k tokens rarely read in full — pointerize it. But an active-
# ticket CARD (status / next / blockers / locks) is small and high-value, so
# it stays inline: pointerizing it would defeat the relevance-routing contract
# and hide blockers/locks. So: ALWAYS persist the full render to latest.md (so
# we keep track), and inject a pointer ONLY when (a) the render is the global
# digest AND (b) persistence succeeded. Everything else — a card, or a persist
# failure (unwritable dir / disk full) — falls through to injecting the render
# inline (fail-open), so the session never loses content. The freshness line
# ("where-are-we · …") stays first on every path, so the L1 contract and the
# smoke test still hold.
if [ -n "$_wa_out" ]; then
    # Route detection is STRUCTURAL, not a whole-body search: the digest's first
    # H1 heading is exactly "# Where are we" (render.mjs), while a card's first
    # H1 is "# <TICKET>". Comparing only the FIRST `# ` heading means a card
    # field (e.g. a multiline next_action) that happens to contain a
    # "# Where are we" line cannot be misclassified as the digest.
    _wa_first_h1="$(printf '%s\n' "$_wa_out" | grep -m1 '^# ' || true)"
    if [ "$_wa_first_h1" = '# Where are we' ]; then
        # Global digest → pointerize. latest.md is RESERVED for the digest: only
        # this route ever writes it, so a concurrent/later active-ticket card
        # session (same state dir) cannot overwrite the pointer target with its
        # card. Persist atomically (temp + mv); skip if the target exists but is
        # NOT a regular file so mv can't orphan the temp inside a directory. Any
        # write/mv failure → fail-open, inject the digest inline below.
        _wa_latest="$_wa_dir/latest.md"
        _wa_persisted=0
        if [ ! -e "$_wa_latest" ] || [ -f "$_wa_latest" ]; then
            _wa_tmp="$_wa_latest.tmp.$$"
            if printf '%s\n' "$_wa_out" > "$_wa_tmp" 2>/dev/null \
                && mv -f "$_wa_tmp" "$_wa_latest" 2>/dev/null \
                && [ -f "$_wa_latest" ]; then
                _wa_persisted=1
            else
                rm -f "$_wa_tmp" 2>/dev/null || true
            fi
        fi
        if [ "$_wa_persisted" = 1 ]; then
            # First line via pure-bash parameter expansion — NOT `printf | head`,
            # which under `set -o pipefail` can return nonzero (printf EPIPEs when
            # head closes the pipe on a large digest), tripping the ERR trap into
            # a silent exit 0 that injects nothing after latest.md was written.
            _wa_head="${_wa_out%%$'\n'*}"
            printf '<system-reminder>\n%s — full digest not loaded (context-lean); full digest at %s\n</system-reminder>\n' \
                "$_wa_head" "$_wa_latest"
        else
            printf '<system-reminder>\n%s\n</system-reminder>\n' "$_wa_out"
        fi
    else
        # Active-ticket card (or any non-digest render): inject inline so its
        # status/next/blockers/locks stay visible, and do NOT touch latest.md —
        # that file is reserved as the digest pointer's target.
        printf '<system-reminder>\n%s\n</system-reminder>\n' "$_wa_out"
    fi
fi

# --- Refresh asynchronously when stale (debounced) --------------------------
if [ -f "$_wa_flag" ] && [ "$(cat "$_wa_flag" 2>/dev/null)" = 1 ]; then
    touch "$_wa_marker" 2>/dev/null || true
    if [ -n "${HIMMEL_WHERE_ARE_WE_COLLECT_CMD:-}" ]; then
        ( nohup bash -c "$HIMMEL_WHERE_ARE_WE_COLLECT_CMD" >/dev/null 2>&1 & ) || true
    else
        ( nohup "$_wa_node" "$_wa_root/scripts/where-are-we/collect.mjs" --ledger "$_wa_ledger" >/dev/null 2>&1 & ) || true
    fi
fi
rm -f "$_wa_flag" 2>/dev/null || true

exit 0
