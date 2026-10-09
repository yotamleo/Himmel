#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-headed-arm-leg.sh
# scripts/handover/console-kit/test-leg-pretrust.sh - suite for leg-pretrust.sh
# (HIMMEL-5056): the launcher's folder/hooks-trust pre-accept.
#
# Asserts:
#   1. a fresh linked worktree has NO trust entry before and an accepted one
#      after; unrelated keys and other projects survive verbatim.
#   2. a path under $HOME/.himmel/eval/ qualifies.
#   3. refusals (exit 3, config never created): $HOME, /, the primary checkout,
#      /tmp-style dirs, a worktree NOT under .claude/worktrees/, the eval root
#      itself.
#   4. each lane writes the config file its claude reads.
#   5. concurrent writers lose no keys.
#   6. an unparseable config is refused (exit 4) and left byte-identical.
# Everything runs under LEG_PRETRUST_HOME in a temp dir; the real ~/.claude.json
# is never touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/leg-pretrust.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-pretrust-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

export LEG_PRETRUST_HOME="$tmp/home"
mkdir -p "$LEG_PRETRUST_HOME"
cfg="$LEG_PRETRUST_HOME/.claude.json"
trusted() { jq -r --arg k "$2" '.projects[$k].hasTrustDialogAccepted // "absent"' "$1" 2>/dev/null || echo "nofile"; }

primary="$tmp/primary"
git init -q "$primary"
git -C "$primary" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$primary/.claude/worktrees"
git -C "$primary" worktree add -q -b wt1 "$primary/.claude/worktrees/wt1"
git -C "$primary" worktree add -q -b wt-out "$tmp/outside-wt"

# 1. RED shape: no entry before, accepted after, other keys preserved.
printf '%s' '{"numStartups":7,"projects":{"/other":{"allowedTools":["x"],"hasTrustDialogAccepted":false}}}' > "$cfg"
check "1a fresh worktree: no trust entry before" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "absent"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "1b worktree: exit 0" "$rc" "0"
check "1c worktree: trust accepted after" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "true"
check "1d unrelated top-level key preserved" "$(jq -r .numStartups "$cfg")" "7"
check "1e other project untouched" "$(jq -c '.projects["/other"]' "$cfg")" '{"allowedTools":["x"],"hasTrustDialogAccepted":false}'
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "1f idempotent: second run exit 0" "$rc" "0"

# 2. eval clone path.
mkdir -p "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01"
rc=0; bash "$SCRIPT" native "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01" >/dev/null 2>&1 || rc=$?
check "2a eval clone: exit 0" "$rc" "0"
check "2b eval clone: trusted" "$(trusted "$cfg" "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01")" "true"

# 3. refusals write nothing.
rm -f "$cfg"
mkdir -p "$tmp/scratch-dir" "$LEG_PRETRUST_HOME/.himmel/eval"
for bad in "$LEG_PRETRUST_HOME" / "$primary" "$tmp/scratch-dir" "$tmp/outside-wt" "$LEG_PRETRUST_HOME/.himmel/eval" "$primary/.claude/worktrees"; do
  rc=0; bash "$SCRIPT" native "$bad" >/dev/null 2>&1 || rc=$?
  check "3 refused ($bad): exit 3" "$rc" "3"
  check "3 refused ($bad): no config written" "$([ -e "$cfg" ] && echo yes || echo no)" "no"
done
# a symlink under the eval root pointing outside must not launder a path
ln -s "$tmp/scratch-dir" "$LEG_PRETRUST_HOME/.himmel/eval/link"
rc=0; bash "$SCRIPT" native "$LEG_PRETRUST_HOME/.himmel/eval/link" >/dev/null 2>&1 || rc=$?
check "3 refused (symlink out of eval root): exit 3" "$rc" "3"

# 4. lanes (the lane launcher owns its config dir; the helper never creates one).
rc=0; bash "$SCRIPT" deepseek "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "4 absent lane dir: exit 4, dir not created" "$rc$([ -d "$LEG_PRETRUST_HOME/.claude-deepseek" ] && echo made)" "4"
mkdir -p "$LEG_PRETRUST_HOME/.claude-codex" "$LEG_PRETRUST_HOME/.claude-openrouter" "$LEG_PRETRUST_HOME/.claude-deepseek"
for pair in "claudex:.claude-codex" "openrouter:.claude-openrouter" "deepseek:.claude-deepseek"; do
  lane="${pair%%:*}"; sub="${pair#*:}"
  rc=0; bash "$SCRIPT" "$lane" "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
  check "4 lane $lane: exit 0" "$rc" "0"
  check "4 lane $lane: writes its own config" "$(trusted "$LEG_PRETRUST_HOME/$sub/.claude.json" "$primary/.claude/worktrees/wt1")" "true"
done
rc=0; bash "$SCRIPT" glm "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "4 unknown lane: exit 2" "$rc" "2"

# 5. concurrent writers lose nothing.
rm -f "$cfg"
printf '%s' '{"keep":"me","projects":{"/pre":{"hasTrustDialogAccepted":true}}}' > "$cfg"
n=12
for i in $(seq 1 $n); do git -C "$primary" worktree add -q -b "c$i" "$primary/.claude/worktrees/c$i"; done
for i in $(seq 1 $n); do bash "$SCRIPT" native "$primary/.claude/worktrees/c$i" >/dev/null 2>&1 & done
wait
got=0
for i in $(seq 1 $n); do [ "$(trusted "$cfg" "$primary/.claude/worktrees/c$i")" = "true" ] && got=$((got+1)); done
check "5a concurrent: all $n entries present" "$got" "$n"
check "5b concurrent: pre-existing project kept" "$(trusted "$cfg" /pre)" "true"
check "5c concurrent: top-level key kept" "$(jq -r .keep "$cfg")" "me"
check "5d concurrent: lock released" "$([ -e "$cfg.leg-pretrust.lock" ] && echo held || echo free)" "free"

# 6. unparseable config is never clobbered.
printf '%s' '{"projects": {oops' > "$cfg"
before="$(cksum < "$cfg")"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "6a unparseable config: exit 4" "$rc" "4"
check "6b unparseable config: byte-identical" "$(cksum < "$cfg")" "$before"
check "6c unparseable config: lock released" "$([ -e "$cfg.leg-pretrust.lock" ] && echo held || echo free)" "free"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-leg-pretrust.sh"; exit 0; fi
echo "FAIL - test-leg-pretrust.sh ($fails failure(s))"; exit 1
