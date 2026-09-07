#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit.
#
# Blocks edits whose target FILE lives in the PRIMARY checkout of a git repo,
# forcing all feature work into a worktree per CLAUDE.md ("All feature work in
# git worktrees. Never commit directly to main."). Two block cases:
#   - the repo is on main/master (the original case), OR
#   - the repo is on a feature branch but is the PRIMARY checkout, NOT a linked
#     worktree (HIMMEL-507 — closes the gap where feature work happened on a
#     branch checked out in the primary tree instead of an isolated worktree).
# A linked worktree carries its own `.git` FILE (vs the primary checkout's
# `.git` DIRECTORY); edits inside one are always allowed — that is the intended
# place for feature work.
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
# Exemption: a file that is BOTH untracked AND gitignored is allowed,
# regardless of branch — it cannot land in an on-main commit, so the block
# would be a false positive (HIMMEL-876, e.g. the operator-local
# scripts/cr/critics.local.json overlay). EXCEPT the secret-file class
# (.env, keys, credentials — mirrored from block-read-secrets.sh): those
# are gitignored BECAUSE they are sensitive, and stay denied. Also EXCEPT the
# `.single-writer` basename itself (HIMMEL-2526): that marker is gitignored
# too, but writing it is exactly the "disable this fence" action, so it never
# takes this exemption either.
#
# The resolution/branch/exemption/bypass decision itself is the shared
# `main_checkout_verdict` predicate in scripts/guardrails/lib.sh (HIMMEL-2526)
# — this hook and any Bash-mediated write fence call the SAME function so a
# `cat >`/`sed -i`/python-heredoc write is judged identically to an Edit/Write
# tool call, instead of drifting a second copy of this logic.
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

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

# Extract target path(s). NotebookEdit uses notebook_path; tolerate both.
# Codex's apply_patch (create/edit envelope, HIMMEL-2170) carries no
# file_path/notebook_path field at all -- every target lives inside
# "*** Add/Update/Delete File:" lines in tool_input.command instead (see
# docs/internals/harness-compat.md's empirical event/tool-name matrix, and
# scripts/guardrails/lesson-write-fence.sh's twin extraction). Pull every such
# target out of the patch text; the loop below (replacing the old single-path
# body) runs the SAME repo/branch check against EACH one, so a hit on ANY
# target blocks the whole apply_patch call. A command with none of these
# lines (empty/malformed patch text) yields an empty target list, which falls
# through to the same allow this hook already gave an empty file_path -- this
# guard's established fail-open posture for an unresolvable target (it is
# defense-in-depth; check-worktree-isolation.sh is the commit-time backstop).
targets=""
if [ "$tool_name" = "apply_patch" ]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # HIMMEL-2170 CR round 2: read the TOOL's cwd the same way lesson-write-
    # fence.sh's twin branch does (`.tool_input.cwd // .cwd`, fallback $PWD).
    # canon() below has no cwd parameter of its own - it resolves a relative
    # path against the HOOK PROCESS's $PWD, which can differ from the tool
    # cwd - so an apply_patch target that is RELATIVE must be joined onto
    # the tool cwd HERE, before canon(), or it silently misresolves and a
    # primary-checkout edit can slip past the main-branch block.
    cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
    [ -n "$cwd" ] || cwd="$PWD"
    _ap_prev=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        # Strip a trailing CR (see lesson-write-fence.sh's twin extraction for
        # the full explanation): `jq -r` CRLF-converts embedded newlines on
        # this platform, and command substitution only strips the FINAL
        # trailing newline group — every OTHER line in a multi-line
        # tool_input.command (apply_patch's patch text always is) keeps a
        # stray `\r` glued on.
        _line="${_line%$'\r'}"
        _target=""
        case "$_line" in
            '*** Add File: '*)    _target="${_line#'*** Add File: '}"; _ap_prev="" ;;
            '*** Update File: '*) _target="${_line#'*** Update File: '}"; _ap_prev="update" ;;
            '*** Delete File: '*) _target="${_line#'*** Delete File: '}"; _ap_prev="" ;;
            # HIMMEL-2170 CR round 1: a rename/move destination (optional
            # line immediately following an `*** Update File:` line - see
            # lesson-write-fence.sh's twin arm for the grammar citation).
            # Without this, an Update on an ALLOWED-branch source could move
            # it onto a path inside the PRIMARY checkout without that
            # destination ever being checked.
            #
            # CodeRabbit round (HIMMEL-2170): valid only immediately after an
            # Update File line (see the fence's twin comment for the grammar
            # citation). Unlike the fence, this hook does NOT deny on a
            # misplaced Move-to — its established posture is fail-OPEN on an
            # unresolvable/malformed target (see the header's fail-open/
            # fail-closed note): a stray Move-to simply contributes NO
            # target ($_target stays empty, dropped below) rather than being
            # treated as a real one. Other valid targets in the same patch
            # (e.g. an Update line) are still checked normally.
            '*** Move to: '*)
                [ "$_ap_prev" = "update" ] && _target="${_line#'*** Move to: '}"
                _ap_prev="" ;;
            *) _ap_prev="" ;;
        esac
        if [ -n "$_target" ]; then
            case "$_target" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;                # already absolute
                *)                           _target="$cwd/$_target" ;;
            esac
            targets="${targets}${_target}"$'\n'
        fi
    done <<< "$cmd"
