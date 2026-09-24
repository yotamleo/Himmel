#!/usr/bin/env bash
# scripts/guardrails/check-git-env-scrub.sh — gate: trust-path git calls must
# scrub GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE (HIMMEL-3570).
#
# WHY: a git subprocess on a trust path inherits the caller's four GIT_*
# env vars, so an attacker-set value steers which repo/worktree/index it
# actually answers about (PR 1212 anchor-handoff.sh, PR 1217
# plugin-profiles.mjs — both this class). This gate does NOT fix either
# existing site; it stops a THIRD one from landing.
#
# Trust paths (fixed, not discovered): scripts/handover/**, scripts/lanes/**,
# scripts/hooks/**, scripts/cr/**, scripts/lib/go-gate.sh. Excluded within
# those: test-*.sh, *.test.mjs, *.test.js, and anything under a fixtures/ or
# test-fixtures/ directory — those run git in scratch fixtures by design.
#
# Two detectors, deliberately different units (console ruling on the first
# draft, 2026-09-24 — a per-call baseline churned on every insertion and
# counted case-pattern/string/comment mentions of "git" as calls):
#
#   shell (*.sh)   FILE-LEVEL. Any .sh file that invokes `git` in command
#                  position anywhere must scrub the four vars ONCE, before
#                  that first invocation: an `unset` of all four (can be
#                  split across several `unset` lines), or sourcing
#                  scripts/lib/git-clean.sh and calling its git_env_scrub, or
#                  a standalone file-level `# git-env-ok: <reason>` comment
#                  line. A call to the git_clean wrapper never counts as a
#                  bare invocation (its name doesn't match the `git` word
#                  boundary), so a file that only ever calls it needs no
#                  scrub line at all. A shebang-less .sh with NO git
#                  invocation at all is skipped without comment (the common
#                  case — a sourced-only lib of plain functions); one that
#                  DOES invoke git must additionally carry a standalone
#                  `# sourced-lib` marker if it truly is only ever sourced
#                  (whatever sources it owns the scrub) — otherwise it is
#                  scanned exactly like a shebang'd entry point, since the
#                  absence of a shebang alone doesn't prove the file is never
#                  run directly (`bash script.sh` needs none).
#                  "Command position" = git preceded by start-of-line, or a
#                  shell separator/operator (`;`, `&`, `|`, `(`, backtick,
#                  whitespace) and followed by whitespace or end-of-line, on
#                  a line with quoted-string content and trailing comments
#                  stripped first — so a case-pattern label, a string
#                  literal, or a comment mentioning "git" is never a hit.
#
#   JS (*.mjs/.js) PER-CALL (no file-wide scrub primitive exists without
#                  side effects). An execFileSync/spawnSync/execSync/spawn
#                  of 'git' with no scrub visible in the same statement (the
#                  matched line plus the next few) is a hit unless it carries
#                  a same-line `// git-env-ok: <reason>`. A call to the
#                  shared gitClean() helper (scripts/lanes/git-clean.mjs) is
#                  never flagged the same way.
#
# Exemption: a non-empty reason only — a bare marker still fails (same
# convention as leak-classes.sh's `leak-allow:`).
#
# Ratchet: scripts/guardrails/git-env-baseline.txt. `SHELL:<path>` entries
# grandfather a whole shell file (no scrub found) — no line number, so
# inserting a line above the file's git calls does not churn it. `JS:<path>:
# <hash>` entries grandfather one unscrubbed JS call in that file with that
# trimmed-line content hash, WITH MULTIPLICITY — N identical baselined lines
# in one file grandfather up to N identical current hits; a new (N+1)th
# occurrence, or any changed line, is not grandfathered. Burning the baseline
# down is later HIMMEL-3570 slices, not this PR.
#
# Modes:
#   --staged            scan trust-path files as they are STAGED (git index),
#                        for the pre-commit hook.
#   --tree [PATH...]     scan trust-path files on disk (working tree), for the
#                        CI job. Explicit PATH args override the default
#                        trust-path set — used by the test suite to point at
#                        fixtures instead of the real trust paths.
#   --emit-baseline      scan the real trust paths on disk and print every
#                        current hit's baseline key to stdout, one per line —
#                        regenerates scripts/guardrails/git-env-baseline.txt.
#                        Ignores any existing baseline (every hit is emitted,
#                        not just new ones), and always exits 0.
#
# Exit: 0 = clean (or fail-open below); 1 = unscrubbed/unexempted hit(s) found
# outside the baseline; 2 = usage/setup error.
set -euo pipefail

