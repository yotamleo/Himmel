#!/usr/bin/env bash
# scripts/cr/impacted-suites.sh — which test suites exercise the files a PR
# changed (HIMMEL-2821).
#
# WHY. PR #2261 changed scripts/machine-setup/uninstall-plugins.sh and merged
# with scripts/test-uninstall.sh — a suite one directory UP that drives it end
# to end — never run: its implementor swept the owning directory, its certifier
# ran /pr-check, and nothing in the ship tail computed "which suites reference
# what this PR changed". Private main went red and it surfaced only on public
# CI. "Owning suites" was prose resolved by directory proximity; this is the
# structural replacement.
#
# Usage:
#   impacted-suites.sh <base>..<head> [--shell]
#       Print the union, one repo-relative path per line, sorted. For every
#       file changed between merge-base(<base>,<head>) and <head> (deletions
#       included, renames counted as delete+add), list each suite at <head>
#       whose text references the file's basename — or, for a slash command or
#       skill, `/<name>`. A changed suite lists itself. --shell keeps only
#       test-*.sh (what run-shell-tests.sh can run); the *.test.mjs / .js / .ts
#       suites are listed without it and are run by their own runner.
#   impacted-suites.sh --check <base>..<head>
#       The verdict gate. Reads one line per impacted suite from stdin:
#           SUITE <path> = PASS
#           SUITE <path> = SKIP <reason>          (reason required)
#           SUITE <path> = BLOCKED <denial>       (denial required)
#       Exit 0 when every impacted suite has one; exit 1, naming each on
#       stderr, when any is missing — the /pr-check row is then NOT clean.
#
# Exit codes: 0 ok / clean; 1 --check found a missing verdict; 2 usage or an
# unresolvable range. A range that cannot be resolved is an ERROR, never an
# empty list: an empty impacted set reads as "nothing to run".
#
# ponytail: references are DIRECT and textual. A suite that reaches a changed
# file only through an intermediate script it calls (no mention of the changed
# file's basename), or builds the path at runtime ("$dir/uninstall-$kind.sh"),
# is not found — the union under-approximates. Widen a suite's text with the
# basename of what it really drives rather than adding a transitive walk here.
# A basename shared by many files (lib.sh) over-approximates on purpose; the
# safe direction for a gate is a suite too many, never one too few.
#
# Platform guard: POSIX bash 3.2+ (no mapfile / associative arrays); runs
# under Git Bash on Windows. No .ps1 twin — it is a git + grep pipeline.
set -uo pipefail

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed -n 's/^# \{0,1\}//p' >&2
}

check=0
shell_only=0
range=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check=1; shift ;;
        --shell) shell_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "impacted-suites.sh: unknown flag: $1" >&2; exit 2 ;;
        *)
            if [ -n "$range" ]; then
                echo "impacted-suites.sh: unexpected argument: $1" >&2; exit 2
            fi
            range="$1"; shift ;;
    esac
done

case "$range" in
    *..*) ;;
    *) echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2 ;;
esac
base="${range%%..*}"
head="${range#*..}"
head="${head#.}"   # tolerate <base>...<head>
if [ -z "$base" ] || [ -z "$head" ]; then
    echo "impacted-suites.sh: expected <base>..<head>, got '${range}'" >&2; exit 2
fi

if ! base_sha=$(git rev-parse --verify --quiet --end-of-options "${base}^{commit}"); then
    echo "impacted-suites.sh: base '${base}' does not resolve to a commit" >&2; exit 2
fi
if ! head_sha=$(git rev-parse --verify --quiet --end-of-options "${head}^{commit}"); then
    echo "impacted-suites.sh: head '${head}' does not resolve to a commit" >&2; exit 2
fi
if ! mb=$(git merge-base "$base_sha" "$head_sha"); then
    echo "impacted-suites.sh: no merge-base between '${base}' and '${head}'" >&2; exit 2
