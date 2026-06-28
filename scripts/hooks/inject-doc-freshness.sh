#!/usr/bin/env bash
# inject-doc-freshness.sh — SessionStart hook (HIMMEL-587): advisory doc/llms.txt
# freshness nudge over origin/main...HEAD on the current feature branch.
#
# ADVISORY injected context, not a guard. Gated by HIMMEL_DOC_FRESHNESS (session
# leg); set it in the repo `.env` (loaded below) OR export from the launching
# shell — process env wins. An EMPTY value does NOT disable it (`load_dotenv`
# treats empty as unset, so a non-empty `.env` value still loads); use `off`/`0`
# to disable. Default OFF (adopters see no change). Fail-OPEN — never blocks
# session start.
#
# Wiring: himmel-ops plugin hooks.json SessionStart (exec-if-exists), like
# inject-where-are-we.sh — editing .claude/settings.json directly is a
# HARD-vetoed self-mod.
set -euo pipefail
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a payload.
if [ -t 0 ]; then :; else cat >/dev/null 2>&1 || true; fi

# --- Resolve the himmel root (never trust CWD) ------------------------------
_df_root="${HIMMEL_REPO:-}"
if [ -z "$_df_root" ]; then
    _df_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null) || _df_root=""
fi
[ -n "$_df_root" ] || exit 0

# Source the clone's .env for the gate var (non-clobbering; process env wins).
if [ -f "$_df_root/.env" ]; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh"
    load_dotenv --root "$_df_root" HIMMEL_DOC_FRESHNESS || true
fi

# --- Gate + detector --------------------------------------------------------
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/doc-freshness.sh"
df_leg_active session || exit 0

_df_branch="$(git -C "$_df_root" branch --show-current 2>/dev/null || true)"
[ -n "$_df_branch" ] || exit 0          # detached HEAD → no feature range
case "$_df_branch" in main|master) exit 0 ;; esac

_df_out="$(df_detect "origin/main...HEAD" "" "$_df_root" 2>/dev/null || true)"
[ -n "$_df_out" ] || exit 0

_df_lines="$(printf '%s\n' "$_df_out" | awk -F'\t' 'NF>=2{printf "  - %s -> consider updating %s\n", $1, $2}')"
printf '<system-reminder>\n📄 Doc-freshness (advisory, HIMMEL-587). Mapped sources changed in origin/main...HEAD without their docs:\n%s\nAdvisory nudge, not a blocker. Update the doc in this branch or ignore.\n</system-reminder>\n' "$_df_lines"
exit 0