usage() {
    echo "usage: $0 --staged | --tree [PATH...] | --emit-baseline" >&2
    exit 2
}

MODE=""
TREE_PATHS=()
EMIT_BASELINE=0
case "${1:-}" in
    --staged)
        shift
        [ "$#" -eq 0 ] || usage
        MODE=staged
        ;;
    --tree)
        shift
        MODE=tree
        TREE_PATHS=("$@")
        ;;
    --emit-baseline)
        shift
        [ "$#" -eq 0 ] || usage
        MODE=tree
        EMIT_BASELINE=1
        ;;
    *)
        usage
        ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "check-git-env-scrub: not inside a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

# GIT_ENV_SCRUB_BASELINE overrides the baseline path — used by
# test-check-git-env-scrub.sh to point at a fixture baseline instead of the
# real one; unset in every production caller (pre-commit, CI).
BASELINE_FILE="${GIT_ENV_SCRUB_BASELINE:-$REPO_ROOT/scripts/guardrails/git-env-baseline.txt}"

line_hash() {
    # First 12 hex chars of the sha256 of the trimmed line content — stable
    # under re-indentation of SURROUNDING code, sensitive to a change of THIS
    # line, which is exactly what the ratchet wants to key on.
    printf '%s' "$1" | sha256sum | cut -c1-12
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_excluded_path() {
    case "$1" in
        */test-*.sh|test-*.sh) return 0 ;;
        *.test.mjs|*.test.js) return 0 ;;
        */fixtures/*|*/test-fixtures/*) return 0 ;;
    esac
    return 1
}

# ---- quote/comment-aware code stripping ----
# Replaces single- and double-quoted string content with spaces and truncates
# at the first unquoted `#`, in one pass. This is what keeps a case-pattern
# label, a string literal ("run git status"), and a comment from ever being
# mistaken for a real invocation, without a full shell tokenizer.
strip_code() {
    awk '
    {
        out = ""; instr = 0
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (instr == 0) {
                if (c == "#") { break }
                else if (c == "\047") { instr = 1; out = out " " }
                else if (c == "\"") { instr = 2; out = out " " }
                else { out = out c }
            } else if (instr == 1) {
                if (c == "\047") { instr = 0 } else { out = out " " }
            } else {
                if (c == "\\") { i++; out = out "  " }
                else if (c == "\"") { instr = 0 }
                else { out = out " " }
            }
        }
        print out
    }' <<<"$1"
}

is_git_invocation() {
    # code_only: comment/quote-stripped. A `git` word: start-of-line or a
    # shell separator before it, whitespace or end-of-line after it. Excludes
    # `git_clean` (next char `_`) and a case-label `git)` (next char `)`) by
    # construction.
    #
    # Captured rather than piped into `grep -q` (pipefail-ok would not save
    # us here: grep is the last command, so a match is never masked — but a
    # SIGPIPE-killed producer under pipefail WOULD still flip the pipeline
    # non-zero on an otherwise-real match; capturing sidesteps that class
    # entirely, HIMMEL-1430).
    local m
    m=$(printf '%s' "$1" | grep -E '(^|[;&|(`[:space:]])git([[:space:]]|$)') || true
    [ -n "$m" ]
}

exemption_reason_js() {
    printf '%s' "$1" | grep -oE '//[[:space:]]*git-env-ok:.*' | tail -n1 || true
}

# HITS accumulates human-readable "file[:line]: message" for the report.
# BASELINE_KEYS accumulates the matching machine keys, in the same order, for
# --emit-baseline.
HITS=()
BASELINE_KEYS=()

# ---- shell: file-level scan ----
scan_shell_file() {
    local f="$1" src="$2"
    is_excluded_path "$f" && return 0
    # A shebang-less .sh is USUALLY a sourced-only lib (whatever invokes it is
    # the entry point on the hook for scrubbing) — but that can't be assumed:
    # a shebang-less file that itself runs `git` in command position must say
    # so explicitly (a `# sourced-lib` marker), or it is scanned exactly like
    # an entry point. This is what stops a future shebang-less script that
    # IS an entry point (e.g. always invoked as `bash script.sh`) from being
    # silently exempted by the absence of a shebang alone.
    local first_line
    IFS= read -r first_line < "$src" || first_line=""
    local has_shebang=0
    case "$first_line" in '#!'*) has_shebang=1 ;; esac

    local lineno=0 line trimmed code_only
    local first_invoke=0
    local have_unset_dir=0 have_unset_wt=0 have_unset_cd=0 have_unset_if=0
    local sourced_helper=0 called_scrub=0 sourced_lib_marker=0
    local file_exempt_reason=""
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        trimmed=$(trim "$line")
        [ -z "$trimmed" ] && continue

        if [ -z "$file_exempt_reason" ]; then
            case "$trimmed" in
                '#'*git-env-ok:*)
                    file_exempt_reason=$(trim "${trimmed#*git-env-ok:}")
                    ;;
            esac
        fi
        # Exact standalone marker only (like git-env-ok's colon requirement)
        # — a comment that merely MENTIONS "sourced-lib" in prose (e.g. this
        # file's own docstring) must never count.
        case "$trimmed" in '# sourced-lib') sourced_lib_marker=1 ;; esac

        case "$trimmed" in '#'*) continue ;; esac
        code_only=$(strip_code "$line")

        if [ "$first_invoke" -eq 0 ] && is_git_invocation "$code_only"; then
            first_invoke=$lineno
            break
        fi

        case "$code_only" in *unset*)
            case "$code_only" in *GIT_DIR*) have_unset_dir=1 ;; esac
            case "$code_only" in *GIT_WORK_TREE*) have_unset_wt=1 ;; esac
            case "$code_only" in *GIT_COMMON_DIR*) have_unset_cd=1 ;; esac
            case "$code_only" in *GIT_INDEX_FILE*) have_unset_if=1 ;; esac
        ;; esac
        # Raw-line substring checks (not the stripped code_only): these two
        # markers are specific literal strings, not a git-command-position
        # question, and stripping mishandles nested $(...) quoting (e.g.
        # `. "$(dirname "$0")/../lib/git-clean.sh"`) in a way that can blank
        # out the substring. A false hit inside a comment is harmless here.
        case "$line" in *git-clean.sh*) sourced_helper=1 ;; esac
        case "$line" in *git_env_scrub*) called_scrub=1 ;; esac
    done < "$src"

    [ "$first_invoke" -eq 0 ] && return 0

    if [ -n "$file_exempt_reason" ]; then
        return 0
    fi
    if [ "$have_unset_dir" -eq 1 ] && [ "$have_unset_wt" -eq 1 ] && [ "$have_unset_cd" -eq 1 ] && [ "$have_unset_if" -eq 1 ]; then
        return 0
    fi
    if [ "$sourced_helper" -eq 1 ] && [ "$called_scrub" -eq 1 ]; then
        return 0
    fi
    if [ "$has_shebang" -eq 0 ] && [ "$sourced_lib_marker" -eq 1 ]; then
        return 0
    fi

    local key="SHELL:$f"
    if [ "$EMIT_BASELINE" -ne 1 ] && [ -r "$BASELINE_FILE" ] && grep -qxF "$key" "$BASELINE_FILE"; then
        return 0
    fi
    if [ "$has_shebang" -eq 0 ]; then
        HITS+=("$f:$first_invoke: no GIT_* env scrub before first git invocation (shebang-less — mark '# sourced-lib' if this file is only ever sourced)")
    else
        HITS+=("$f:$first_invoke: no GIT_* env scrub before first git invocation")
    fi
    BASELINE_KEYS+=("$key")
}

# ---- JS: per-call scan (unchanged shape, new baseline key) ----
scan_js_file() {
    local f="$1" content="$2" lineno=0 line trimmed marker reason window
    is_excluded_path "$f" && return 0
    local -a lines=()
    while IFS= read -r line || [ -n "$line" ]; do
        lines+=("$line")
    done < "$content"
    local n="${#lines[@]}"

    local -a remaining=()
    if [ "$EMIT_BASELINE" -ne 1 ] && [ -f "$BASELINE_FILE" ]; then
        while IFS= read -r bline || [ -n "$bline" ]; do
            case "$bline" in
                "JS:$f:"*) remaining+=("${bline#JS:"$f":}") ;;
            esac
        done < "$BASELINE_FILE"
    fi

    local i=0
    while [ "$i" -lt "$n" ]; do
        lineno=$((i + 1))
        line="${lines[$i]}"
        trimmed=$(trim "$line")
        i=$((i + 1))
        [ -z "$trimmed" ] && continue
        case "$trimmed" in '//'*) continue ;; esac
        local m
        m=$(printf '%s' "$line" | grep -E "(execFileSync|spawnSync|execSync|spawn)\\([[:space:]]*['\"]git['\"]") || true
        [ -n "$m" ] || continue
        # Window: this line plus the next 4, joined, to see a same-statement
        # scrub (e.g. an `env:` object on a following line).
        local end=$((lineno + 4))
        [ "$end" -gt "$n" ] && end=$n
        window="$line"
        local j=$lineno
        while [ "$j" -lt "$end" ]; do
            window="$window
${lines[$j]}"
            j=$((j + 1))
        done
        case "$window" in
            *GIT_DIR*GIT_WORK_TREE*GIT_COMMON_DIR*GIT_INDEX_FILE*) continue ;;
            *"gitClean("*) continue ;;
        esac
        marker=$(exemption_reason_js "$line")
        if [ -n "$marker" ]; then
            reason=$(trim "${marker#*:}")
            [ -n "$reason" ] && continue
            HITS+=("$f:$lineno: git-env-ok marker with no reason")
            continue
        fi

        local hash
        hash=$(line_hash "$trimmed")
        local consumed=0
        local idx
        for idx in "${!remaining[@]}"; do
            if [ "${remaining[$idx]}" = "$hash" ]; then
                unset 'remaining[idx]'
                consumed=1
                break
            fi
        done
        [ "$consumed" -eq 1 ] && continue

        HITS+=("$f:$lineno: unscrubbed JS git subprocess call")
        BASELINE_KEYS+=("JS:$f:$hash")
    done
}

is_trust_path() {
    local m
    m=$(printf '%s' "$1" | grep -E '^scripts/handover/|^scripts/lanes/|^scripts/hooks/|^scripts/cr/|^scripts/lib/go-gate\.sh$') || true
    [ -n "$m" ]
}

scan_one() {
    local f="$1" src="$2"
    case "$f" in
        *.sh) scan_shell_file "$f" "$src" ;;
        *.mjs|*.js) scan_js_file "$f" "$src" ;;
    esac
}

if [ "$MODE" = staged ]; then
    tmp_list=$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-list.XXXXXX") || exit 2
    trap 'rm -f "$tmp_list"' EXIT
    git diff --cached --name-only --diff-filter=ACM > "$tmp_list"
    while IFS= read -r f || [ -n "$f" ]; do
        [ -z "$f" ] && continue
        is_trust_path "$f" || continue
        case "$f" in *.sh|*.mjs|*.js) : ;; *) continue ;; esac
        tmp_blob=$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-blob.XXXXXX") || exit 2
        if git show ":$f" > "$tmp_blob" 2>/dev/null; then
            scan_one "$f" "$tmp_blob"
        fi
        rm -f "$tmp_blob"
    done < "$tmp_list"
else
    if [ "${#TREE_PATHS[@]}" -gt 0 ]; then
        for p in "${TREE_PATHS[@]}"; do
            if [ -f "$p" ]; then
                case "$p" in *.sh|*.mjs|*.js) scan_one "$p" "$p" ;; esac
            elif [ -d "$p" ]; then
                while IFS= read -r f; do
                    scan_one "$f" "$f"
                done < <(find "$p" -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' \) | sort)
            fi
        done
    else
        while IFS= read -r f; do
            is_trust_path "$f" || continue
            scan_one "$f" "$f"
        done < <(git ls-files 'scripts/handover' 'scripts/lanes' 'scripts/hooks' 'scripts/cr' 'scripts/lib/go-gate.sh' 2>/dev/null | grep -E '\.(sh|mjs|js)$')
    fi
fi

if [ "$EMIT_BASELINE" -eq 1 ]; then
    if [ "${#BASELINE_KEYS[@]}" -gt 0 ]; then
        printf '%s\n' "${BASELINE_KEYS[@]}" | sort
    fi
    exit 0
fi

if [ "${#HITS[@]}" -gt 0 ]; then
    echo "check-git-env-scrub: ${#HITS[@]} unscrubbed trust-path git finding(s):" >&2
    for h in "${HITS[@]}"; do
        echo "  $h" >&2
    done
    echo "" >&2
    echo "Shell: scrub GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE (unset, or" >&2
    echo "source scripts/lib/git-clean.sh and call git_env_scrub) before the file's" >&2
    echo "first git invocation, or mark the file '# git-env-ok: <reason>'." >&2
    echo "JS: route the call through gitClean() in scripts/lanes/git-clean.mjs, or" >&2
    echo "mark the line '// git-env-ok: <reason>'." >&2
    exit 1
fi

echo "check-git-env-scrub: clean"
exit 0
