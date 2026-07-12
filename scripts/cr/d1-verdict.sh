#!/usr/bin/env bash
# d1-verdict — WS7 D1 lane-gate verdict record writer (HIMMEL-654, spec D1.4).
#
# The unquarantine gate's PASS/FAIL persistence. A Claude-family validating
# session (⚑ Fork A default owner) that has run the D1 lane gate on a cheap-lane
# worker branch writes its verdict here. Two effects:
#   1. merges a `d1_verdict` field into the spawn-glm session-dir meta.json
#      (value "<verdict> (<rubric>)", default rubric R1-R4);
#   2. prints the one-line PR-body snippet `d1_verdict: <verdict> (<rubric>)` to
#      stdout — the validating session pastes it into `gh pr create --body`.
# D5's gated-merge count reads this record + git history (NOT the CR ledger,
# which carries critic findings, not lane verdicts).
#
# `--lane` writes the classifier-vocabulary flag to a DISTINCT key `d1_lane` —
# it NEVER clobbers spawn-glm's own `lane:"glm"` field (different vocabulary;
# D5/WS10 corpus readers key on `lane`). v1 accepts `cheap-glm` only —
# `cheap-codex` is DROPPED until the Codex session substrate (the FUTURE hermes
# task→branch record) exists; a manually-flagged Codex branch is recorded in the
# PR-body snippet, not the meta.
#
# Fail-closed on the verdict-presence axis: a missing --session-dir, a missing
# meta.json, or an invalid --verdict is a REFUSAL (exit 2), no partial write.
# This is the record whose ABSENCE means "not PR-eligible" (spec D1.4).
#
# Enforcement honesty: writing this record is BEHAVIORALLY enforced v1
# (validating-session discipline). Nothing structurally requires it until the
# lane-marker hook (scripts/hooks/block-cheap-lane-pr-without-verdict.sh) is
# escalated on drift (HIMMEL-195). The CR-marker hook already structurally
# enforces the panel/CR half; this is the lane-rubric half.
#
# bash 3.2-safe; node is the JSON tool the cr scripts already depend on.
# Exit codes: 0 — wrote the record; 2 — refusal (fail-closed on verdict axis).
set -euo pipefail

SESSION_DIR=""
VERDICT=""
RUBRIC=""
LANE=""

usage() {
    cat <<'EOF'
Usage: d1-verdict.sh --session-dir <dir> --verdict pass|fail [--rubric "R1-R4"] [--lane cheap-glm]

Merges a d1_verdict record into <dir>/meta.json and prints the PR-body snippet.
Fail-closed (exit 2) on missing --session-dir, missing meta.json, or bad --verdict.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --session-dir) SESSION_DIR="${2:-}"; shift 2 ;;
        --verdict)     VERDICT="${2:-}"; shift 2 ;;
        --rubric)      RUBRIC="${2:-}"; shift 2 ;;
        --lane)        LANE="${2:-}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "ERR d1-verdict: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Validate (fail-closed on the verdict-presence axis).
case "$VERDICT" in pass|fail) ;; *)
  echo "ERR d1-verdict: --verdict must be pass|fail (got: ${VERDICT:-<empty>})" >&2; exit 2 ;; esac
[ -n "$SESSION_DIR" ] || { echo "ERR d1-verdict: --session-dir required" >&2; exit 2; }
META="$SESSION_DIR/meta.json"
[ -f "$META" ] || { echo "ERR d1-verdict: no meta.json at $META (not a spawn-glm session dir?)" >&2; exit 2; }
RUBRIC="${RUBRIC:-R1-R4}"
# --lane v1 accepts cheap-glm only (cheap-codex waits on the Codex session
# substrate — the FUTURE hermes task→branch record). Refuse anything else.
case "${LANE:-}" in ""|cheap-glm) ;; *)
  echo "ERR d1-verdict: --lane accepts cheap-glm only (got: $LANE)" >&2; exit 2 ;; esac

# Merge d1_verdict (+ optional d1_lane) into meta.json — node is the JSON tool
# the cr scripts already depend on; string args are injection-safe (no shell
# interp). d1_lane is a DISTINCT key: spawn-glm's own lane:"glm" field uses a
# different vocabulary and the D5/WS10 corpus readers key on it — never clobber.
# shellcheck disable=SC2016  # ${...} below are JS template literals, not shell expansions
node -e '
const fs = require("fs");
const [mp, verdict, rubric, lane] = process.argv.slice(1);
const m = JSON.parse(fs.readFileSync(mp, "utf8"));
m.d1_verdict = `${verdict} (${rubric})`;
if (lane) m.d1_lane = lane;
fs.writeFileSync(mp, JSON.stringify(m, null, 2) + "\n");
' "$META" "$VERDICT" "$RUBRIC" "${LANE:-}"

printf 'd1_verdict: %s (%s)\n' "$VERDICT" "$RUBRIC"
