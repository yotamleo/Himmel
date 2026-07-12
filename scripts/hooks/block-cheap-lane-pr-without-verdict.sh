#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): block `gh pr create` for a
# cheap-glm branch that has NO d1_verdict record in its spawn-glm session meta
# (HIMMEL-654 WS7, spec D1.4 deferred-structural half).
#
# This is the STRUCTURAL enforcement of the D1 lane-gate verdict that
# scripts/cr/d1-verdict.sh writes behaviorally. It is BUILT but NOT wired into
# marketplace/plugins/himmel-ops/hooks/hooks.json until a SECOND observed drift
# (a cheap-lane PR opened with no d1_verdict) — the HIMMEL-195 escalate-on-drift
# rule. Until then the verdict discipline is behavioral (validating-session).
#
# Scope: cheap-glm ONLY. Only glm has a session substrate to look a verdict up
# in (spawn-glm writes glm/<slug> branches + <BRIDGE_ROOT>/glm-sessions/ meta).
# A codex/* branch has NO session under glm-sessions/, so gating it would
# spuriously hard-block every Codex PR — cheap-codex therefore ALLOWS here and
# its structural enforcement WAITS on the FUTURE hermes task→branch record
# (spec D1.1, SC2). claude-lane branches ALLOW (this hook only gates cheap-glm).
#
# Input: PreToolUse JSON on stdin:
#   { "tool_name": "Bash", "tool_input": { "command": "...", ... }, ... }
#
# Exit semantics (per Claude Code hooks docs):
#   - exit 0 → allow tool use
#   - exit 2 → block tool use; stderr shown to model + user
#
# Fail-open policy (matches every sibling block-* hook): if THIS script errors
# (missing jq/git/node, malformed JSON, session-root not found), exit 0 with a
# stderr warning. We never block on our own bugs — the validating session still
# catches a truly ungated PR. Fail-CLOSED (exit 2) only on the genuine condition:
# a cheap-glm branch whose matching session meta carries no d1_verdict.
set -euo pipefail

warn() { echo "block-cheap-lane-pr-without-verdict: $*" >&2; }

# Read stdin once (small payload).
payload=""
if ! payload=$(cat); then
    warn "WARNING: could not read stdin; fail-open"
    exit 0
fi

# Fast-path: pure-bash substring check before shelling out. The PreToolUse hook
# fires on every Bash call; short-circuit the vast majority that never touch
# `gh pr create`. A false positive here only costs the slow path below.
case "$payload" in
    *"gh pr create"*) ;;  # might be a real invocation — fall through
    *) exit 0 ;;
esac

# Extract tool_input.command (jq first, grep -oP fallback) — mirrors
# check-cr-marker-on-pr-create.sh exactly.
extract_command() {
    local input="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null
        return
    fi
    echo "$input" | grep -oP '"command"\s*:\s*"(\\.|[^"\\])*"' \
        | head -1 \
        | sed -E 's/^"command"\s*:\s*"(.*)"$/\1/' \
        | sed 's/\\"/"/g'
}

cmd=$(extract_command "$payload" || true)
if [ -z "$cmd" ]; then
    exit 0  # malformed JSON / non-Bash tool — fail-open
fi

# Only gate `gh pr create` at a command position (start-of-string or after a
# command-separator). Anchored exactly as check-cr-marker-on-pr-create.sh.
# shellcheck disable=SC2016  # literal $ inside the character class — intentional
if ! echo "$cmd" | grep -qE '(^|[;&|`$(]\s*)gh\s+pr\s+create\b'; then
    exit 0
fi

# Resolve the PR's source branch. Prefer --head (worktree-independent); fall
# back to the project_dir branch. Mirrors check-cr-marker-on-pr-create.sh.
head_branch=""
set -f
# shellcheck disable=SC2086  # intentional word-splitting of the command
set -- $cmd
set +f
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head=*) head_branch="${1#--head=}" ;;
        --head|-H)
            if [ "$#" -ge 2 ]; then head_branch="$2"; fi
            ;;
    esac
    shift
done

if [ -n "$head_branch" ]; then
    branch="${head_branch##*:}"  # strip owner: fork prefix; marker keyed by bare name
else
    project_dir="${CLAUDE_PROJECT_DIR:-}"
    if [ -z "$project_dir" ] || ! command -v git >/dev/null 2>&1; then
        warn "WARNING: no --head and CLAUDE_PROJECT_DIR/git unavailable; fail-open"
        exit 0
    fi
    branch=$(git -C "$project_dir" branch --show-current 2>/dev/null || true)
fi
if [ -z "$branch" ]; then
    warn "WARNING: no branch resolved (no --head, detached HEAD?); fail-open"
    exit 0
fi

# Classify. Only cheap-glm is gated; cheap-codex and claude ALLOW.
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cr/lane-classify.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
if ! . "$hook_dir/../cr/lane-classify.sh" 2>/dev/null; then
    warn "WARNING: could not source lane-classify.sh; fail-open"
    exit 0
fi
if [ "$(lane_classify "$branch")" != "cheap-glm" ]; then
    exit 0  # claude-lane or cheap-codex (no glm session substrate) → allow
fi

# cheap-glm: require a d1_verdict in at least one matching session, and NONE of
# the matching sessions may lack it. node is the JSON tool the cr scripts use;
# missing node → fail-open.
if ! command -v node >/dev/null 2>&1; then
    warn "WARNING: node not on PATH; fail-open"
    exit 0
fi
slug="${branch#glm/}"
scan_root="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/glm-sessions"

# node exit codes: 0 = all matching sessions carry a verdict (allow);
# 2 = no matching session OR a matching session lacks a verdict (block);
# 3 = scan_root not readable (own-bug → fail-open).
verdict_rc=0
node -e '
const fs=require("fs"), path=require("path");
const [root, slug]=process.argv.slice(1);
let dirs;
try { dirs=fs.readdirSync(root); } catch { process.exit(3); }
let matched=0, missing=false;
for (const d of dirs) {
  const mp=path.join(root, d, "meta.json");
  let m;
  try { m=JSON.parse(fs.readFileSync(mp, "utf8")); } catch { continue; }
  if (m.task_name === slug) {
    matched++;
    if (m.d1_verdict === undefined || m.d1_verdict === null || m.d1_verdict === "") missing=true;
  }
}
if (matched === 0) process.exit(2);   // no gate run for this branch
if (missing) process.exit(2);         // a matching session has no verdict
process.exit(0);
' "$scan_root" "$slug" || verdict_rc=$?

case "$verdict_rc" in
    0) exit 0 ;;
    3) warn "WARNING: glm-sessions root not found ($scan_root); fail-open"; exit 0 ;;
    2)
        echo "cheap-lane PR for ${branch} has no d1_verdict record. Run the D1 lane gate + scripts/cr/d1-verdict.sh first." >&2
        exit 2 ;;
    *) warn "WARNING: verdict scan errored (rc=$verdict_rc); fail-open"; exit 0 ;;
esac
