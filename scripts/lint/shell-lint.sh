#!/usr/bin/env bash
# shell-lint.sh — Pre-emptive advisory shell lint (HIMMEL-478, C4).
#
# Runs shellcheck + a UTF-8 BOM check + an errexit-leak check on shell files
# BEFORE the commit attempt, so the autonomous loop fixes issues instead of
# bouncing off the real pre-commit gate mid-run. The authoritative gate
# (.pre-commit-config.yaml) stays the source of truth and is UNCHANGED — this is
# additive and runs earlier. Advisory: it reports findings and exits non-zero if
# any are found; it never modifies files.
#
# Usage:
#   bash scripts/lint/shell-lint.sh [FILE...]   # lint the named shell files
#   bash scripts/lint/shell-lint.sh --staged    # lint staged shell files (git)
#   bash scripts/lint/shell-lint.sh --help
#
# Checks:
#   [BOM]        UTF-8 byte-order mark at file start (breaks the shebang; SC1082).
#   [errexit]    `set -e` / `-eu` / `-euo` / `-o errexit` — errexit leaks into a
#                sourcing shell; himmel convention is `set -uo pipefail`.
#   [shellcheck] the same linter the pre-commit gate runs (when installed).
#
# Exit: 0 = clean, 1 = findings, 2 = usage error.
# bash 3.2-safe; shellcheck-clean; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

# statusline is vendored byte-for-byte (HIMMEL-331); mirror the gate's exclude.
EXCLUDE_SUBSTR='scripts/statusline/'

usage() {
    # Print only the contiguous header doc block (stop at the first non-# line),
    # so inline implementation comments never leak into --help.
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# True for a path the gate would lint as shell: a .sh extension or a sh shebang.
_is_shell_file() {
    case "$1" in
        *.sh) return 0 ;;
    esac
    case "$(head -n1 "$1" 2>/dev/null)" in
        '#!'*sh*) return 0 ;;
    esac
    return 1
}

STAGED=0
EXPLICIT=0         # 1 once any explicit file path is given
FILES=""           # newline-separated (bash 3.2-safe; avoids array edge cases)
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) STAGED=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do FILES="$FILES$1"$'\n'; EXPLICIT=1; shift; done ;;
        -*) printf 'shell-lint: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) FILES="$FILES$1"$'\n'; EXPLICIT=1; shift ;;
    esac
done

if [ "$STAGED" -eq 1 ]; then
    command -v git >/dev/null 2>&1 || { printf 'shell-lint: --staged needs git on PATH\n' >&2; exit 2; }
    # git diff --cached yields REPO-ROOT-relative paths; resolve them against the
    # toplevel so --staged works from any subdirectory (a worktree-relative cwd
    # would otherwise silently drop every path → a false "clean" before a commit).
    _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$_root" ] || { printf 'shell-lint: --staged: not inside a git work tree\n' >&2; exit 2; }
    # Capture git's exit code explicitly — a git failure must NOT read as
    # "no staged files" (that would be a false all-clear).
    if ! _staged="$(cd "$_root" && git diff --cached --name-only --diff-filter=ACM)"; then
        printf 'shell-lint: --staged: git diff --cached failed\n' >&2; exit 2
    fi
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        _abs="$_root/$_f"
        [ -f "$_abs" ] || continue
        _is_shell_file "$_abs" && FILES="$FILES$_abs"$'\n'
    done <<EOF
$_staged
EOF
fi

command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1 || HAVE_SHELLCHECK=0
[ "$HAVE_SHELLCHECK" -eq 1 ] || printf 'shell-lint: shellcheck not installed — running BOM + errexit checks only\n' >&2

CHECKED=0
MISSING=0
ISSUE_FILES=0

# Iterate the newline-separated file list.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        *"$EXCLUDE_SUBSTR"*) continue ;;
    esac
    if [ ! -f "$f" ]; then
        printf 'shell-lint: skipping missing file: %s\n' "$f" >&2
        MISSING=$((MISSING + 1))
        continue
    fi
    CHECKED=$((CHECKED + 1))
    file_issues=0
    file_report=""

    # [BOM] — first three bytes EF BB BF. No 2>/dev/null: a genuine od/head
    # failure should surface, not be absorbed into a false "no BOM".
    first3="$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')"
    if [ "$first3" = "efbbbf" ]; then
        file_report="$file_report  [BOM] UTF-8 byte-order mark at file start — strip it (breaks shebang; shellcheck SC1082)"$'\n'
        file_issues=$((file_issues + 1))
    fi

    # [errexit] — set -e / -eu / -euo / -o errexit in the prologue. A real
    # errexit directive sits at file top, before any heredoc; `set -e` text inside
    # a heredoc body is a false positive (shellcheck parses heredocs correctly), so
    # stop scanning at the first heredoc operator (`<<`).
    ee="$(awk '/<</{exit} /^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)/{print NR": "$0}' "$f")"
    if [ -n "$ee" ]; then
        while IFS= read -r eline; do
            [ -n "$eline" ] || continue
            file_report="$file_report  [errexit] line $eline — errexit leaks into a sourcing shell; use 'set -uo pipefail'"$'\n'
        done <<EOF
$ee
EOF
        file_issues=$((file_issues + 1))
    fi

    # [shellcheck] — the gate's linter (when installed). Check rc directly.
    if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
        if ! sc_out="$(shellcheck "$f" 2>&1)"; then
            file_report="$file_report  [shellcheck]"$'\n'"$(printf '%s\n' "$sc_out" | sed 's/^/    /')"$'\n'
            file_issues=$((file_issues + 1))
        fi
    fi

    if [ "$file_issues" -gt 0 ]; then
        ISSUE_FILES=$((ISSUE_FILES + 1))
        printf '%s:\n' "$f"
        printf '%s' "$file_report"
    fi
done <<EOF
$FILES
EOF

# Distinguish "checked nothing because the paths were wrong" from "checked and
# clean" — reporting clean when every named file was missing is a false all-clear.
if [ "$EXPLICIT" -eq 1 ] && [ "$CHECKED" -eq 0 ] && [ "$MISSING" -gt 0 ]; then
    printf 'shell-lint: none of the named files exist (%d missing) — checked nothing\n' "$MISSING" >&2
    exit 2
fi

if [ "$ISSUE_FILES" -gt 0 ]; then
    printf 'shell-lint: %d file(s) with issues — fix before committing (the pre-commit gate blocks otherwise)\n' "$ISSUE_FILES"
    exit 1
fi
printf 'shell-lint: clean (%d file(s) checked)\n' "$CHECKED"
exit 0
