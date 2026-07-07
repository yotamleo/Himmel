#!/usr/bin/env bash
# inject-worktree-nudge.sh — SessionStart hook (gh#230): surface the worktree
# requirement UP FRONT instead of at the first blocked edit.
#
# block-edit-on-main.sh only fires on the FIRST Edit/Write — by then the operator
# is mid-flow (context loaded, plan formed) and the block sends them back to
# create a worktree, wasting the setup. The signal ("on main + about to do
# feature work") exists at session start, well before the first edit. This hook
# emits that nudge at SessionStart so the block-at-edit becomes the rare fallback,
# not the normal path. The guard itself is unchanged — it stays the hard backstop.
#
# Mirrors block-edit-on-main.sh's fire conditions EXACTLY, so it stays SILENT
# whenever that guard would not fire on the launched checkout:
#   - EDIT_ON_MAIN_OK=1 session bypass set          → silent
#   - a `.single-writer` marker at the repo root    → silent
#   - a linked worktree (its `.git` is a FILE)       → silent (feature work belongs there)
#   - a feature branch NOT in the primary checkout   → silent
#   - not inside a git repo / branch unreadable      → silent
# Only when block-edit-on-main WOULD refuse the first edit (primary checkout on
# main/master, or a feature branch in the primary tree — HIMMEL-507) does it emit
# one <system-reminder> pointing at /worktree | /clean_garden.
#
# ADVISORY injected context, not a permission change — it cannot widen what the
# hooks allow. Fail-OPEN: never blocks session start (trap + silent-on-error).
#
# Gated by HIMMEL_WORKTREE_NUDGE (set in the shell that LAUNCHED Claude, or the
# clone `.env`; process env wins). Default OFF — adopters see no change, matching
# the sibling SessionStart injectors inject-where-are-we / inject-doc-freshness.
# `off`/`0`/`false`/`no`/empty disable; any other value enables.
#
# Wiring: himmel-ops plugin hooks.json SessionStart (exec-if-exists), like the
# sibling injectors — editing .claude/settings.json directly is a HARD-vetoed
# self-mod.
#
# Test seam (used only by test-inject-worktree-nudge.sh):
#   CLAUDE_PROJECT_DIR   anchors the checkout to inspect (the launched repo)

set -euo pipefail
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a payload.
if [ -t 0 ]; then :; else cat >/dev/null 2>&1 || true; fi

# --- Resolve the launched repo (the session's checkout) ----------------------
# Anchor to CLAUDE_PROJECT_DIR (the launched project) so a session started inside
# a worktree resolves to the worktree, and one started in the primary checkout
# resolves there. Fall back to the process CWD.
_wn_anchor="${CLAUDE_PROJECT_DIR:-}"
[ -n "$_wn_anchor" ] || _wn_anchor="$(pwd)"
_wn_root="$(git -C "$_wn_anchor" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$_wn_root" ] || exit 0     # not inside a git repo → nothing to nudge
_wn_root="${_wn_root%/}"

# Source the clone's .env for the gate var (non-clobbering; process env wins).
if [ -f "$_wn_root/.env" ]; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh"
    load_dotenv --root "$_wn_root" HIMMEL_WORKTREE_NUDGE || true
fi

# --- Gate: OFF unless HIMMEL_WORKTREE_NUDGE is truthy ------------------------
_wn_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ""|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
_wn_truthy "${HIMMEL_WORKTREE_NUDGE:-}" || exit 0

# --- Mirror block-edit-on-main's silence conditions -------------------------
# Session bypass set → the guard won't fire → stay silent.
[ "${EDIT_ON_MAIN_OK:-0}" = "1" ] && exit 0
# single-writer opt-in → the guard won't fire → stay silent.
[ -f "$_wn_root/.single-writer" ] && exit 0

# --- Would block-edit-on-main fire? (shared branch predicate) ---------------
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../guardrails/lib.sh" 2>/dev/null || exit 0

_wn_frame=""
_wn_rc=0
is_on_main "$_wn_root" || _wn_rc=$?
if [ "$_wn_rc" -eq 0 ]; then
    _wn_frame="on main/master"
elif [ "$_wn_rc" -eq 1 ]; then
    # Feature branch. A linked worktree (its `.git` is a FILE) is where feature
    # work belongs (the guard allows it) so stay silent. Only a feature branch
    # in the PRIMARY checkout (its `.git` is a DIRECTORY) is blocked (HIMMEL-507).
    [ -d "$_wn_root/.git" ] || exit 0
    _wn_frame="on a feature branch in the PRIMARY checkout"
else
    exit 0   # branch unreadable: stay silent (the guard fails closed on its own)
fi

# --- Inject the up-front nudge ----------------------------------------------
printf '<system-reminder>\n[worktree-nudge] advisory (gh#230): the launched checkout %s is %s, where block-edit-on-main will REFUSE the first Edit/Write. Plan feature work in a worktree BEFORE editing, not after the block:\n    /worktree feat/<scope>          # create an isolated worktree\n    /clean_garden feat/<scope>      # prune merged worktrees + create in one shot\nExempt: edits under handovers/, single-writer repos, or an emergency hotfix relaunched with EDIT_ON_MAIN_OK=1. Advisory only, not a blocker.\n</system-reminder>\n' "$_wn_root" "$_wn_frame"
exit 0
