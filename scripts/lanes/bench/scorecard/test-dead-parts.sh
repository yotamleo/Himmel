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
WTPATH="$TMPREPO-worktree"
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below
cleanup() { git -C "$TMPREPO" worktree remove --force "$WTPATH" 2>/dev/null; rm -rf "$TMPREPO" "$WTPATH" "${BROKENREPO:-}"; }
trap cleanup EXIT

cp -R "$HERE/fixtures/dead-parts/basic-repo/." "$TMPREPO/" || { echo "FAIL - fixture copy"; exit 1; }
git -C "$TMPREPO" init -q || { echo "FAIL - git init"; exit 1; }
git -C "$TMPREPO" add -A || { echo "FAIL - git add"; exit 1; }
git -C "$TMPREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - git commit"; exit 1; }

# --- basic: one entry per class, plus the precedence rule -------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok - basic: dead-parts.sh exits 0"
else
    echo "FAIL - basic: dead-parts.sh rc=$rc (expected 0): $OUT"
    fails=$((fails + 1))
fi

check_contains "basic: script class counts (USED/WIRED/TEST-ONLY/DOC-ONLY/DEAD)" \
    "$OUT" "kind=script USED=2 WIRED=3 TEST-ONLY=3 DOC-ONLY=1 DEAD=5"
check_contains "basic: command class counts" \
    "$OUT" "kind=command USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: skill class counts" \
    "$OUT" "kind=skill USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: agent class counts" \
    "$OUT" "kind=agent USED=1 WIRED=1 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: totals line sums every kind" \
    "$OUT" "totals: USED=5 WIRED=4 TEST-ONLY=3 DOC-ONLY=1 DEAD=8"
check_contains "basic: transcript coverage line beside the table" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=1 skipped=0"

check_contains "basic: USED script detected via a Bash tool_use naming its path" \
    "$OUT" $'script\tfoo-used\tscripts/foo-used.sh'
check_contains "basic: USED skill detected via a Skill tool_use" \
    "$OUT" $'skill\tused-skill\t.claude/skills/used-skill/SKILL.md'
check_contains "basic: USED command detected via a typed <command-name> tag" \
    "$OUT" $'command\tused-cmd\t.claude/commands/used-cmd.md'
check_contains "basic: WIRED script whose own self-referencing header used to mask a real external basename reference (codex-3 unmasking fix)" \
    "$OUT" $'script\tcaller\tscripts/caller.sh\tWIRED'
check_contains "basic: WIRED script whose own full-path doc mention used to mask a real basename-only code caller (codex-2 unmasking fix)" \
    "$OUT" $'script\tdoc-and-code\tscripts/doc-and-code.sh\tWIRED'
check_contains "basic: the basename-only caller itself has no reference anywhere and stays DEAD" \
    "$OUT" $'script\trelative-caller\tscripts/relative-caller.sh\tDEAD'
check_contains "basic: a mention living inside a nested fixtures/ dir does not count as a reference (codex-1 fixture-blind-spot fix)" \
    "$OUT" $'script\tfixture-blind\tscripts/fixture-blind.sh\tDEAD'
check_contains "basic: a mention living inside a top-level fixtures/ dir (no leading slash) does not count as a reference either (codex-2 top-level-fixtures fix)" \
    "$OUT" $'script\ttoplevel-blind\tscripts/toplevel-blind.sh\tDEAD'
check_contains "basic: plugin-qualified Skill tool_use (fixture-plugin:used-skill) still matches the bare discovered skill name" \
    "$OUT" $'skill\tused-skill\t.claude/skills/used-skill/SKILL.md\tUSED'
check_contains "basic: Agent tool_use subagent_type marks a zero-static-reference agent USED" \
    "$OUT" $'agent\tused-agent\t.claude/agents/used-agent.md\tUSED'
check_contains "basic: a Bash command with an embedded newline still counts its second line's script as USED" \
    "$OUT" $'script\tmultiline-used\tscripts/multiline-used.sh\tUSED'

check_contains "basic: DEAD list header" "$OUT" "--- DEAD (no reference anywhere, no transcript call)"
check_contains "basic: DEAD script with only a self-referencing header comment stays DEAD (self-match excluded)" \
    "$OUT" $'script\tqux-deadd\tscripts/qux-deadd.sh\tDEAD'
check_contains "basic: DEAD command" "$OUT" $'command\tdead-cmd\t.claude/commands/dead-cmd.md\tDEAD'
check_contains "basic: DEAD skill" "$OUT" $'skill\tdead-skill\t.claude/skills/dead-skill/SKILL.md\tDEAD'
check_contains "basic: DEAD agent" "$OUT" $'agent\tdead-agent\t.claude/agents/dead-agent.md\tDEAD'

