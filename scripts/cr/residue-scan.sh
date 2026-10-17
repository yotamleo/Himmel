#!/usr/bin/env bash
# scripts/cr/residue-scan.sh - /pr-check advisory: expired-transition residue
# in the PR's own diff.
#
# Flags each ADDED line that looks like scaffolding for a one-time transition
# (a removal, rename or migration) that would outlive the PR:
#   a  removal-guard test: a negative assertion whose label says gone/removed/
#      no longer/..., or whose quoted needle appears on a line this diff removes
#   b  literal source grep: a test reading a source file and asserting a string
#   c  transition code: legacy/deprecated/compat-shim/old-path handling
#   d  transition gate: a deny/refuse/block row whose text says retired/dropped
#   e  transition prose: "X was removed" / "(removed)" in a doc
# The author drops it, keeps it with a stated reason, or gives it an expiry:
# a line carrying `ponytail:` or `residue-keep: <reason>` is never flagged.
#
# ADVISORY ONLY - always exits 0. Diff-scoped, deterministic, no LLM call.
#
# Usage:
#   bash scripts/cr/residue-scan.sh                  # <default-branch>...HEAD
#   bash scripts/cr/residue-scan.sh --diff-file <f>  # a unified diff (-U0 ok)
#
# Stdout: "residue-scan (advisory): N finding(s)" then "  - [class] file:line: text".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/git-clean.sh" 2>/dev/null || { echo "residue-scan: git-clean.sh missing, skipped."; exit 0; }
# shellcheck source=../lib/prim.sh
# shellcheck disable=SC1091
if ! { [ -r "$HIMMEL_ROOT/scripts/lib/prim.sh" ] && . "$HIMMEL_ROOT/scripts/lib/prim.sh"; } 2>/dev/null; then
    echo "residue-scan: prim.sh missing, skipped."
    exit 0
fi

diff_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --diff-file) shift; if [ $# -gt 0 ]; then diff_file="$1"; shift; fi ;;
        *) shift ;;
    esac
done

tmp="$(tmpdir)" || exit 0
trap 'rm -rf "$tmp"' EXIT

if [ -z "$diff_file" ]; then
    db=""
    # shellcheck source=../guardrails/lib.sh
    # shellcheck disable=SC1091
    if . "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null; then
        db="$(default_branch 2>/dev/null || true)"
    fi
    [ -n "$db" ] || db=main
    git_clean diff -U0 --no-color "$db...HEAD" > "$tmp/d.diff" 2>/dev/null || : > "$tmp/d.diff"
    diff_file="$tmp/d.diff"
fi
[ -r "$diff_file" ] || { echo "residue-scan: diff unreadable, skipped."; exit 0; }

# Two passes over the same diff: pass 1 gathers removed-line text, pass 2
# classifies added lines. POSIX awk only (mawk/gawk/BSD).
awk '
function is_test(p) {
    return (p ~ /(^|\/)test-[^\/]*$/ || p ~ /\.(test|spec)\.[a-z]+$/ || p ~ /(^|\/)(tests|__tests__)\//)
}
function skip_path(p) {
    return (p ~ /(^|\/)testdata\// || p ~ /(^|\/)residue-scan\.sh$/ || p ~ /(^|\/)test-residue-scan\.sh$/ \
        || p ~ /^\.claude\/skills\/test-audit\// || p ~ /(^|\/)specs\// || p ~ /(^|\/)handovers\//)
}
function has_marker(s) {
    return (s ~ /(gone|removed|no longer|dropped|retired|legacy|stale|not name|renamed)/)
}
# A quoted needle (>= 4 chars) of this line that a removed line also contains.
function needle_removed(line,    rest, q, n) {
    rest = line
    while (match(rest, /"[^"]+"/)) {
        q = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (length(q) >= 4 && index(removed, q) > 0) return 1
    }
    return 0
}
function emit(cls, text) {
    n++
    if (length(text) > 110) text = substr(text, 1, 110) "..."
    out[n] = sprintf("  - [%s] %s:%d: %s", cls, file, ln, text)
}
NR == FNR {
    if ($0 ~ /^-[^-]/ || $0 == "-") removed = removed "\n" substr($0, 2)
    next
}
/^\+\+\+ / { file = $0; sub(/^\+\+\+ (b\/)?/, "", file); next }
/^--- /    { next }
/^@@ /     { s = $0; sub(/^[^+]*\+/, "", s); sub(/[, ].*/, "", s); ln = s + 0; next }
/^\+/ {
    text = substr($0, 2); cur = ln; ln = ln + 1;
    if (file == "/dev/null" || skip_path(file)) next
    if (text ~ /^[ \t]*$/ || text ~ /ponytail:|residue-keep:/) next
    low = tolower(text)
    saved = ln; ln = cur
    if (is_test(file)) {
        if (low ~ /(assert_not_contains|assert_not_has|assert_no_match|nogrep|not\.tocontain|\.not\.to|! *grep -q|refute)/ \
            && (has_marker(low) || needle_removed(text))) emit("a", text)
        else if ((low ~ /readfilesync\([^)]*(src|script|source|\.sh|\.ts|\.mjs|\.js)/ && low ~ /(tocontain|tomatch)/) \
            || (low ~ /grep -q[a-z]* / && text ~ /\$\{?(SCRIPT|LIB|HOOK|SRC|HELPER)[A-Z_]*\}?/)) emit("b", text)
    } else if (file ~ /\.md$/) {
        if (low ~ /(was|were|has been|have been) (now )?(removed|dropped|renamed|retired|deleted)/ \
            || low ~ /\((removed|dropped|retired)\)/) emit("e", text)
    } else if (file ~ /(^|\/)(hooks|guardrails)\// || file ~ /pre-commit-config/ || file ~ /doctor/) {
        if (low ~ /(deny|refus|reject|forbid|block )/ && low ~ /(removed|no longer|dropped|retired|gone)/) emit("d", text)
        else if (low ~ /(^|[^a-z])(legacy|deprecated|compat shim|old path|backward.compat)([^a-z]|$)/) emit("c", text)
    } else {
        if (low ~ /(^|[^a-z])(legacy|deprecated|compat shim|old path|old format|backward.compat|migration shim)([^a-z]|$)/) emit("c", text)
    }
    ln = saved
    next
}
/^[ ]/ { ln = ln + 1; next }
END {
    printf "residue-scan (advisory): %d finding(s)\n", n
    for (i = 1; i <= n; i++) print out[i]
    if (n > 0) print "  Drop each one, keep it with `residue-keep: <security/safety reason>`, or give it an expiry (`ponytail: <ceiling>, <upgrade path>`). Does not block this PR."
}
' "$diff_file" "$diff_file"

exit 0
