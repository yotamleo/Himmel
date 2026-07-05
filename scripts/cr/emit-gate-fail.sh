#!/usr/bin/env bash
# emit-gate-fail — D6 blocking-fail corpus emission (HIMMEL-654 WS7, spec D6).
#
# Today file-deferred-issues.sh files ONLY the deferred tier (NIT/LOW/…);
# blocking CRITICAL/HIGH/IMPORTANT CR fails are NOT persisted (they block the
# marker and get fixed in place). WS7 places ONE added emission: blocking CR
# fails on a CHEAP-LANE branch are appended to the SAME session-dir gate-report
# path as lane fails, so WS10's self-improvement corpus includes the failures
# that matter. No new storage system (YAGNI) — session dirs are the corpus v1.
#
# The blocking tier (CRITICAL|HIGH|IMPORTANT) is its own set — NOT the complement
# of file-deferred-issues's deferred set. MEDIUM sits in neither and is captured
# by neither filer (unchanged from today).
#
# Cheap-lane only (spec D6): a branch that classifies `claude` via lane_classify
# emits nothing (Claude-lane blocking fails are fixed in place, not corpus'd).
#
# Report contract (spec D2): each emitted line preserves file:line + severity
# verbatim from the CR output.
#
# bash 3.2-safe; reuses file-deferred-issues.sh's line grammar verbatim.
# Exit codes: 0 — completed (incl. nothing-to-do); 1 — usage/scan error.
set -euo pipefail

# shellcheck source=scripts/cr/lane-classify.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(dirname "${BASH_SOURCE[0]}")/lane-classify.sh"

SESSION_DIR=""
INPUT=""
BRANCH=""
PR_NUMBER=""

usage() {
    cat <<'EOF'
Usage: emit-gate-fail.sh --session-dir <dir> --input <file|-> [--branch <name>] [--pr <n>]

Appends one JSON line per blocking (CRITICAL|HIGH|IMPORTANT) CR finding to
<dir>/gate-report.jsonl. Cheap-lane branches only (spec D6). Idempotent.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --session-dir) SESSION_DIR="${2:-}"; shift 2 ;;
        --input)       INPUT="${2:-}"; shift 2 ;;
        --branch)      BRANCH="${2:-}"; shift 2 ;;
        --pr)          PR_NUMBER="${2:-}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "ERR emit-gate-fail: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$SESSION_DIR" ] || { echo "ERR emit-gate-fail: --session-dir required" >&2; exit 1; }
[ -d "$SESSION_DIR" ] || { echo "ERR emit-gate-fail: --session-dir not a directory: $SESSION_DIR" >&2; exit 1; }
[ -n "$INPUT" ] || { echo "ERR emit-gate-fail: --input required" >&2; exit 1; }

SEV_REGEX='CRITICAL|HIGH|IMPORTANT'
REPORT="$SESSION_DIR/gate-report.jsonl"

# Cheap-lane gate (spec D6): claude-lane blocking fails are fixed in place, not
# corpus'd here. This check runs BEFORE any write, so a claude-lane branch never
# creates the report file.
if [ -n "$BRANCH" ] && [ "$(lane_classify "$BRANCH")" = "claude" ]; then
  echo "emit-gate-fail: $BRANCH is claude-lane — blocking fails fixed in place, not corpus'd (spec D6)."
  exit 0
fi

# Resolve input — '-' reads stdin; else must be a readable file.
if [ "$INPUT" = "-" ]; then
    INPUT_CONTENT=$(cat)
elif [ -f "$INPUT" ] && [ -r "$INPUT" ]; then
    INPUT_CONTENT=$(cat "$INPUT")
else
    echo "ERR emit-gate-fail: --input file not readable: $INPUT" >&2
    exit 1
fi

# Same grammar as file-deferred-issues.sh (bullets/backticks stripped, LINE
# optional), with the blocking severity set. `set +e` lets us inspect grep's rc
# without pipefail exiting; rc=1 (no match) is fine, rc>1 is a real error.
set +e
# shellcheck disable=SC2016  # single-quoted sed expressions are intentional (literal regex)
blocking=$(printf '%s\n' "$INPUT_CONTENT" \
  | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/^`+//; s/`+$//' \
  | grep -E "^[^[:space:]:]+(:[0-9]+)?:[[:space:]]*(${SEV_REGEX})[[:space:]]*:")
rc=$?; set -e
[ "$rc" -gt 1 ] && { echo "ERR emit-gate-fail: scan failed (rc=$rc)" >&2; exit 1; }
[ -z "$blocking" ] && { echo "emit-gate-fail: no blocking findings in input."; exit 0; }

while IFS= read -r line; do
  [ -z "$line" ] && continue
  # idempotent: skip if this exact finding is already recorded
  if [ -f "$REPORT" ] && node -e '
    const fs=require("fs"),[rp,f]=process.argv.slice(1);
    const hit=fs.readFileSync(rp,"utf8").split("\n").filter(Boolean)
      .some(l=>{try{return JSON.parse(l).finding===f}catch{return false}});
    process.exit(hit?0:1);' "$REPORT" "$line"; then continue; fi
  node -e '
    const fs=require("fs");const [rp,b,pr,f]=process.argv.slice(1);
    fs.appendFileSync(rp, JSON.stringify({
      ts:new Date().toISOString(), branch:b||null,
      pr: pr?Number(pr):null, rubric:"CR", finding:f}) + "\n");
  ' "$REPORT" "$BRANCH" "$PR_NUMBER" "$line"
done <<< "$blocking"
echo "emit-gate-fail: wrote blocking findings to $REPORT"
