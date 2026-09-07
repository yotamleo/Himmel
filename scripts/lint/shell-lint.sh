#!/usr/bin/env bash
# shell-lint.sh — Pre-emptive advisory shell lint (HIMMEL-478, C4).
#
# Runs shellcheck plus advisory byte/regex portability checks (BOM split by
# file type, errexit leak, POSIX-ERE classes, mktemp template, bash-3.2 constructs, GNU-only
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
#   [BOM]          UTF-8 BOM (EF BB BF) at file start on a SHELL file (breaks
#                  the shebang; SC1082). Never reported on *.ps1 — a BOM is
#                  CORRECT there (Windows PowerShell 5.1 needs it to decode
#                  UTF-8; HIMMEL-1432). A UTF-16/UTF-32 BOM is also valid on a
#                  .ps1 (PS5.1 decodes those natively) and never reported.
#   [PS1-NO-BOM]   a *.ps1 carrying non-ASCII bytes (>0x7F), NO recognized BOM,
#                  whose bytes VALIDATE as UTF-8 (iconv) — PS5.1 mojibake-decodes
#                  a no-BOM UTF-8 file as cp1252 and fails to parse. Add the BOM
#                  (EF BB BF). A pure-ASCII .ps1 without a BOM is fine.
#   [PS1-ENCODING] a *.ps1 carrying non-ASCII bytes, NO recognized BOM, whose
#                  bytes do NOT validate as UTF-8 (or iconv is absent so it
#                  cannot be verified) — unsupported/unknown encoding. Inspect
#                  manually; do NOT prepend a UTF-8 BOM (that corrupts a
#                  non-UTF-8 payload such as UTF-16). (HIMMEL-1432 CR r3.)
#   [parse]       the file does not parse (`bash -n`). A hook file is LIVE the
#                 instant it is written, so a parse error denies EVERY command
#                 fleet-wide before any commit gate can run. The commonest cause
#                 is an apostrophe in prose inside a single-quoted awk/sed/perl
#                 program (`# it's the entry point`) — it ends the shell string
#                 early. (HIMMEL-2230.)
#   [quote-break] an apostrophe that TERMINATED a single-quoted awk/sed/perl
#                 program body: the closing quote is immediately followed by a
#                 word character, the signature of prose (`it's`, `don't`)
#                 rather than an intended end-of-program. Catches the same class
#                 as [parse] in the case where the file still happens to parse
#                 (the stray quote re-balanced) but awk receives a TRUNCATED
#                 program. (HIMMEL-2230.)
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

# Resolve sibling helpers (hook-parse-check.sh) relative to this script, not cwd.
LINT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Like _is_shell_file but also admits *.ps1 (the BOM policy covers PowerShell: a
# BOM is correct there, and a non-ASCII no-BOM .ps1 is the HIMMEL-1432 trap). The
# shell-specific checks below still gate on _is_shell_file, so a .ps1 only ever
# reaches the BOM policy ([BOM] never fires on .ps1; [PS1-NO-BOM] may).
_is_lint_target() {
    case "$1" in
        *.ps1) return 0 ;;
    esac
    _is_shell_file "$1"
}

