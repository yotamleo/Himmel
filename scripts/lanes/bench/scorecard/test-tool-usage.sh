#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-tool-usage.sh - RED/GREEN suite for
# tool-usage.sh (HIMMEL-3513). House check_contains/PASS-FAIL style, per
# test-extra-metrics.sh in this same directory.
#
# Platform guard: no .ps1 twin, by design, same as every sibling in this dir.
# Hermetic: every case points SCORECARD_PROJECTS_DIR / SCORECARD_MEMORY_DIR /
# --memory-traps / --skill-cwd / --skill-config-dir at fixtures under
# fixtures/tool-usage/ - never at the live ~/.claude/projects tree or the
# live memory directory.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/tool-usage.sh"
fails=0

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle]"; fails=$((fails + 1)) ;;
    esac
}

check_not_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL - $name: expected NOT to find [$needle]"; fails=$((fails + 1)) ;;
        *) echo "ok - $name" ;;
    esac
}

# --- basic: skill invocations, slash commands, script calls (ok + error),
# a hook denial, a classifier denial, per-role split, never-used skills.
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/tool-usage/basic"

OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok - basic: tool-usage.sh exits 0"
else
    echo "FAIL - basic: tool-usage.sh rc=$rc (expected 0): $OUT"
    fails=$((fails + 1))
fi

check_contains "basic: skill invocation counted across both sessions" \
    "$OUT" "skill=himmel-ops:stuck-playbook count=2 sessions=2"
check_contains "basic: slash command counted" \
    "$OUT" "slash=/graphify count=1 sessions=1"
check_contains "basic: himmel script call counted" \
    "$OUT" "script=scripts/lib/bank-preflight.sh count=1"
check_contains "basic: jira op call counted under a jira: key" \
    "$OUT" "script=jira:get count=1"
check_contains "basic: a failed script call raises its error rate" \
    "$OUT" "script=scripts/lanes/bench/scorecard/agg-burn.sh count=1 sessions=1 errors=1"
check_contains "basic: himmel hook denial counted by hook name" \
    "$OUT" "hook=block-destructive-commands count=1"
check_contains "basic: classifier denial counted by bracketed category" \
    "$OUT" "classifier=[Out-of-Place Publication] count=1"
check_contains "basic: a hook denial lacking the glyph is still counted by hook name" \
    "$OUT" "hook=block-jira-compound-write count=1"
check_not_contains "basic: that hook denial's bracketed text is not misread as a classifier category" \
    "$OUT" "classifier=[External System Writes]"
check_not_contains "basic: a bracketed test-output tag without the classifier wrapper phrase is not counted" \
    "$OUT" "classifier=[FAIL]"
check_contains "basic: transcript coverage triple beside the scan" \
    "$OUT" "coverage: roots=1 discovered=2 parsed=2 skipped=0"
check_contains "basic: per-role split shows leg for the leg session" \
    "$OUT" "role=leg skill=himmel-ops:stuck-playbook count=1"
check_contains "basic: per-role split shows console for the console session" \
    "$OUT" "role=console skill=himmel-ops:stuck-playbook count=1"
check_not_contains "basic: the used skill is excluded from never-used" \
    "$OUT" "never-used: scope=project-skills name=stuck-playbook"
check_contains "basic: a guardrail-friction eval-candidate asks whether the denial is correct enforcement, not that it should go away" \
    "$OUT" "eval-candidates: defect=block-destructive-commands evidence_count=1 proposed_eval=\"reproduce block-destructive-commands's trigger; confirm whether the denial is correct enforcement or a false-positive papercut\""
check_contains "basic: a script-error eval-candidate asks whether the error is an expected rejection, not that it should go away (codex-5 asymmetry fix)" \
    "$OUT" "eval-candidates: defect=scripts/lanes/bench/scorecard/agg-burn.sh evidence_count=1 proposed_eval=\"reproduce scripts/lanes/bench/scorecard/agg-burn.sh; confirm whether the error is an expected rejection or a defect\""
check_contains "basic: an installed-but-uninvoked skill is listed never-used" \
    "$OUT" "never-used: scope=user-skills name=never-used-skill"
check_contains "basic: an installed-but-untyped command is listed never-used" \
    "$OUT" "never-used: scope=user-commands name=never-used-cmd"

# --- since-edge: a session entirely before --since must be excluded, and
# counted as skipped rather than silently dropped (HIMMEL-3269 coverage rule).
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/tool-usage/since-edge"
OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>/dev/null)
rc_since=$?
if [ "$rc_since" -eq 0 ]; then
    echo "ok - since-edge: tool-usage.sh exits 0"
else
    echo "FAIL - since-edge: tool-usage.sh rc=$rc_since (expected 0): $OUT"
    fails=$((fails + 1))
fi
check_not_contains "since-edge: the pre-window session's skill call is excluded" \
    "$OUT" "skill=himmel-ops:stuck-playbook count=1"
check_contains "since-edge: the excluded session is counted as skipped, not lost" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=0 skipped=1"

