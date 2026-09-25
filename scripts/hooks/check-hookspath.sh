#!/usr/bin/env bash
# Detects `core.hooksPath` misconfiguration that silently bypasses git hooks.
#
# Background (HIMMEL-105): in HIMMEL-45 the repo on disk was renamed
# `yotam_internal` → `himmel`. The `.git/config` was carried over but the
# absolute path inside `core.hooksPath` was not updated. Git silently
# skipped every pre-commit + pre-push hook for an unknown duration —
# no-push-to-main, npm-audit, npm-licenses, code-review-before-push,
# platforms-tested. This script catches that class of bug.
#
# Detection:
#   val := `git config --get core.hooksPath` (trimmed)
#   if val == "":            OK (unset is the default; pre-commit framework
#                                writes .git/hooks/ directly, which git finds
#                                without any core.hooksPath setting)
#   if not exists(val):      FAIL (silent-bypass risk)
#   real_val := realpath(val)
#   real_top := realpath(`git rev-parse --show-toplevel`)
#   real_gcd := realpath(`git rev-parse --git-common-dir`)
#   if real_val is prefix-of real_top:  OK (inside worktree)
#   elif real_val is prefix-of real_gcd: OK (inside primary repo's .git —
#                                  this is the canonical pre-commit-installed
#                                  location, shared across linked worktrees)
#   else:                    FAIL (outside both — same silent-bypass risk)
#
# Used by:
#   1. .pre-commit-config.yaml (pre-commit stage) — fails commits
#   2. scripts/machine-setup/ubuntu.sh (post-clone gate)
#   3. scripts/machine-setup/win11.ps1 (post-clone gate, via .ps1 sibling)
#   4. Claude ~/.claude/settings.json SessionStart (warning, non-blocking)
#   5. scripts/hooks/test-check-hookspath.sh (smoke test)
#
# Exit codes:
#   0 — OK or bypassed
#   1 — misconfigured (hookspath set to missing or out-of-repo target)
#   2 — internal error (git not on PATH, realpath/python unavailable)
#
# Bypass: HOOKSPATH_OK=1 — env var, session-sticky (same convention as
# PLATFORMS_TESTED_OK, EDIT_ON_MAIN_OK, READ_SECRETS_OK).
set -uo pipefail