fi
if ! changed=$(git -c core.quotepath=off diff --name-only --no-renames "$mb" "$head_sha"); then
    echo "impacted-suites.sh: git diff ${mb}..${head_sha} failed" >&2; exit 2
fi
if ! tree=$(git -c core.quotepath=off ls-tree -r --name-only "$head_sha"); then
    echo "impacted-suites.sh: git ls-tree ${head_sha} failed" >&2; exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/impacted-suites.XXXXXX") || { echo "impacted-suites.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT
pats="$work/patterns"
found="$work/found"
: > "$pats"
: > "$found"

suite_re='(^|/)test-[^/]*\.sh$|\.test\.(mjs|js|ts)$'
suites=$(grep -E "$suite_re" <<< "$tree" || true)
# Basenames that name nothing on their own: match them by "<parent>/<name>".
generic_re='^(README\.md|CLAUDE\.md|SKILL\.md|CHANGELOG\.md|index\.(js|mjs|ts)|package\.json|package-lock\.json|\.gitignore|LICENSE)$'

# add_needle <literal> — one ERE per needle: a literal bounded so `install.sh`
# never matches `uninstall.sh` and `/pr-check` never matches `/pr-check_x`.
add_needle() {
    local esc
    esc=$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g')
    printf '(^|[^A-Za-z0-9_.-])%s($|[^A-Za-z0-9_-])\n' "$esc" >> "$pats"
}

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -Eq "$suite_re" <<< "$f"; then
        # A changed suite is impacted by itself (unless the PR deleted it).
        if grep -Fxq -- "$f" <<< "$suites"; then printf '%s\n' "$f" >> "$found"; fi
        continue
    fi
    name="${f##*/}"
    if grep -Eq "$generic_re" <<< "$name"; then
        case "$f" in
            */*) parent="${f%/*}"; add_needle "${parent##*/}/$name" ;;
        esac
    else
        add_needle "$name"
    fi
    case "$f" in
        .claude/commands/*.md|marketplace/plugins/*/commands/*.md)
            add_needle "/${name%.md}" ;;
        */skills/*/SKILL.md)
            skill="${f%/SKILL.md}"; add_needle "/${skill##*/}" ;;
    esac
done <<< "$changed"

if [ -s "$pats" ]; then
    # git grep on the resolved <head> tree, not the working tree: the answer is
    # about the PR as pushed. -l prefixes each path with "<head_sha>:".
    git grep -l -E -f "$pats" "$head_sha" -- \
        ':(glob)**/test-*.sh' ':(glob)**/*.test.mjs' ':(glob)**/*.test.js' ':(glob)**/*.test.ts' \
        2>/dev/null | sed "s/^${head_sha}://" >> "$found"
fi

impacted="$work/impacted"
if [ "$shell_only" -eq 1 ]; then
    grep -E '(^|/)test-[^/]*\.sh$' "$found" | sort -u > "$impacted" || true
else
    sort -u "$found" > "$impacted"
fi

if [ "$check" -eq 0 ]; then
    cat "$impacted"
    exit 0
fi

# --check: every impacted suite needs a valid verdict line on stdin.
have="$work/have"
awk '
    /^SUITE +[^ ]+ += +(PASS|SKIP|BLOCKED)( +.*)?$/ {
        path = $2
        verdict = $4
        reason = $0
        sub(/^SUITE +[^ ]+ += +(PASS|SKIP|BLOCKED) */, "", reason)
        if (verdict == "PASS" || reason ~ /[^ \t\r]/) print path
    }
' | sort -u > "$have"
missing="$work/missing"
comm -23 "$impacted" "$have" > "$missing"
n_impacted=$(wc -l < "$impacted" | tr -d ' ')
n_missing=$(wc -l < "$missing" | tr -d ' ')
printf 'impacted-suites: %s impacted, %s without a verdict\n' "$n_impacted" "$n_missing"
if [ "$n_missing" -gt 0 ]; then
    while IFS= read -r s; do
        printf 'impacted-suites: MISSING VERDICT %s\n' "$s" >&2
    done < "$missing"
    exit 1
fi
exit 0