check_contains "basic: DOC-ONLY list header" "$OUT" "--- DOC-ONLY (referenced only from docs/*.md)"
check_contains "basic: DOC-ONLY script referenced only from docs/readme.md" \
    "$OUT" $'script\tquux-doc\tscripts/quux-doc.sh\tDOC-ONLY'

check_contains "basic: precedence - a script referenced by BOTH a test file and a doc lands TEST-ONLY, not DOC-ONLY" \
    "$OUT" $'script\tprecedence-test\tscripts/precedence-test.sh\tTEST-ONLY'
check_contains "basic: a script referenced only from a .spec.* file lands TEST-ONLY (codex-3 .spec.* naming fix)" \
    "$OUT" $'script\tspec-testonly\tscripts/spec-testonly.sh\tTEST-ONLY'
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
rc2=$?
if [ "$rc2" -eq 0 ]; then
    echo "ok - out-of-window: dead-parts.sh exits 0"
else
    echo "FAIL - out-of-window: dead-parts.sh rc=$rc2 (expected 0): $OUT2"
    fails=$((fails + 1))
fi

check_contains "out-of-window: the pre-window transcript is discovered but skipped, not silently dropped" \
    "$OUT2" "coverage: roots=1 discovered=1 parsed=0 skipped=1 (out-of-window=1)"
check_contains "out-of-window: a Bash call before --since does not count as USED - the script stays DEAD" \
    "$OUT2" $'script\tout-of-window\tscripts/out-of-window.sh\tDEAD'

# --- non-chronological: a transcript whose PHYSICAL first and last records are
# both out-of-window must not skip an in-window record sitting between them -
# the window check must scan every record's timestamp, not just head/tail
# (round-6 codex-1) ------------------------------------------------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/non-chronological-transcripts"
OUT5=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)
rc5=$?
if [ "$rc5" -eq 0 ]; then
    echo "ok - non-chronological: dead-parts.sh exits 0"
else
    echo "FAIL - non-chronological: dead-parts.sh rc=$rc5 (expected 0): $OUT5"
    fails=$((fails + 1))
fi
check_contains "non-chronological: an in-window Bash call is not discarded because the file's first and last physical records are both out-of-window (round-6 codex-1 fix)" \
    "$OUT5" $'script\tqux-deadd\tscripts/qux-deadd.sh\tUSED'

# --- linked worktree: --repo-root pointing at a worktree whose .git is a
# FILE (`gitdir: ...`), not a directory - every leg runs from exactly this
# shape, and a `[ -d "$REPO_ROOT/.git" ]` check (the pre-fix code) rejects it
# outright even though the repo is perfectly valid ---------------------------
git -C "$TMPREPO" worktree add -q -b test-dead-parts-wt "$WTPATH" >/dev/null 2>&1 \
    || { echo "FAIL - git worktree add"; fails=$((fails + 1)); }
if [ -f "$WTPATH/.git" ]; then
    echo "ok - linked worktree: .git is a file, not a directory (precondition)"
else
    echo "FAIL - linked worktree: expected $WTPATH/.git to be a file"
    fails=$((fails + 1))
fi
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT3=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$WTPATH" 2>&1)
rc3=$?
if [ "$rc3" -eq 0 ]; then
    echo "ok - linked worktree: dead-parts.sh accepts a file-shaped .git and exits 0"
else
    echo "FAIL - linked worktree: dead-parts.sh rc=$rc3 (expected 0): $OUT3"
    fails=$((fails + 1))
fi
check_contains "linked worktree: still reports the classification table" \
    "$OUT3" "--- entry-point classification"

# --- broken repo lookup: --repo-root's `.git` exists (passes the earlier
# `[ -e "$REPO_ROOT/.git" ]` guard) but is corrupt, so `git ls-files` itself
# fails - the report must abort loudly, never fall through to an empty
# discovery file and a "successful" table claiming every entry point is
# missing (round-8 codex-3) --------------------------------------------------
BROKENREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-broken.XXXXXX") || { echo "FAIL - mktemp broken repo"; fails=$((fails + 1)); }
mkdir -p "$BROKENREPO/scripts"
printf 'not a real gitfile\n' > "$BROKENREPO/.git"
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT4=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$BROKENREPO" 2>&1)
rc4=$?
if [ "$rc4" -ne 0 ]; then
    echo "ok - broken repo: dead-parts.sh aborts (rc=$rc4) instead of reporting success"
else
    echo "FAIL - broken repo: dead-parts.sh exited 0 despite a failed git ls-files"
    fails=$((fails + 1))
fi
check_contains "broken repo: the abort names the failing git ls-files call, not a silent empty report" \
    "$OUT4" "dead-parts: git ls-files failed for --repo-root"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-dead-parts.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-dead-parts.sh: $fails failure(s)"
    exit 1
fi
