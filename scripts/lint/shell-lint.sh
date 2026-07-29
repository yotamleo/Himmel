#!/usr/bin/env bash
# shell-lint.sh — Pre-emptive advisory shell lint (HIMMEL-478, C4).
#
# Runs shellcheck plus advisory byte/regex portability checks (BOM incl. *.ps1,
# errexit leak, POSIX-ERE classes, mktemp template, bash-3.2 constructs, GNU-only
# flags, echo -e/-n) BEFORE the commit attempt, so the autonomous loop fixes
# issues instead of bouncing off the real pre-commit gate mid-run. The
# authoritative gate (.pre-commit-config.yaml) stays the source of truth and is
# UNCHANGED — this is additive and runs earlier. Advisory: it reports findings
# and exits non-zero if any are found; it never modifies files.
#
# Usage:
#   bash scripts/lint/shell-lint.sh [FILE...]   # lint the named shell files
#   bash scripts/lint/shell-lint.sh --staged    # lint staged shell files (git)
#   bash scripts/lint/shell-lint.sh --help
#
# Checks:
#   [BOM]         UTF-8 byte-order mark at file start (breaks the shebang; SC1082).
#                 Runs on shell AND *.ps1 files — a BOM breaks PowerShell too.
#   [errexit]     `set -e` / `-eu` / `-euo` / `-o errexit` — errexit leaks into a
#                 sourcing shell; himmel convention is `set -uo pipefail`.
#   [shellcheck]  the same linter the pre-commit gate runs (when installed).
#   [regex-class] \s / \d / \w in a grep -E / egrep / sed -E / sed -e pattern —
#                 POSIX ERE has no such classes (they match a literal letter).
#   [mktemp]      `mktemp` / `mktemp -d` with no template arg (BSD/macOS needs one).
#   [bash32]      bash 4+ constructs (declare -A, mapfile/readarray, ${var,,}/
#                 ${var^^}, |&, &>>) — not 3.2-safe, the macOS default.
#   [gnu-flag]    GNU-only flags (sed -i no-suffix, date -d, readlink -f, grep -P,
#                 stat -c) without a same-line BSD fallback; exempt via
#                 `# gnu-ok: <reason>` (mirrors the repo's headless-claude-ok hatch).
#   [echo-e]      `echo -e` / `echo -n` — non-portable; use printf.
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

# Like _is_shell_file but also admits *.ps1 (the [BOM] check covers PowerShell
# too). The shell-specific checks below still gate on _is_shell_file, so a .ps1
# only ever reaches [BOM].
_is_lint_target() {
    case "$1" in
        *.ps1) return 0 ;;
    esac
    _is_shell_file "$1"
}

