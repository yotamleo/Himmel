#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit.
#
# Blocks edits that target the primary worktree when HEAD == main. Forces
# all feature work into a `.claude/worktrees/<name>/` subdir per CLAUDE.md
# ("All feature work in git worktrees. Never commit directly to main.").
#
# Pre-existing pre-commit `check-worktree-isolation.sh` catches this at
# commit time. This hook catches it at EDIT time so the operator gets
# immediate feedback instead of losing changes after a doomed commit.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default for any non-blocking path)
#   2 — block; stderr is shown to Claude and the user
#
# Refs: handovers/yotam/backlog.md B1 (pre-edit worktree guard)
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

project_dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# `|| proj_real=""` suppresses set -e on canon failure so the empty-check
# below catches the case with its actionable message instead of `set -e`
# aborting with rc=1 and no diagnostic.
proj_real=""; proj_real=$(canon "$project_dir") || proj_real=""
file_real=""; file_real=$(canon "$file_path") || file_real=""

# Fail CLOSED on empty canonicalisation results — a permission error or odd
# input that returns empty would otherwise prefix-match nothing and exit 0,
# functionally re-opening the bypass we just plugged.
if [ -z "$proj_real" ] || [ -z "$file_real" ]; then
    _hint=""
    if [ -n "${CANON_FORCE:-}" ]; then
        _hint=" (CANON_FORCE=$CANON_FORCE — likely a wedged python3/python Store stub; unset CANON_FORCE or kill the stub process)"
    fi
    echo "block-edit-on-main: canonicalisation returned empty (proj='$proj_real', file='$file_real')${_hint} — refusing to evaluate" >&2
    exit 2
fi

# Strip any trailing slash defensively (canon should already normalise, but
# belt-and-suspenders against odd inputs).
proj_real="${proj_real%/}"

# Skip if the edit is outside the project (global config, system files, etc.)
case "$file_real" in
    "$proj_real"/*) ;;
    "$proj_real") ;;
    *) exit 0 ;;
esac

# Skip if the edit is inside any worktree subdir.
case "$file_real" in
    "$proj_real"/.claude/worktrees/*) exit 0 ;;
esac

# Skip if the edit is a handover/status doc edit (operator may legitimately
# update those from primary). These are pure docs, never code.
case "$file_real" in
    "$proj_real"/handovers/*) exit 0 ;;
esac

# At this point: edit is inside primary worktree, not in a sub-worktree, not a
# handover file. Check the branch via the shared predicate. rc=2 means we
# could not determine the branch (git missing, .git unreadable, etc.) - fail
# CLOSED on that case to match the rest of this script's security posture
# (jq/realpath capability checks above also fail closed). Bare `if is_on_main`
# would collapse rc=2 into "not on main" and silently allow the edit.
is_on_main "$project_dir"
branch_rc=$?
if [ "$branch_rc" -eq 1 ]; then
    exit 0
fi
if [ "$branch_rc" -ne 0 ]; then
    echo "block-edit-on-main: is_on_main returned rc=$branch_rc (cannot determine branch) - refusing to evaluate" >&2
    exit 2
fi

# Branch is main. Honour bypass BEFORE printing the block message so the
# operator does not see a misleading "refusing" warning when the edit will
# actually succeed.
if [ "${EDIT_ON_MAIN_OK:-0}" = "1" ]; then
    exit 0
fi

cat >&2 <<EOF
⛔ block-edit-on-main: refusing to edit \`$file_path\` from PRIMARY worktree while HEAD == main.
(resolved path: $file_real)

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

Or temporarily comment out the hook stanza in .claude/settings.json.
EOF
exit 2