# looks_like_absolute_path VALUE -- true only if VALUE is a plausible
# absolute path. --path-format=absolute needs git >= 2.31, but this repo's
# declared minimum is git 2.30 (docs/setup/new-machine.md); an unrecognised
# --path-format is not rejected by `git rev-parse` -- it is echoed back as an
# ordinary output line and the command still exits 0 with a garbage,
# non-absolute value (see scripts/hooks/install-main-ref-transaction.sh's
# GIT VERSION note, proven directly rather than assumed). Validate the VALUE,
# never trust the exit status alone.
looks_like_absolute_path() {
    case "$1" in
        /*|[A-Za-z]:[/\\]*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Capability checks (fail CLOSED on missing deps) ---
if ! command -v git >/dev/null 2>&1; then
    echo "check-hookspath: git not on PATH — refusing to evaluate" >&2
    exit 2
fi

# Bypass FIRST so a noisy machine can silence the gate without needing
# the canonicaliser deps present.
if [ "${HOOKSPATH_OK:-0}" = "1" ]; then
    echo "→ check-hookspath: HOOKSPATH_OK=1 — skipping (WARNING: verify core.hooksPath is correct)" >&2
    exit 0
fi

# Are we inside a git repo at all? If not, exit 0 (covers CI sandboxes,
# pre-commit dry-runs outside any repo, etc.).
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# Read the setting. `--get` returns rc=1 on unset with empty stdout —
# tolerate that without aborting under `set -u`.
val=$(git config --get core.hooksPath 2>/dev/null || true)
# Trim leading/trailing whitespace (covers stray editor-added newlines).
val="${val#"${val%%[![:space:]]*}"}"
val="${val%"${val##*[![:space:]]}"}"

if [ -z "$val" ]; then
    # Unset is the safe default — pre-commit writes .git/hooks/* and git
    # picks them up without any core.hooksPath setting.
    exit 0
fi

# Resolve relative path against the worktree top (matches how git resolves
# core.hooksPath: relative to the worktree, not pwd).
toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$toplevel" ]; then
    echo "check-hookspath: could not resolve repo toplevel — refusing to evaluate" >&2
    exit 2
fi

# git-common-dir is the SHARED .git directory across linked worktrees.
# In a `git worktree add`-created worktree, --show-toplevel returns the
# linked worktree dir but --git-common-dir returns the primary repo's
# `.git` — that's where the canonical pre-commit hooks live. We accept
# core.hooksPath pointing inside EITHER as valid.
#
# HIMMEL-2640: --git-common-dir is relative to CWD, not to toplevel — joining
# it against toplevel (as this used to do) is only correct when cwd IS
# toplevel. Invoked from a subdirectory, that join anchored the wrong number
# of ".." segments and produced a gitcommondir that did not point at the
# real .git at all. Direction: this makes the OR-check below spuriously miss
# a legitimate git-common-dir match, so a CORRECTLY configured
# core.hooksPath pointing at the shared .git could be reported as outside
# the repo (exit 1) — a false REJECTION of a valid config, not a missed
# misconfiguration; the fail-closed exit-1 behaviour itself is unaffected.
# --path-format=absolute (git 2.31+) resolves correctly from any cwd.
gitcommondir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if ! looks_like_absolute_path "$gitcommondir"; then
    echo "check-hookspath: could not resolve an absolute git-common-dir (got: '$gitcommondir'; this repo needs git >= 2.31 for --path-format) — refusing to evaluate" >&2
    exit 2
fi

# Drive-relative paths like "C:foo" (no separator after the colon) are
# NOT absolute on Windows — they resolve against the per-drive cwd, not
# the drive root. Require a slash/backslash after the colon to count as
# absolute; otherwise treat as relative and join with toplevel.
case "$val" in
    /*|[A-Za-z]:[/\\]*)
        # absolute (POSIX) or Windows-style absolute — use as-is
        resolved_val="$val"
        ;;
    *)
        resolved_val="$toplevel/$val"
        ;;
esac

# Exists check — does the path point at anything on disk?
if [ ! -e "$resolved_val" ]; then
    cat >&2 <<EOF
⛔ check-hookspath: core.hooksPath points at a path that does not exist.

    core.hooksPath = $val
    resolves to    = $resolved_val
    repo toplevel  = $toplevel

Git is silently SKIPPING all hooks because the hooks dir is gone. This is
the HIMMEL-45 class of bug — every pre-commit + pre-push gate
(no-push-to-main, npm-audit, code-review-before-push, platforms-tested,
worktree-isolation, etc.) is bypassed.

Fix:
    git config --unset core.hooksPath
    pre-commit install --hook-type pre-commit
    pre-commit install --hook-type pre-push
    pre-commit install --hook-type commit-msg

Bypass (NOT recommended — re-enables the silent bypass):
    HOOKSPATH_OK=1 <cmd>
EOF
    exit 1
fi

# Canonicalise both sides for the "is inside repo" comparison. Use the
# same probe-then-fallback pattern as block-edit-on-main.sh: prefer GNU
# realpath -m, fall back to python pathlib for cross-platform support.
CANON_MODE=""
probe=$(realpath -m /nonexistent-canon-probe 2>/dev/null || true)
if [ "$probe" = "/nonexistent-canon-probe" ]; then
    CANON_MODE="realpath-m"
elif command -v python3 >/dev/null 2>&1; then
    CANON_MODE="python3"
elif command -v python >/dev/null 2>&1; then
    CANON_MODE="python"
else
    echo "check-hookspath: needs GNU realpath -m or python — refusing to evaluate" >&2
    exit 2
fi

# Capture python stderr too — if pathlib fails on a weird input, we want
# the actual diagnostic, not a silent "canonicalisation returned empty".
canon() {
    case "$CANON_MODE" in
        realpath-m) realpath -m "$1" ;;
        python3)    python3 -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$1" ;;
        python)     python  -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$1" ;;
        *) return 1 ;;
    esac
}

canon_err=""
real_val=""; real_val=$(canon "$resolved_val" 2>/tmp/check-hookspath-canon.$$.err) || true
if [ -z "$real_val" ] && [ -s /tmp/check-hookspath-canon.$$.err ]; then
    canon_err=$(cat /tmp/check-hookspath-canon.$$.err)
fi
rm -f /tmp/check-hookspath-canon.$$.err

real_top=""; real_top=$(canon "$toplevel" 2>/tmp/check-hookspath-canon.$$.err2) || true
if [ -z "$real_top" ] && [ -s /tmp/check-hookspath-canon.$$.err2 ]; then
    canon_err="${canon_err:+$canon_err; }$(cat /tmp/check-hookspath-canon.$$.err2)"
fi
rm -f /tmp/check-hookspath-canon.$$.err2

real_gcd=""; real_gcd=$(canon "$gitcommondir" 2>/tmp/check-hookspath-canon.$$.err3) || true
if [ -z "$real_gcd" ] && [ -s /tmp/check-hookspath-canon.$$.err3 ]; then
    canon_err="${canon_err:+$canon_err; }$(cat /tmp/check-hookspath-canon.$$.err3)"
fi
rm -f /tmp/check-hookspath-canon.$$.err3

if [ -z "$real_val" ] || [ -z "$real_top" ] || [ -z "$real_gcd" ]; then
    if [ -n "$canon_err" ]; then
        echo "check-hookspath: canonicalisation failed ($CANON_MODE): $canon_err" >&2
    else
        echo "check-hookspath: canonicalisation returned empty — refusing to evaluate" >&2
    fi
    exit 2
fi

# Strip trailing slashes for clean prefix comparison.
real_val="${real_val%/}"
real_top="${real_top%/}"
real_gcd="${real_gcd%/}"

# On Windows, NTFS is case-insensitive: `C:/users/...` and `C:/Users/...`
# refer to the same directory, but shell `case` glob matching is byte-exact.
# If the operator types core.hooksPath with different casing than the
# canonical worktree path (e.g. `c:/users/<user>/...` typed but
# `C:/Users/<user>/...` returned by realpath -m), the prefix check would
# falsely fail. Downcase both sides on Windows before compare. POSIX
# filesystems are case-sensitive, so we don't downcase elsewhere (it would
# mask a real case-mismatch bug).
cmp_val="$real_val"
cmp_top="$real_top"
cmp_gcd="$real_gcd"
case "${OS-}:$(uname -s 2>/dev/null)" in
    Windows_NT:*|*:MINGW*|*:MSYS*|*:CYGWIN*)
        cmp_val=$(printf '%s' "$real_val" | tr '[:upper:]' '[:lower:]')
        cmp_top=$(printf '%s' "$real_top" | tr '[:upper:]' '[:lower:]')
        cmp_gcd=$(printf '%s' "$real_gcd" | tr '[:upper:]' '[:lower:]')
        ;;
esac

# Inside check: real_val == real_top OR real_val starts with real_top + "/"
# OR real_val is inside the primary repo's `.git` (git-common-dir).
case "$cmp_val" in
    "$cmp_top"|"$cmp_top"/*)
        exit 0
        ;;
    "$cmp_gcd"|"$cmp_gcd"/*)
        exit 0
        ;;
esac

cat >&2 <<EOF
⛔ check-hookspath: core.hooksPath points OUTSIDE the current repo.

    core.hooksPath  = $val
    resolves to     = $real_val
    repo toplevel   = $real_top
    git-common-dir  = $real_gcd

Git is loading hooks from a directory that is not part of this repo. This
is the HIMMEL-45 class of bug — hooks from a leftover or stale repo path
are running (or, more likely, an empty/missing dir is running NOTHING)
instead of this repo's pre-commit-installed gates.

Fix:
    git config --unset core.hooksPath
    pre-commit install --hook-type pre-commit
    pre-commit install --hook-type pre-push
    pre-commit install --hook-type commit-msg

Bypass (NOT recommended):
    HOOKSPATH_OK=1 <cmd>
EOF
exit 1
