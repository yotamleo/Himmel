#!/usr/bin/env bash
# HIMMEL-102 representative session - DO NOT EDIT without re-baselining.
# Usage: session.sh <arm> <out-dir>
#   arm: "baseline" or "plugin"
#   out-dir: directory to dump stdout per call (must exist)
set -uo pipefail
ARM="${1:?arm required: baseline|plugin}"
OUT="${2:?out-dir required}"
TS="$(date -u +%FT%TZ)"
STAMP="$(date +%s)"
mkdir -p "$OUT"

run() {
  local name="$1"; shift
  local file="$OUT/${ARM}-${name}.txt"
  { "$@" ; } > "$file" 2>&1 || true
  printf '%s %s -> %s (%d bytes)\n' "$TS" "$name" "$file" "$(wc -c <"$file")"
}

if [ "$ARM" = "baseline" ]; then
  # Raw CLI arm - direct invocations, no runner.
  JIRA_CMD=(node scripts/jira/dist/index.js)
  run jira-create-1 "${JIRA_CMD[@]}" create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-1"
  run jira-create-2 "${JIRA_CMD[@]}" create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-2"
  run jira-create-3 "${JIRA_CMD[@]}" create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-3"
  run jira-create-4 "${JIRA_CMD[@]}" create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-4"
  run jira-create-5 "${JIRA_CMD[@]}" create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-5"
  run jira-list-1   "${JIRA_CMD[@]}" list --project HIMTEST --status Done --limit 5
  run jira-list-2   "${JIRA_CMD[@]}" list --project HIMTEST --status Done --limit 5
  run jira-list-3   "${JIRA_CMD[@]}" list --project HIMTEST --status Done --limit 5
  run gh-pr-view-1  gh pr view 101 --repo yotamleo/himmel --json title,state,mergeable
  run gh-pr-view-2  gh pr view 102 --repo yotamleo/himmel --json title,state,mergeable
  run gh-pr-list-1  gh pr list --repo yotamleo/himmel --state open
  run gh-pr-list-2  gh pr list --repo yotamleo/himmel --state open --author @me
  run gh-pr-list-3  gh pr list --repo yotamleo/himmel --limit 5
  run gh-pr-checks-1 gh pr checks 101 --repo yotamleo/himmel
else
  # Plugin arm - go through himmel-run, capture the *summary line* that
  # Claude actually sees.
  run jira-create-1 himmel-run jira -- create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-1"
  run jira-create-2 himmel-run jira -- create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-2"
  run jira-create-3 himmel-run jira -- create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-3"
  run jira-create-4 himmel-run jira -- create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-4"
  run jira-create-5 himmel-run jira -- create --type Task --project HIMTEST --title "vm-smoke-${STAMP}-5"
  run jira-list-1   himmel-run jira -- list --project HIMTEST --status Done --limit 5
  run jira-list-2   himmel-run jira -- list --project HIMTEST --status Done --limit 5
  run jira-list-3   himmel-run jira -- list --project HIMTEST --status Done --limit 5
  run gh-pr-view-1  himmel-run gh -- pr view 101 --repo yotamleo/himmel --json title,state,mergeable
  run gh-pr-view-2  himmel-run gh -- pr view 102 --repo yotamleo/himmel --json title,state,mergeable
  run gh-pr-list-1  himmel-run gh -- pr list --repo yotamleo/himmel --state open
  run gh-pr-list-2  himmel-run gh -- pr list --repo yotamleo/himmel --state open --author @me
  run gh-pr-list-3  himmel-run gh -- pr list --repo yotamleo/himmel --limit 5
  run gh-pr-checks-1 himmel-run gh -- pr checks 101 --repo yotamleo/himmel
fi

echo "OK arm=$ARM count=14"
