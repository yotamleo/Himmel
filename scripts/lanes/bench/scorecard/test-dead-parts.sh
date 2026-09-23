#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-dead-parts.sh - RED/GREEN suite for
# dead-parts.sh (HIMMEL-3513 EXPANSION 2). House check_contains/PASS-FAIL
# style, per test-extra-metrics.sh.
#
# Hermetic: never git-greps the live himmel repo. A throwaway fixture git
# repo is built fresh under a mktemp dir from the committed, .git-free tree at
# fixtures/dead-parts/basic-repo/ (a nested .git can never be committed into
# this repo itself - that would turn the fixture into a broken gitlink for
# the outer himmel repo). The transcript scan uses SCORECARD_PROJECTS_DIR
# fixtures, same convention as test-extra-metrics.sh.
#
# Platform guard: no .ps1 twin, by design.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/dead-parts.sh"
fails=0

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle]"; fails=$((fails + 1)) ;;
    esac
}

TMPREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts.XXXXXX") || { echo "FAIL - mktemp"; exit 1; }
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below
cleanup() { rm -rf "$TMPREPO"; }
trap cleanup EXIT

cp -R "$HERE/fixtures/dead-parts/basic-repo/." "$TMPREPO/" || { echo "FAIL - fixture copy"; exit 1; }
git -C "$TMPREPO" init -q || { echo "FAIL - git init"; exit 1; }
git -C "$TMPREPO" add -A || { echo "FAIL - git add"; exit 1; }
git -C "$TMPREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - git commit"; exit 1; }

# --- basic: one entry per class, plus the precedence rule -------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)

check_contains "basic: script class counts (USED/WIRED/TEST-ONLY/DOC-ONLY/DEAD)" \
    "$OUT" "kind=script USED=1 WIRED=1 TEST-ONLY=2 DOC-ONLY=1 DEAD=3"
check_contains "basic: command class counts" \
    "$OUT" "kind=command USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: skill class counts" \
    "$OUT" "kind=skill USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: agent class counts" \
    "$OUT" "kind=agent USED=0 WIRED=1 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: totals line sums every kind" \
    "$OUT" "totals: USED=3 WIRED=2 TEST-ONLY=2 DOC-ONLY=1 DEAD=6"
check_contains "basic: transcript coverage line beside the table" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=1 skipped=0"

check_contains "basic: USED script detected via a Bash tool_use naming its path" \
    "$OUT" $'script\tfoo-used\tscripts/foo-used.sh'
check_contains "basic: USED skill detected via a Skill tool_use" \
    "$OUT" $'skill\tused-skill\t.claude/skills/used-skill/SKILL.md'
check_contains "basic: USED command detected via a typed <command-name> tag" \
    "$OUT" $'command\tused-cmd\t.claude/commands/used-cmd.md'

check_contains "basic: DEAD list header" "$OUT" "--- DEAD (no reference anywhere, no transcript call)"
check_contains "basic: DEAD script with only a self-referencing header comment stays DEAD (self-match excluded)" \
    "$OUT" $'script\tqux-deadd\tscripts/qux-deadd.sh'
check_contains "basic: DEAD script with zero references at all" \
    "$OUT" $'script\tcaller\tscripts/caller.sh'
check_contains "basic: DEAD command" "$OUT" $'command\tdead-cmd\t.claude/commands/dead-cmd.md'
check_contains "basic: DEAD skill" "$OUT" $'skill\tdead-skill\t.claude/skills/dead-skill/SKILL.md'
check_contains "basic: DEAD agent" "$OUT" $'agent\tdead-agent\t.claude/agents/dead-agent.md'

check_contains "basic: DOC-ONLY list header" "$OUT" "--- DOC-ONLY (referenced only from docs/*.md)"
check_contains "basic: DOC-ONLY script referenced only from docs/readme.md" \
    "$OUT" $'script\tquux-doc\tscripts/quux-doc.sh'

check_contains "basic: precedence - a script referenced by BOTH a test file and a doc lands TEST-ONLY, not DOC-ONLY" \
    "$OUT" $'script\tprecedence-test\tscripts/precedence-test.sh'
dead_section=$(printf '%s\n' "$OUT" | sed -n '/^--- DEAD /,/^--- DOC-ONLY /p')
if printf '%s\n' "$dead_section" | grep -q 'precedence-test'; then
    echo "FAIL - precedence: precedence-test.sh must not appear in the DEAD list"
    fails=$((fails + 1))
else
    echo "ok - precedence: precedence-test.sh absent from DEAD"
fi
# it must appear exactly once in the classified table (as TEST-ONLY), never twice
occurrences=$(printf '%s\n' "$OUT" | grep -c 'precedence-test')
if [ "$occurrences" -eq 1 ]; then
    echo "ok - precedence: precedence-test.sh classified exactly once"
else
    echo "FAIL - precedence: precedence-test.sh should appear exactly once in the report, got $occurrences"
    fails=$((fails + 1))
fi

# --- out-of-window: a Bash call before --since must not count as USED, and
# must not leak into the DEAD verdict for an otherwise-unreferenced script ---
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/out-of-window-transcripts"
OUT2=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)

check_contains "out-of-window: the pre-window transcript is discovered but skipped, not silently dropped" \
    "$OUT2" "coverage: roots=1 discovered=1 parsed=0 skipped=1 (out-of-window=1)"
check_contains "out-of-window: a Bash call before --since does not count as USED - the script stays DEAD" \
    "$OUT2" $'script\tout-of-window\tscripts/out-of-window.sh'

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-dead-parts.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-dead-parts.sh: $fails failure(s)"
    exit 1
fi