# Print "lineno: line" for every non-comment line in file $1 matching ERE $2.
# Full-line comments are excluded so a construct merely NAMED in a doc comment
# — e.g. "# bash 3.2-safe: no mapfile" — is not a false positive. (Inline
# comments and heredoc/string bodies can still match; these checks are advisory.)
_grep_hits() {
    grep -nE "$2" -- "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# Append one "  [tag] line N: text — hint" per "lineno: line" entry in $2, and
# bump file_issues once if any. Empty $2 is a no-op. file_report/file_issues are
# the caller's loop-scoped accumulators (not local here).
_report_hits() {
    # $1=tag  $2=hits (lineno:line lines)  $3=hint
    [ -n "$2" ] || return 0
    local _ln _rest
    while IFS=: read -r _ln _rest; do
        [ -n "$_ln" ] || continue
        file_report="${file_report}  [$1] line $_ln: $_rest — $3"$'\n'
    done <<EOF
$2
EOF
    file_issues=$((file_issues + 1))
}

# True if line $2 (1-indexed) of file $1 carries a `# gnu-ok: <reason>` marker,
# on that line or the line immediately above — mirrors the repo's
# `headless-claude-ok` opt-in pattern (scripts/hooks/check-no-headless-claude.sh).
_has_gnu_ok() {
    local file="$1" line_no="$2"
    sed -n "${line_no}p" "$file" 2>/dev/null | grep -q 'gnu-ok' && return 0
    if [ "$line_no" -gt 1 ]; then
        sed -n "$((line_no - 1))p" "$file" 2>/dev/null | grep -q 'gnu-ok' && return 0
    fi
    return 1
}

# ── Advisory portability patterns (CR-learnings tuning, HIMMEL-1315, 2026-07-28)
# POSIX ERE throughout (no \s/\d/\w, no PCRE); bash 3.2-safe. Lines are scanned
# as-is (full-line comments excluded by _grep_hits); a construct inside a heredoc
# body or quoted string may still match — these checks are advisory, never a gate.

# grep -E / egrep / sed -E / sed -e invocation; check 1 then looks for a PCRE
# class escape (\s \d \w) on the same line.
REGEX_CLASS_CMD='(^|[^[:alnum:]_-])(grep[[:space:]]+-[A-Za-z]*E|egrep|sed[[:space:]]+(-[A-Za-z]*E|-[A-Za-z]*e))'
PCRE_CLASS='\\[sdw]'

# mktemp / mktemp -d with NO template arg (next token is a shell terminator or
# end-of-line, not a path). Templated forms (mktemp x.XXXX, mktemp "$x",
# mktemp -d -t p) skip — a following quote opens a template argument, so '"' is
# intentionally NOT a terminator; the close-paren ')' still covers "$(mktemp)".
MKTEMP_NOARG='(^|[^[:alnum:]_-])mktemp([[:space:]]+-[A-Za-z]+)*[[:space:]]*($|\)|\||&|;)'

# bash 4+ constructs. |& and &>> are matched only in operator position
# (whitespace-bounded) so the same tokens inside a regex char-class or quoted
# string ([;|&()], "&>>") are not false positives.
BASH32='(^|[^[:alnum:]_])(declare[[:space:]]+-[A-Za-z]*A[A-Za-z]*|mapfile|readarray)([^[:alnum:]_]|$)|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|[[:space:]]\|&[[:space:]]|[[:space:]]&>>'

# GNU-only flags. Portable code pairs them with a BSD alt on the same line
# (stat -f for stat -c, date -[vrj] for date -d); check 5 excludes those, then
# honors '# gnu-ok:'.
GNU_FLAG_PAT='(^|[^[:alnum:]_-])(sed[[:space:]]+-i([[:space:]]|$)|date[[:space:]]+(-d|--date)|readlink[[:space:]]+-f|grep[[:space:]]+-[A-Za-z]*P|stat[[:space:]]+(-c|--format))'

# echo -e / echo -n (and combined short flags such as -ne / -en).
ECHO_FLAG='(^|[^[:alnum:]_-])echo[[:space:]]+-[A-Za-z]*[en][A-Za-z]*'

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
        _is_lint_target "$_abs" && FILES="$FILES$_abs"$'\n'
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

    # [BOM] — first three bytes EF BB BF. Runs on shell AND *.ps1 (a BOM breaks
    # PowerShell too). No 2>/dev/null: a genuine od/head failure should surface,
    # not be absorbed into a false "no BOM".
    first3="$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')"
    if [ "$first3" = "efbbbf" ]; then
        file_report="$file_report  [BOM] UTF-8 byte-order mark at file start — strip it (breaks shebang; shellcheck SC1082)"$'\n'
        file_issues=$((file_issues + 1))
    fi

    # The remaining checks are shell-specific; a .ps1 only reached [BOM] above.
    if _is_shell_file "$f"; then

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

    # Advisory portability checks (CR-learnings tuning). These define their own
    # patterns/tags/hints as DATA, so this linter's own source — and its test
    # suite's fixtures/assertions, which embed the same patterns/tags on
    # purpose — would flag itself (the BASH32 pattern mentions `mapfile`; the
    # echo-e hint says `echo -e`). Skip them for these two files only —
    # BOM/errexit/shellcheck still run on both. This mirrors
    # check-no-headless-claude exempting its own pattern-documenting file.
    case "$f" in
        *scripts/lint/shell-lint.sh|*scripts/lint/test-shell-lint.sh) _skip_advisory=1 ;;
        *) _skip_advisory=0 ;;
    esac
    if [ "$_skip_advisory" -eq 0 ]; then

    # [regex-class] — \s / \d / \w are PCRE/GNU extensions; in a grep -E / egrep
    # / sed -E / sed -e pattern they match a literal letter, not a character
    # class (POSIX ERE has none).
    _rc="$(_grep_hits "$f" "$REGEX_CLASS_CMD" | grep -E "$PCRE_CLASS")"
    _report_hits regex-class "$_rc" \
        "POSIX ERE has no \s/\d/\w (matches a literal letter); use [[:space:]]/[[:digit:]]/[[:alnum:]]"

    # [mktemp] — GNU mktemp works with no template arg; BSD/macOS requires one.
    _mt="$(_grep_hits "$f" "$MKTEMP_NOARG")"
    _report_hits mktemp "$_mt" \
        "BSD/macOS mktemp needs a template arg (e.g. mktemp -d -t prefix.XXXXXX)"

    # [bash32] — bash 4+ constructs; macOS ships bash 3.2.
    _b32="$(_grep_hits "$f" "$BASH32")"
    _report_hits bash32 "$_b32" \
        "bash 4+ construct, not 3.2-safe (macOS default) — see repo house style"

    # [echo-e] — echo -e/-n behaviour varies by shell/build; printf is portable.
    _echo="$(_grep_hits "$f" "$ECHO_FLAG")"
    _report_hits echo-e "$_echo" \
        "echo -e/-n is non-portable; use printf"

    # [gnu-flag] — GNU-only flags (sed -i no-suffix, date -d, readlink -f, grep
    # -P, stat -c). Lines that already pair the GNU form with its BSD alternative
    # on the same line (stat -f for stat -c, date -[vrj] for date -d) are the
    # intended portable idiom and are dropped; the rest may be exempted with
    # `# gnu-ok: <reason>` (same-line or line above).
    _gf="$(grep -nE "$GNU_FLAG_PAT" -- "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vE 'stat[[:space:]]+-f|date[[:space:]]+-[vrj]' || true)"
    if [ -n "$_gf" ]; then
        _gf_report=""
        while IFS=: read -r _gln _grest; do
            [ -n "$_gln" ] || continue
            if ! _has_gnu_ok "$f" "$_gln"; then
                _gf_report="${_gf_report}  [gnu-flag] line $_gln: $_grest — GNU-only flag, not portable to BSD/macOS; add a BSD fallback or '# gnu-ok: <reason>'"$'\n'
            fi
        done <<EOF
$_gf
EOF
        if [ -n "$_gf_report" ]; then
            file_report="${file_report}${_gf_report}"
            file_issues=$((file_issues + 1))
        fi
    fi

    fi   # end advisory checks (_skip_advisory)

    fi   # end shell-specific checks (gate on _is_shell_file; .ps1 hit only [BOM])

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