# --- memory-join: a hook-denial matching a fixture trap's pattern is
# RECURRING, an unseen trap is DORMANT, an empty-pattern trap is UNMATCHABLE;
# a Read of a file under SCORECARD_MEMORY_DIR is counted by basename.
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/tool-usage/memory-join"
export SCORECARD_MEMORY_DIR="$HERE/fixtures/tool-usage/memory-join/memory"
OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --memory-traps "$HERE/fixtures/tool-usage/memory-join/traps.json" \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>/dev/null)
rc_mem=$?
if [ "$rc_mem" -eq 0 ]; then
    echo "ok - memory-join: tool-usage.sh exits 0"
else
    echo "FAIL - memory-join: tool-usage.sh rc=$rc_mem (expected 0): $OUT"
    fails=$((fails + 1))
fi
check_contains "memory-join: a matched trap is RECURRING with a hit count" \
    "$OUT" "trap=trap-hit status=RECURRING hits=1"
check_contains "memory-join: an unmatched trap is DORMANT" \
    "$OUT" "trap=trap-dormant status=DORMANT hits=0"
check_contains "memory-join: an empty-pattern trap is UNMATCHABLE" \
    "$OUT" "trap=trap-bad status=UNMATCHABLE"
check_contains "memory-join: a Read under SCORECARD_MEMORY_DIR is counted by basename" \
    "$OUT" "memory-file-read: leg-lifecycle.md reads=1 sessions=1"
check_contains "memory-join: eval-candidates table carries the recurring trap" \
    "$OUT" "trap-hit"
check_contains "memory-join: eval-candidates table names a proposed eval" \
    "$OUT" "eval-candidates"

# --- memory-join-malformed: a malformed traps file must not silently report
# zero traps as if the join had succeeded (codex-5: the memory-trap jq call
# now carries the same WARNING guard sections 3/4 already have) -------------
OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --memory-traps "$HERE/fixtures/tool-usage/memory-join/traps-malformed.json.notjson" \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>&1)
rc_mem_bad=$?
if [ "$rc_mem_bad" -eq 0 ]; then
    echo "ok - memory-join-malformed: tool-usage.sh exits 0 (a jq failure here is a warning, not a fatal error)"
else
    echo "FAIL - memory-join-malformed: tool-usage.sh rc=$rc_mem_bad (expected 0): $OUT"
    fails=$((fails + 1))
fi
check_contains "memory-join-malformed: the jq failure is surfaced, not silent" \
    "$OUT" "tool-usage: WARNING: memory-trap join (jq) failed"

# --- command-window: a <command-name> entry outside --since/--until must not
# count even when the transcript FILE as a whole falls inside the window
# (codex-2: the CMDS extraction pass filters each command's own timestamp,
# not just the file's first/last) ------------------------------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/tool-usage/command-window"
OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>/dev/null)
rc_cmdwin=$?
if [ "$rc_cmdwin" -eq 0 ]; then
    echo "ok - command-window: tool-usage.sh exits 0"
else
    echo "FAIL - command-window: tool-usage.sh rc=$rc_cmdwin (expected 0): $OUT"
    fails=$((fails + 1))
fi
check_contains "command-window: an in-window command is counted" \
    "$OUT" "slash=/counted-cmd count=1"
check_not_contains "command-window: a command timestamped before --since is excluded even though the file itself parses" \
    "$OUT" "slash=/out-of-window-cmd"
check_contains "command-window: the file still counts as parsed, not skipped" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=1 skipped=0"

# --- partial-write: a file whose tool_use/tool_result enrichment pass fails
# (a malformed tool_use timestamp) must not leak its slash commands into the
# report, even though the earlier CMDS extraction pass for that same file
# succeeded on its own (codex-7: cmds_f is merged into CMDS only after every
# extraction pass for the file has succeeded) -------------------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/tool-usage/partial-write"
OUT=$("$SCRIPT" --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z \
    --skill-cwd "$HERE/fixtures/tool-usage/skills" \
    --skill-config-dir "$HERE/fixtures/tool-usage/skills-config" 2>&1)
rc_partial=$?
if [ "$rc_partial" -eq 0 ]; then
    echo "ok - partial-write: tool-usage.sh exits 0 (a jq failure here is a warning, not a fatal error)"
else
    echo "FAIL - partial-write: tool-usage.sh rc=$rc_partial (expected 0): $OUT"
    fails=$((fails + 1))
fi
check_not_contains "partial-write: a command from a file whose enrichment pass jq-failed is never counted" \
    "$OUT" "slash=/leaked-cmd"
check_not_contains "partial-write: a tool_use preceding the malformed timestamp is never counted either (EVENTS staged per-file, same as CMDS)" \
    "$OUT" "script=scripts/lib/bank-preflight.sh count=1"
check_contains "partial-write: the file is counted as jq-failed, not parsed" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=0 skipped=1 (jq-failed=1)"
check_contains "partial-write: the jq-failure warning is surfaced" \
    "$OUT" "tool-usage: WARNING: transcript(s) skipped due to jq failure"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-tool-usage.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-tool-usage.sh: $fails failure(s)"
    exit 1
fi
