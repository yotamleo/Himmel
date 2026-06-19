#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit.
#
# Blocks edits whose target FILE lives in a git repo that is currently on
# main/master, forcing all feature work into a worktree per CLAUDE.md ("All
# feature work in git worktrees. Never commit directly to main.").
#
# The repo is resolved from the EDITED FILE's path (walking up its own ancestors
# for a `.git`), NOT from CLAUDE_PROJECT_DIR / the launch dir. That way it still
# protects a nested repo on main even when Claude Code is launched from a
# directory ABOVE it (Himmel#45) — anchoring to the launch dir silently read the
# wrong repo's branch and let the edit through.
#
# Pre-existing pre-commit `check-worktree-isolation.sh` catches this at
# commit time. This hook catches it at EDIT time so the operator gets
# immediate feedback instead of losing changes after a doomed commit.
#
# Opt-out: a local `.single-writer` file at a repo's root (gitignored via
# global excludes, never committed) opts that repo out of the block —
# personal vaults and state repos that commit straight to main by design.
# The check is anchored to repo_real (the EDITED FILE's repo root), so a
# marker in a parent repo cannot leak the opt-out onto a nested repo.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default for any non-blocking path)
#   2 — block; stderr is shown to Claude and the user
#
# Refs: handovers/<USER_SLUG>/backlog.md B1 (pre-edit worktree guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "block-edit-on-main: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi
# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe) — and a hung PreToolUse
# hook hangs the whole session. canon()'s python fallbacks go through this.
# Sourced GUARDED: under set -e an unguarded failed source exits rc=1, and
# PreToolUse only blocks on exit 2 — a missing lib would fail this security
# hook OPEN. Fail CLOSED instead, matching the capability checks below.
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../lib/py-armor.sh" 2>/dev/null; then
    echo "block-edit-on-main: cannot source py-armor.sh — refusing to evaluate" >&2
    exit 2
fi

# --- Capability checks (fail CLOSED on missing deps; security boundary) ---
if ! command -v jq >/dev/null 2>&1; then
    echo "block-edit-on-main: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi
# git drives the branch read (is_on_main → lib.sh). Missing git would otherwise
# surface only as a confusing rc=2 deep in the branch check — fail CLOSED here
# with a clear message instead (matches the jq check; HIMMEL-401 CR).
if ! command -v git >/dev/null 2>&1; then
    echo "block-edit-on-main: git not on PATH — refusing to evaluate; install git or comment the hook in .claude/settings.json" >&2
    exit 2
fi

# Pick a canonicaliser. GNU realpath -m is preferred (handles non-existent
# paths). BSD realpath on macOS does NOT support -m, so fall back to python
# (pathlib resolves traversal + symlinks AND emits POSIX forward slashes
# for self-consistency with the realpath-m branch).
# Fail CLOSED if neither is available — a missing canonicaliser silently
# leaving paths un-resolved would re-open the `worktrees/../foo.sh` bypass.
#
# CANON_FORCE env var (test-only) overrides probe so smoke tests can
# exercise the fallback branches without unmounting binaries from PATH.
CANON_MODE=""
if [ -n "${CANON_FORCE:-}" ]; then
    CANON_MODE="$CANON_FORCE"
else
    # Probe by checking OUTPUT, not just exit status: BSD-realpath variants
    # may exit 0 on `-m` while silently ignoring it. A real GNU realpath -m
    # on a non-existent path echoes the canonicalised path verbatim.
    probe=$(realpath -m /nonexistent-canon-probe 2>/dev/null || true)
    if [ "$probe" = "/nonexistent-canon-probe" ]; then
        CANON_MODE="realpath-m"
    elif command -v python3 >/dev/null 2>&1; then
        CANON_MODE="python3"
    elif command -v python >/dev/null 2>&1; then
        CANON_MODE="python"
    else
        echo "block-edit-on-main: needs GNU realpath -m or python (3.x) — refusing to evaluate; install GNU coreutils (macOS: brew install coreutils && add gnubin to PATH) or comment the hook" >&2
        exit 2
    fi
fi

canon() {
    # Canonicalise a path. Returns empty on failure; caller MUST fail closed
    # on empty output. Python branch uses pathlib.resolve(strict=False) so
    # non-existent paths still canonicalise, and as_posix() forces forward
    # slashes for cross-branch consistency with realpath -m. Python calls
    # are armored (py_armor_capture, HIMMEL-249): a wedged Store stub reads
    # as a nonzero rc -> empty output -> the caller's fail-closed exit 2,
    # never a hung hook. The WindowsApps stub ships python.exe too, so the
    # plain-python branch is armored via PY_ARMOR_BIN.
    case "$CANON_MODE" in
        realpath-m)
            realpath -m "$1" 2>/dev/null
            ;;
        python3)
            py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$1" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        python)
            PY_ARMOR_BIN=python py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$1" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        *)
            return 1
            ;;
    esac
}

input=$(cat)

# Extract the target file_path. NotebookEdit uses notebook_path; tolerate both.
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
[ -z "$file_path" ] && exit 0

# `|| file_real=""` suppresses set -e on canon failure so the empty-check below
# catches it with an actionable message instead of set -e aborting rc=1.
file_real=""; file_real=$(canon "$file_path") || file_real=""

# Fail CLOSED on empty canonicalisation — an odd input that returns empty would
# otherwise prefix-match nothing and exit 0, re-opening the `worktrees/../foo.sh`
# traversal bypass.
if [ -z "$file_real" ]; then
    _hint=""
    if [ -n "${CANON_FORCE:-}" ]; then
        _hint=" (CANON_FORCE=$CANON_FORCE — likely a wedged python3/python Store stub; unset CANON_FORCE or kill the stub process)"
    fi
    echo "block-edit-on-main: canonicalisation returned empty (file='$file_real')${_hint} — refusing to evaluate" >&2
    exit 2