else
    targets=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
fi
[ -n "$(printf '%s' "$targets" | tr -d '[:space:]')" ] || exit 0

while IFS= read -r file_path || [ -n "$file_path" ]; do
[ -n "$file_path" ] || continue

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

# Resolve the EDITED FILE's write verdict via the shared main_checkout_verdict
# predicate (scripts/guardrails/lib.sh, HIMMEL-2526) — the walk-up-for-`.git`,
# branch check, handovers/untracked-ignored/secret-class/single-writer-basename
# exemptions, and the EDIT_ON_MAIN_OK / .single-writer bypasses all live there
# now, shared with any other Bash-mediated write fence, instead of a second
# copy of this logic drifting here. The call MUST go through `|| verdict_rc=$?`
# (not a bare call): under set -e a bare call returning nonzero (the common
# case — most edits get judged, not merely resolved) aborts the script with NO
# stderr, surfacing as Claude Code's "hook error: No stderr output"
# (HIMMEL-392, the same reason the old inline `is_on_main` call needed it).
repo_real=""
verdict_rc=0
repo_real=$(main_checkout_verdict "$file_real") || verdict_rc=$?

# rc=0 covers every allow path main_checkout_verdict has: not inside any repo,
# the handovers/ carve-out, a linked worktree, the untracked+gitignored
# exemption, EDIT_ON_MAIN_OK=1, and a repo-root .single-writer marker.
[ "$verdict_rc" -eq 0 ] && continue

# rc=3: branch unreadable (e.g. a repo with a corrupt/removed HEAD) — fail
# CLOSED to match this script's security posture (jq/git/realpath capability
# checks above also fail closed).
if [ "$verdict_rc" -eq 3 ]; then
    echo "block-edit-on-main: cannot determine branch for '$repo_real' - refusing to evaluate" >&2
    exit 2
fi

if [ "$verdict_rc" -eq 2 ]; then
    cat >&2 <<EOF
⛔ block-edit-on-main: refusing to edit \`$file_path\` — its repo is the PRIMARY
checkout on a feature branch. Feature work must be isolated in a worktree per
CLAUDE.md, not done on a branch checked out in the primary tree (HIMMEL-507).
(file: $file_real — repo: $repo_real)

Move the work into a worktree (a linked worktree carries its own \`.git\` file,
so edits there are allowed):

    /clean_garden feat/<scope>          # prune merged worktrees + create new
    cd .claude/worktrees/feat+<scope>   # switch in the existing shell

Bypass / single-writer opt-out behave the same as the on-main case:

    EDIT_ON_MAIN_OK=1 claude            # session bypass (set in the launching shell)
    touch "$repo_real/.single-writer"   # local, gitignored single-writer opt-in

Or temporarily comment out the hook stanza in .claude/settings.json.
EOF
    exit 2
fi

# The only remaining verdict is rc=1 ("main"/"master").
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
done <<< "$targets"

exit 0
