#!/usr/bin/env bash
# Tests for guard-judge-writes.sh (HIMMEL-4564): a judge session
# (HIMMEL_CONSOLE_JUDGE=1, exported by headed-arm-leg.sh --judge) is denied
# every outward or mutating transition — push, PR create/comment/review/merge,
# the merge and GO scripts, Jira writes, inbox sends, a foreign MCP tool, and an
# Edit/Write outside its verdict and scratch dirs — while its reads and its
# verdict write pass. Every row runs twice: with the marker (expect the row's
# rc) and without it (expect a silent allow), pinning the marker-gated no-op.
#
# Usage: bash scripts/hooks/test-guard-judge-writes.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; not ported to native PowerShell — the
# judge lane (headed-arm-leg.sh --judge) is Linux-only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-judge-writes.sh"

BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/judge-guard-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
ROOT="$TMP/handovers"
REPO="$TMP/repo"
mkdir -p "$FAKE_HOME/.cache/himmel/verdicts/J1/scratch" "$ROOT/u/himmel/verdicts/J1" "$ROOT/inbox" "$REPO/scripts"
ln -s "$REPO/scripts" "$ROOT/u/himmel/verdicts/J1/escape"

pass=0
fail=0

# run <payload-json> <marker 0|1> — prints the hook's rc.
run() {
    local payload="$1" marker="$2" rc
    if [ "$marker" = "1" ]; then
        printf '%s' "$payload" | env HOME="$FAKE_HOME" HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_JUDGE=1 "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$payload" | env -u HIMMEL_CONSOLE_JUDGE HOME="$FAKE_HOME" HANDOVER_DIR="$ROOT" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    fi
    rc=$?
    printf '%s' "$rc"
}

# row <label> <expected rc with marker> <payload-json>
row() {
    local label="$1" want="$2" payload="$3" got
    got=$(run "$payload" 1)
    if [ "$got" = "$want" ]; then
        echo "ok   judge: $label (rc=$got)"; pass=$((pass + 1))
    else
        echo "FAIL judge: $label — expected rc=$want, got rc=$got"; fail=$((fail + 1))
    fi
    got=$(run "$payload" 0)
    if [ "$got" = "0" ]; then
        echo "ok   normal session: $label (rc=0)"; pass=$((pass + 1))
    else
        echo "FAIL normal session: $label — expected rc=0, got rc=$got"; fail=$((fail + 1))
    fi
}

bash_payload() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
file_payload() { jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, content:"x"}}'; }
mcp_payload() { jq -nc --arg t "$1" '{tool_name:$t, tool_input:{}}'; }

# --- push ---
row "git push" 2 "$(bash_payload 'git push origin HEAD')"
row "git -C <dir> push" 2 "$(bash_payload "git -C $REPO push -u origin fix/x")"
# --- PR create / comment / review / merge ---
row "gh pr create" 2 "$(bash_payload 'gh pr create --title t --body-file b.md')"
row "gh pr comment" 2 "$(bash_payload 'gh pr comment 12 --body-file b.md')"
row "gh pr review" 2 "$(bash_payload 'gh pr review 12 --approve')"
row "gh pr merge" 2 "$(bash_payload 'gh pr merge 12 --squash')"
row "gh api POST comment" 2 "$(bash_payload 'gh api repos/o/r/issues/12/comments -f body=x')"
row "leg-pr-open.sh" 2 "$(bash_payload 'bash scripts/lanes/leg-pr-open.sh t.txt b.md')"
row "merge-on-green.sh" 2 "$(bash_payload 'bash /repo/scripts/handover/merge-on-green.sh')"
row "go.sh" 2 "$(bash_payload 'bash scripts/handover/console-kit/go.sh 12 abc')"
# --- Jira writes ---
row "jira create" 2 "$(bash_payload 'node /repo/scripts/jira/dist/index.js create --type Task --summary s')"
row "jira comment" 2 "$(bash_payload 'node /repo/scripts/jira/dist/index.js comment HIMMEL-1 --comment-file c.md')"
row "jira transition" 2 "$(bash_payload 'node /repo/scripts/jira/dist/index.js transition HIMMEL-1 Done')"
row "leg-jira-status.sh" 2 "$(bash_payload 'bash scripts/handover/console-kit/leg-jira-status.sh HIMMEL-1 Done')"
row "foreign MCP write" 2 "$(mcp_payload 'mcp__claude_ai_Slack__slack_send_message')"
# --- inbox sends ---
row "inbox-send.sh" 2 "$(bash_payload 'bash scripts/handover/console-kit/inbox-send.sh --to c --file m.md')"
# --- marker override ---
row "marker named in command" 2 "$(bash_payload 'env -u HIMMEL_CONSOLE_JUDGE bash x.sh')"
# --- Edit / Write outside the verdict and scratch dirs ---
row "Write into a repo file" 2 "$(file_payload Write "$REPO/scripts/x.sh")"
row "Edit a repo file" 2 "$(file_payload Edit "$REPO/scripts/x.sh")"
row "Write into the inbox" 2 "$(file_payload Write "$ROOT/inbox/m.md")"
row "Write through a symlink out of verdicts" 2 "$(file_payload Write "$ROOT/u/himmel/verdicts/J1/escape/x.sh")"
row "Write with a .. segment" 2 "$(file_payload Write "$ROOT/u/himmel/verdicts/J1/../../x.md")"
row "malformed payload" 2 'not json'
# --- what a judge must still be able to do ---
row "verdict file write" 0 "$(file_payload Write "$ROOT/u/himmel/verdicts/J1/HIMMEL-1-judge-J1.md")"
row "scratch write under ~/.cache" 0 "$(file_payload Write "$FAKE_HOME/.cache/himmel/verdicts/J1/scratch/notes.md")"
row "own judge doc write" 0 "$(file_payload Edit "$ROOT/u/himmel/HIMMEL-1-judge-J1-2026-10-06.md")"
row "git log read" 0 "$(bash_payload 'git log -1 --format=%H')"
row "gh pr view read" 0 "$(bash_payload 'gh pr view 12 --json state')"
row "gh pr diff read" 0 "$(bash_payload 'gh pr diff 12')"
row "jira get read" 0 "$(bash_payload 'node /repo/scripts/jira/dist/index.js get HIMMEL-1')"
row "append-results bullet" 0 "$(bash_payload 'bash scripts/handover/console-kit/append-results.sh d.md "LIVE x"')"
row "qmd MCP read" 0 "$(mcp_payload 'mcp__qmd__query')"
row "Read tool" 0 "$(jq -nc '{tool_name:"Read", tool_input:{file_path:"/etc/hostname"}}')"

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
