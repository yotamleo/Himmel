#!/usr/bin/env bash
# scripts/where-are-we/statusline-segment.sh — the where-are-we status-line
# segment (HIMMEL-538, epic 514). Reads OFFLINE on the render path and emits ONE
# line: the active-handover marker + ticket (+ its 514-ledger status) + the epic
# rollup. Composed onto the base bar by scripts/where-are-we/statusline.sh.
#
#   ⎇ <KEY>[ 📋][ <ledger-status>][ · <EPIC> <done>/<total>]
#
# Sources (all offline; at most ONE node spawn — the ledger slice):
#   - ticket KEY  : bash regex on the branch (no node).
#   - 📋 marker   : presence of <handover_root>/breadcrumbs/<KEY>.json (the
#                   HIMMEL-477 resume breadcrumb; layout-agnostic, no node).
#   - ledger stat : provision.mjs slice (the one node spawn; "—"/empty → omit).
#   - epic rollup : a CACHED read of the rollup file (no network); a stale/cold
#                   cache fires a DETACHED, lock-gated refresh (statusline-rollup.sh).
#
# FAIL-OPEN everywhere: any error omits only its own part; never errors/hangs.
# Gated by HIMMEL_WHERE_ARE_WE (default OFF) — defense-in-depth (the wrapper also
# gates) so the segment is testable in isolation.
#
# Test seams: --branch / --cwd ; HANDOVER_DIR (breadcrumb root, existing) ;
#   --ledger (provision.mjs ledger path) ; HIMMEL_WHERE_ARE_WE_ROLLUP_DIR
#   (rollup cache dir, default /tmp/claude) ; HIMMEL_WHERE_ARE_WE_ROLLUP_CMD
#   (refresh command, default the sibling statusline-rollup.sh) ;
#   HIMMEL_WHERE_ARE_WE_REFRESH_SYNC (run the refresh foreground, deterministic).
set -uo pipefail

branch_override="" cwd_override="" ledger_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) branch_override="${2:-}"; shift 2 ;;
        --cwd)    cwd_override="${2:-}"; shift 2 ;;
        --ledger) ledger_override="${2:-}"; shift 2 ;;
        *)        shift ;;
    esac
done

# Drain stdin (the Claude Code JSON) so the wrapper's pipe never blocks.
input=""
if [ ! -t 0 ]; then input="$(cat 2>/dev/null || true)"; fi

# --- Gate -------------------------------------------------------------------
_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ""|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
_truthy "${HIMMEL_WHERE_ARE_WE:-}" || exit 0

SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/../.." && pwd)"

# --- cwd + branch -----------------------------------------------------------
cwd=""
if [ -n "$cwd_override" ]; then
    cwd="$cwd_override"
elif [ -n "$input" ]; then
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

branch="$branch_override"
if [ -z "$branch" ]; then
    branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)"
fi
[ -n "$branch" ] || exit 0

# --- branchToKey (bash; no node) --------------------------------------------
# type/ABC-123-slug → ABC-123 (uppercased). No match → nothing to show.
key=""
case "$branch" in
    */*)
        rest="${branch#*/}"
        cand="$(printf '%s' "$rest" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p')"
        [ -n "$cand" ] && key="$(printf '%s' "$cand" | tr '[:lower:]' '[:upper:]')"
        ;;
esac
[ -n "$key" ] || exit 0

now="$(date +%s)"

# --- Active-handover marker (breadcrumb presence; offline, no node) ---------
marker=""
if [ -f "$ROOT/scripts/lib/handover-path.sh" ]; then
    # shellcheck source=/dev/null
    . "$ROOT/scripts/lib/handover-path.sh" 2>/dev/null || true
    hroot=""
    if command -v handover_root >/dev/null 2>&1; then
        hroot="$(handover_root 2>/dev/null || true)"
    fi
    if [ -n "$hroot" ] && [ -f "$hroot/breadcrumbs/$key.json" ]; then
        if jq -e . "$hroot/breadcrumbs/$key.json" >/dev/null 2>&1; then
            marker="📋"
        fi
    fi
fi