# _bom_kind FILE -> echoes one of: utf8 | utf16le | utf16be | utf32le | utf32be,
# or prints nothing (no recognized Unicode byte-order mark). The 4-byte UTF-32
# forms are probed BEFORE the 2-byte UTF-16 forms: UTF-32LE (FF FE 00 00) shares
# its first two bytes (FF FE) with UTF-16LE, so a 2-byte-first check would
# mis-tag a UTF-32LE file. od -An -tx1 is byte-accurate and locale-independent;
# head -c4 on a <4-byte file yields fewer bytes, so the prefix globs still match.
# (HIMMEL-1432 CR r3: PowerShell 5.1 decodes BOM'd UTF-16/UTF-32 natively, so a
# .ps1 carrying any of these is a VALID script — never a defect to mutate. The
# r2 code only recognized EF BB BF, so a UTF-16LE .ps1 (FF FE ...) fell into the
# no-BOM branch and was told to "add a UTF-8 BOM", corrupting it. [codex-adv-r2-1].)
_bom_kind() {
    local h4
    h4="$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')"
    case "$h4" in
        0000feff) printf 'utf32be'; return ;;
        fffe0000) printf 'utf32le'; return ;;
    esac
    case "$h4" in
        feff*) printf 'utf16be'; return ;;
        fffe*) printf 'utf16le'; return ;;
        efbbbf*) printf 'utf8'; return ;;
    esac
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
# iconv validates a no-BOM .ps1's bytes as UTF-8 before prescribing a BOM add
# (HIMMEL-1432 CR r3). Ships with Git Bash; when absent the .ps1 policy fails
# SAFE (never prescribes an automated UTF-8-BOM add on unverified bytes).
command -v iconv >/dev/null 2>&1 && HAVE_ICONV=1 || HAVE_ICONV=0

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

    # BOM policy is split by file type (HIMMEL-1432):
    #   shell (.sh / sh shebang) — a UTF-8 BOM is an ERROR: it breaks the
    #     shebang (shellcheck SC1082). Report it ([BOM]).
    #   *.ps1 — a UTF-8 BOM is CORRECT and REQUIRED for non-ASCII content:
    #     Windows PowerShell 5.1 decodes a no-BOM UTF-8 file as cp1252
    #     (mojibake) and its parser then explodes on em-dashes etc. A UTF-8 BOM
    #     is therefore NEVER reported on a .ps1. A UTF-16/UTF-32 BOM is ALSO
    #     valid (PS5.1 decodes those natively) and never mutated. The trap is a
    #     .ps1 carrying non-ASCII bytes (>0x7F) but NO recognized BOM — but only
    #     prescribe adding a UTF-8 BOM when the bytes actually validate as
    #     UTF-8; otherwise the payload is some other encoding and prepending
    #     EF BB BF would corrupt it ([PS1-ENCODING], manual triage). A pure-ASCII
    #     .ps1 without a BOM is fine (the BOM is optional there).
    # CR r3 (HIMMEL-1432): r2 recognized only EF BB BF, so a UTF-16LE .ps1
    # (FF FE ...) fell into the no-BOM branch, read as non-ASCII, and was told
    # to "add a UTF-8 BOM" — corrupting a valid script. [codex-adv-r2-1].
    # No 2>/dev/null on od/head: a genuine failure should surface, not be
    # absorbed into a false "no BOM".
    bom="$(_bom_kind "$f")"
    if [ -n "$bom" ]; then
        # A recognized Unicode byte-order mark is present.
        case "$bom" in
            utf8)
                case "$f" in
                    *.ps1) : ;;  # UTF-8 BOM is correct for .ps1 — never report
                    *)
                        file_report="$file_report  [BOM] UTF-8 byte-order mark at file start — strip it (breaks the shebang; shellcheck SC1082)"$'\n'
                        file_issues=$((file_issues + 1)) ;;
                esac ;;
            utf16le|utf16be|utf32le|utf32be)
                # Split by file type exactly like the utf8 arm above:
                #   *.ps1 — PowerShell 5.1 decodes BOM'd UTF-16/UTF-32 natively,
                #     so a .ps1 carrying one is a VALID script, never a defect to
                #     mutate (HIMMEL-1432 CR r3 [codex-adv-r2-1]).
                #   everything else (shell) — the first two bytes MUST be the `#!`
                #     shebang; ANY byte-order mark (UTF-16LE/BE or UTF-32LE/BE)
                #     pushes `#!` off byte 0 and the kernel won't exec the file.
                #     This is the SAME defect class as a UTF-8 BOM on a shell
                #     script, so reuse the [BOM] tag. You cannot just strip the
                #     mark: the whole payload is UTF-16/32, not only the signature,
                #     so the file must be re-saved as UTF-8 WITHOUT a BOM.
                #     (HIMMEL-1432 CR r4 [codex-r3p-1]: r3 over-broadly blessed
                #     UTF-16/32 on EVERY file type, so a UTF-16-BOM'd .sh passed
                #     the linter with an explicit clean bill of health.)
                case "$f" in
                    *.ps1) : ;;
                    *)
                        case "$bom" in
                            utf16le) bom_name='UTF-16LE' ;;
                            utf16be) bom_name='UTF-16BE' ;;
                            utf32le) bom_name='UTF-32LE' ;;
                            utf32be) bom_name='UTF-32BE' ;;
                        esac
                        file_report="$file_report  [BOM] ${bom_name} byte-order mark at file start — a shell script cannot start with any BOM (breaks the shebang); convert the file to UTF-8 WITHOUT a BOM"$'\n'
                        file_issues=$((file_issues + 1)) ;;
                esac ;;
        esac
    else
        # No recognized BOM. For .ps1, flag non-ASCII content that lacks the BOM
        # it needs — but only prescribe adding a UTF-8 BOM when the bytes really
        # are UTF-8; otherwise flag an unknown encoding (fail-safe: never mutate).
        case "$f" in
            *.ps1)
                # Non-ASCII byte (>0x7F) present? tr deletes every 0x00-0x7F
                # byte; any remaining byte means non-ASCII content (e.g. an
                # em-dash) that PS5.1 would mojibake-decode without a BOM.
                # LC_ALL=C forces BYTE-WISE processing on BOTH stages: an env
                # prefix coats only the first pipeline command, so grep must be
                # coated too. Otherwise, in a UTF-8 locale, '.' does not match a
                # lone invalid-UTF-8 byte (0xA0/0xFF) and the non-ASCII check
                # silently misses it — [PS1-ENCODING] never fired, reopening the
                # very corruption path this policy exists to gate. (HIMMEL-1432
                # CR r5; without this test 16f goes red on a UTF-8 machine.)
                # Full-consuming probe (CR r5, codex-adv): `tr | grep -q` under
                # this script's own pipefail is the HIMMEL-1430 SIGPIPE class —
                # grep -q exits on the first non-ASCII byte, tr takes SIGPIPE on
                # a file larger than a pipe buffer, the pipeline reads nonzero,
                # and a heavily non-ASCII .ps1 silently SKIPS the encoding
                # guard. `wc -c` consumes everything, so the pipeline result is
                # size-independent.
                if [ "$(LC_ALL=C tr -d '\000-\177' < "$f" | wc -c)" -gt 0 ]; then
                    if [ "$HAVE_ICONV" -eq 1 ] && iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
                        file_report="$file_report  [PS1-NO-BOM] non-ASCII bytes present but no UTF-8 BOM — Windows PowerShell 5.1 decodes this as cp1252 mojibake and fails to parse; add a UTF-8 BOM (EF BB BF) (HIMMEL-1432)"$'\n'
                    else
                        # No recognized BOM AND not valid UTF-8 (or iconv absent
                        # so it CANNOT be verified) — never prescribe an
                        # automated UTF-8-BOM add; that would corrupt a
                        # non-UTF-8 payload. Routing to operator-gated triage is
                        # done by the [PS1-ENCODING] TAG: self-heal's classifier
                        # has a dedicated manual-triage arm matching it, checked
                        # BEFORE the generic lint match. (Avoiding the bare token
                        # "BOM" does NOT route here — it only dodged _RE_ENCODING;
                        # the report's "shell-lint" summary token still matched
                        # _RE_LINT and dispatched a fix. HIMMEL-1432 CR r5.)
                        if [ "$HAVE_ICONV" -eq 1 ]; then
                            file_report="$file_report  [PS1-ENCODING] non-ASCII bytes, no recognized byte-order signature, and the bytes are not valid UTF-8 — unsupported/unknown encoding; inspect manually. Do NOT prepend the EF BB BF UTF-8 signature (it corrupts a non-UTF-8 payload such as UTF-16). (HIMMEL-1432)"$'\n'
                        else
                            file_report="$file_report  [PS1-ENCODING] non-ASCII bytes, no recognized byte-order signature, encoding UNVERIFIED (iconv not installed) — inspect manually. Do NOT prepend the EF BB BF UTF-8 signature. (HIMMEL-1432)"$'\n'
                        fi
                    fi
                    file_issues=$((file_issues + 1))
                fi ;;
        esac
    fi

    # The remaining checks are shell-specific; a .ps1 only reached the BOM policy
    # above ([BOM] never fires on .ps1; [PS1-NO-BOM] may have).
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

    # [parse] + [quote-break] — HIMMEL-2230, delegated to the shared checker so
    # there is exactly ONE implementation: scripts/hooks/check-hook-file-parse.sh
    # runs the same script at WRITE time, which is the only moment that helps a
    # live hook file. Findings already carry their own path and tag.
    if [ -f "$LINT_DIR/hook-parse-check.sh" ]; then
        if ! hpc_out="$(bash "$LINT_DIR/hook-parse-check.sh" "$f" 2>&1)"; then
            file_report="$file_report$hpc_out"$'
'
            file_issues=$((file_issues + 1))
        fi
    else
        printf 'shell-lint: hook-parse-check.sh missing next to shell-lint.sh - [parse]/[quote-break] skipped
' >&2
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

    fi   # end shell-specific checks (gate on _is_shell_file; .ps1 hit BOM policy only)

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