fi

# Resolve the EDITED FILE's git repo root — NOT the launch/project dir
# (CLAUDE_PROJECT_DIR). Anchoring to the launch dir silently no-oped the guard
# when Claude was started ABOVE the repo: a nested repo on main went unguarded
# because the OUTER dir's branch was read instead (Himmel#45). Walk up the
# file's OWN canonicalised ancestors looking for a `.git` (a directory in a
# normal checkout, a FILE in a linked worktree or submodule). Walking
# file_real's ancestors — rather than `git -C <dir> rev-parse --show-toplevel`
# — keeps repo_real a literal PREFIX of file_real (no git-vs-canon path-form
# mismatch on the handovers/ check) AND lets us distinguish "inside a repo whose
# branch we cannot read" (→ fail CLOSED in the branch check) from "not inside
# any repo" (→ allow) — `git rev-parse` collapses both to rc=128. The check is
# `.git`-EXISTENCE only (no git invocation), so a not-yet-created Write target
# whose parent dirs are missing simply keeps walking up to the repo root, and
# the loop terminates at the filesystem root where dirname stops changing
# (robust on both `/...` and bare-drive `C:/...` forms — no `git -C C:` foot-gun).
repo_real=""
_d=$(dirname "$file_real")
_prev=""
while [ "$_d" != "$_prev" ]; do
    if [ -e "$_d/.git" ]; then repo_real="$_d"; break; fi
    _prev="$_d"
    # `|| _d="$_prev"` keeps a (near-impossible) dirname failure from aborting
    # the hook with no stderr under set -e — it just terminates the loop.
    _d=$(dirname "$_d") || _d="$_prev"
done

# File is not inside any git repo (global config, /tmp, system files) → allow.
[ -z "$repo_real" ] && exit 0
repo_real="${repo_real%/}"

# Skip handover/status doc edits — pure docs the operator may update from the
# primary checkout on main. Anchored to the FILE's repo root (Himmel#45).
case "$file_real" in
    "$repo_real"/handovers/*) exit 0 ;;
esac

# No explicit `.claude/worktrees/` skip is needed: a git worktree carries its
# own `.git` file, so the walk above resolves repo_real to the worktree dir
# (checked out on a feature branch) and the branch check below ALLOWS the edit
# via rc=1. The old launch-dir-anchored worktrees skip was itself part of the
# Himmel#45 mis-anchoring.

# Check the branch of the FILE's repo. rc=2 (branch unreadable — e.g. a repo
# with a corrupt/removed HEAD) fails CLOSED to match this script's security
# posture (jq/git/realpath capability checks above also fail closed). The call
# MUST go through `|| branch_rc=$?` (not a bare `is_on_main`): under set -e a
# bare call returning rc=1 (feature branch) aborts the script rc=1 with NO
# stderr — before the rc=1 ALLOW path below — surfacing as Claude Code's "hook
# error: No stderr output" (HIMMEL-392).
branch_rc=0
is_on_main "$repo_real" || branch_rc=$?
if [ "$branch_rc" -eq 1 ]; then
    exit 0
fi
if [ "$branch_rc" -ne 0 ]; then
    echo "block-edit-on-main: is_on_main returned rc=$branch_rc (cannot determine branch for '$repo_real') - refusing to evaluate" >&2
    exit 2
fi

# Branch is main. Honour bypass BEFORE printing the block message so the
# operator does not see a misleading "refusing" warning when the edit will
# actually succeed.
if [ "${EDIT_ON_MAIN_OK:-0}" = "1" ]; then
    exit 0
fi

# Single-writer opt-in (HIMMEL-404): a repo with a local `.single-writer`
# marker at its root commits straight to main by design (personal vaults /
# state repos) — the worktree-forcing block does not apply. Anchored to
# repo_real (the edited file's repo), so a parent's marker never leaks the
# opt-out onto a nested repo. The marker is gitignored (global excludes) so
# it never propagates to a clone/fork — a checkout without it stays protected.
# POSIX `[ -f ]` is true for a regular file OR a symlink that resolves to one,
# and false for a directory, unreadable file, or broken symlink (fail-closed).
# That is acceptable: the marker is a deliberate local opt-in, not a security
# boundary (the operator can equally use EDIT_ON_MAIN_OK=1 or comment the hook,
# and anyone able to create the marker could just touch it directly).
if [ -f "$repo_real/.single-writer" ]; then
    exit 0
fi

cat >&2 <<EOF
⛔ block-edit-on-main: refusing to edit \`$file_path\` — its repo is on main/master.
(file: $file_real — repo: $repo_real)

Feature work must go in a worktree per CLAUDE.md. To start one:

    /clean_garden feat/<scope>          # prune merged worktrees + create new
    cd .claude/worktrees/feat+<scope>   # switch in the existing shell

Or to bypass for an emergency hotfix, set EDIT_ON_MAIN_OK=1 in the shell
that launched Claude Code (the hook reads its environment, so per-edit
prefix syntax cannot work — Claude Code cannot inject env vars into a
hook process). Example:

    EDIT_ON_MAIN_OK=1 claude

The bypass lasts for the entire Claude Code session (it's session-sticky,
not per-edit). Restart Claude without the env var to re-enable the guard.

Or, if this is a single-writer repo you always commit to main directly
(a personal vault / state repo), opt it out locally:

    touch "$repo_real/.single-writer"

(Local + gitignored — never committed, so it cannot weaken a shared clone.)

Or temporarily comment out the hook stanza in .claude/settings.json.
EOF
exit 2