# --- 514-ledger status (the one node spawn; "—"/empty → omit) ---------------
status=""
node_bin="${HIMMEL_WHERE_ARE_WE_NODE_BIN:-}"   # test seam (default: auto-resolve)
if [ -z "$node_bin" ] && [ -f "$ROOT/scripts/lib/resolve-node.sh" ]; then
    # shellcheck source=/dev/null
    . "$ROOT/scripts/lib/resolve-node.sh" 2>/dev/null || true
    if command -v resolve_node >/dev/null 2>&1; then
        node_bin="$(resolve_node 2>/dev/null || true)"
    fi
fi
[ -n "$node_bin" ] || node_bin="$(command -v node 2>/dev/null || true)"
ledger="$ledger_override"
[ -n "$ledger" ] || ledger="$ROOT/.where-are-we/ledger.jsonl"
# The provision.mjs slice is the ONLY unbounded actor on the render path, so it
# must be timeout-bounded HERE (the wrapper's timeout is belt-and-braces and is
# itself skipped when no timeout binary exists). Resolve GNU `timeout` or macOS
# coreutils `gtimeout`; if NEITHER exists, SKIP the node spawn entirely rather
# than risk a hung node freezing the bar (degrade to no-status — C1).
seg_to=""
if command -v timeout >/dev/null 2>&1; then seg_to="timeout"
elif command -v gtimeout >/dev/null 2>&1; then seg_to="gtimeout"; fi
node_to="${HIMMEL_WHERE_ARE_WE_NODE_TIMEOUT:-3}"
case "$node_to" in ''|*[!0-9]*) node_to=3 ;; esac
if [ -n "$node_bin" ] && [ -f "$ledger" ] && [ -n "$seg_to" ]; then
    slice="$("$seg_to" "$node_to" "$node_bin" "$ROOT/scripts/where-are-we/provision.mjs" slice --ledger "$ledger" --for "$key" 2>/dev/null || true)"
    if [ -n "$slice" ]; then
        st="$(printf '%s\n' "$slice" | sed -n 's/^- status: //p' | head -n1)"
        case "$st" in ""|"—") st="" ;; esac
        status="$st"
    fi
fi

# --- Epic rollup (cached read; refresh detached + lock-gated) ---------------
cachedir="${HIMMEL_WHERE_ARE_WE_ROLLUP_DIR:-/tmp/claude}"
cache="$cachedir/where-are-we-rollup-$key.json"
epic_part=""
if [ -f "$cache" ]; then
    ej="$(jq -r '.epic // empty' "$cache" 2>/dev/null || true)"
    dj="$(jq -r '.done' "$cache" 2>/dev/null || true)"
    tj="$(jq -r '.total' "$cache" 2>/dev/null || true)"
    if [ -n "$ej" ] && printf '%s' "$dj" | grep -qE '^[0-9]+$' && printf '%s' "$tj" | grep -qE '^[0-9]+$'; then
        epic_part="$ej $dj/$tj"
    fi
fi

# Stale/cold → fire a refresh, but only if no refresh is already in flight
# (pre-spawn lock check keeps the common case from forking).
need_refresh=0
if [ ! -f "$cache" ]; then
    need_refresh=1
else
    cmt="$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)"
    ttl="${HIMMEL_WHERE_ARE_WE_ROLLUP_TTL:-900}"
    case "$ttl" in ''|*[!0-9]*) ttl=900 ;; esac
    if [ "$(( now - cmt ))" -gt "$ttl" ]; then need_refresh=1; fi
fi
if [ "$need_refresh" -eq 1 ] && [ ! -d "$cache.lock" ]; then
    mkdir -p "$cachedir" 2>/dev/null || true
    rollup_cmd="${HIMMEL_WHERE_ARE_WE_ROLLUP_CMD:-bash $SD/statusline-rollup.sh}"
    if [ -n "${HIMMEL_WHERE_ARE_WE_REFRESH_SYNC:-}" ]; then
        # shellcheck disable=SC2086  # rollup_cmd is the intentional "bash <path>" seam word-split
        $rollup_cmd --key "$key" --out "$cache" >/dev/null 2>&1 || true
    else
        # shellcheck disable=SC2086
        ( $rollup_cmd --key "$key" --out "$cache" >/dev/null 2>&1 & ) || true
    fi
fi

# --- Compose ----------------------------------------------------------------
line="⎇ $key"
[ -n "$marker" ] && line="$line $marker"
[ -n "$status" ] && line="$line $status"
[ -n "$epic_part" ] && line="$line · $epic_part"
printf '%s\n' "$line"
exit 0
