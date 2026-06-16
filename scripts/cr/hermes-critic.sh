#!/usr/bin/env bash
# scripts/cr/hermes-critic.sh — Orchestrator-Critic reviewer over a branch diff
# (HIMMEL-273). Claude implements, a fresh model family reviews: this script
# assembles the final code changes (NEVER the orchestrator's plans/reasoning —
# reviewer isolation, ticket item 3), sends them through the hermes chokepoint
# (scripts/hermes/invoke.sh) under a strict JSON response contract, and
# enforces a fail-closed verdict.
#
# Verdict policy (fail-closed, ticket item 2): any security_concerns or
# logic_errors entry forces passed=false regardless of what the model set.
#
# Bounded auto-fix loop (ticket item 4) lives in the ORCHESTRATOR, not here:
# on exit 1, feed the JSON report back to the implementer, fix, re-run.
# Max 2-3 iterations, then escalate to the operator.
#
# Failure mode (ticket item 5): hermes quota/auth/transport errors exit 3
# (fail-open) with a warning on stderr — the caller falls back to the
# gemini-cli route or claude-only review and notes that in its summary.
#
# Exit codes:
#   0  review ran, verdict passed=true   (JSON report on stdout)
#   1  review ran, verdict passed=false  (JSON report on stdout)
#   2  usage / not a git repo / empty diff
#   3  hermes transport/auth/quota failure or unparseable response (fail-open)
#
# Usage:
#   hermes-critic.sh [--repo <dir>] [--base <ref>] [--goal "<text>"|--goal-file <p>]
#                    [--model <name>] [--max-pack-bytes <n>]
#
# Defaults: repo = cwd; base = merge-base with origin/main (fallback main);
# model = nvidia/nemotron-3-nano-30b-a3b (spike 2026-06-12: 8s latency,
# strict JSON obedience on NIM free tier; the 550b ultra took 105s+ on a
# trivial prompt and times out on review-shaped ones).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../hermes/invoke.sh"

usage() {
    cat >&2 <<'EOF'
Usage: hermes-critic.sh [--repo <dir>] [--base <ref>]
                        [--goal "<text>" | --goal-file <path>]
                        [--model <name>] [--max-pack-bytes <n>]

Reviews the diff base..HEAD with a hermes-routed critic model under a strict
JSON contract. JSON report on stdout. Exit 0 pass / 1 fail / 2 usage / 3
transport (fail-open — fall back to another review route).
EOF
}

repo=""
base=""
goal=""
goal_file=""
model="nvidia/nemotron-3-nano-30b-a3b"
max_pack_bytes=200000

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)      [ $# -ge 2 ] || { usage; exit 2; }; repo="$2"; shift 2 ;;
        --base)      [ $# -ge 2 ] || { usage; exit 2; }; base="$2"; shift 2 ;;
        --goal)      [ $# -ge 2 ] || { usage; exit 2; }; goal="$2"; shift 2 ;;
        --goal-file) [ $# -ge 2 ] || { usage; exit 2; }; goal_file="$2"; shift 2 ;;
        --model)     [ $# -ge 2 ] || { usage; exit 2; }; model="$2"; shift 2 ;;
        --max-pack-bytes) [ $# -ge 2 ] || { usage; exit 2; }; max_pack_bytes="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "hermes-critic.sh: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -n "$repo" ]; then
    cd "$repo" || { echo "hermes-critic.sh: cannot cd to --repo: $repo" >&2; exit 2; }
fi
git rev-parse --git-dir >/dev/null 2>&1 || { echo "hermes-critic.sh: not a git repo: $(pwd)" >&2; exit 2; }

if [ -n "$goal_file" ]; then
    [ -f "$goal_file" ] || { echo "hermes-critic.sh: goal file not found: $goal_file" >&2; exit 2; }
    goal="$(cat "$goal_file")"
fi
[ -n "$goal" ] || goal="(no task goal provided — review the change on its own merits)"

# Resolve the diff base: explicit --base, else merge-base with origin/main,
# else main. The diff is the FINAL code change only (reviewer isolation).
# Two-dot semantics ($base HEAD) everywhere: with a merge-base SHA the result
# equals three-dot, and with an explicit --base ref two-dot is what the
# caller literally asked to compare against.
if [ -z "$base" ]; then
    base="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "")"
fi
[ -n "$base" ] || { echo "hermes-critic.sh: could not resolve a diff base (no origin/main or main merge-base — pass --base)" >&2; exit 2; }

diff_text="$(git diff "$base" HEAD)" || { echo "hermes-critic.sh: git diff failed for base $base" >&2; exit 2; }
if [ -z "$diff_text" ]; then
    echo "hermes-critic.sh: empty diff vs $base — nothing to review" >&2
    exit 2
fi

# Context pack: the post-change content of each touched file (the critic sees
# what the code IS, not how the orchestrator got there), truncated to the
# byte budget. nemotron-3-nano context is 262K tokens; default 200KB of pack
# stays comfortably inside it alongside the diff.
pack_file="$(mktemp "${TMPDIR:-/tmp}/hermes-critic-pack.XXXXXX")"
trap 'rm -f "$pack_file"' EXIT

{
    printf '%s\n' "You are an independent code-review critic in an Orchestrator-Critic pipeline. The implementation was produced by a different model; review the FINAL code change on its objective merits, like a human PR reviewer. You are seeing only the code — no plans, no chat history."
    printf '%s\n' ""
    printf '%s\n' "Respond with ONLY a JSON object — no markdown fences, no prose before or after — matching exactly this schema:"
    printf '%s\n' '{"passed": boolean, "security_concerns": string[], "logic_errors": string[], "architectural_mismatches": string[], "suggestions": string[], "summary": string}'
    printf '%s\n' "Rules: passed=false if there is ANY security concern or logic error. architectural_mismatches = the change fights the surrounding code's structure or conventions. suggestions = non-blocking improvements."
    printf '%s\n' ""
    printf '%s\n' "## Original task goal"
    printf '%s\n' "$goal"
    printf '%s\n' ""
    printf '%s\n' "## Diff under review ($base..HEAD)"
    printf '%s\n' "$diff_text"
    printf '%s\n' ""
    printf '%s\n' "## Post-change content of touched files (truncated to budget)"
    git diff --name-only "$base" HEAD | while IFS= read -r f; do
        [ -f "$f" ] || continue   # deleted files have no post-change content
        printf '\n===== %s =====\n' "$f"
        cat "$f"
    done
} | head -c "$max_pack_bytes" > "$pack_file"
# head -c closing the pipe early SIGPIPEs the writers (rc 141) — that is
# intended truncation, not an error. Anything else is a real assembly failure.
pack_rc=${PIPESTATUS[0]}
if [ "$pack_rc" -ne 0 ] && [ "$pack_rc" -ne 141 ]; then
    echo "hermes-critic.sh: context-pack assembly failed (rc=$pack_rc)" >&2
    exit 2
fi
if [ "$(wc -c < "$pack_file")" -ge "$max_pack_bytes" ]; then
    printf '\n[CONTEXT PACK TRUNCATED AT %s BYTES — file contents above may end mid-file]\n' "$max_pack_bytes" >> "$pack_file"
fi

# Dispatch through the chokepoint. Toolset stays the invoke.sh default (todo,
# neutralized) — a critic must not run tools. Stderr is captured (not
# discarded): auth/quota errors must reach the operator, not be collapsed
# into an anonymous transport failure.
err_file="$(mktemp "${TMPDIR:-/tmp}/hermes-critic-err.XXXXXX")"
trap 'rm -f "$pack_file" "$err_file"' EXIT
raw="$(bash "$INVOKE" --model "$model" --prompt-file "$pack_file" 2>"$err_file")"
rc=$?
if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    hermes_err="$(cat "$err_file" 2>/dev/null)"
    echo "hermes-critic.sh: WARN hermes route failed (rc=$rc): ${hermes_err:-<no stderr>} — fail-open, fall back to gemini-cli or claude-only review and note it in the review summary." >&2
    exit 3
fi

# Parse + enforce fail-closed verdict. node is a himmel baseline dependency.
printf '%s' "$raw" | node -e '
let d = "";
process.stdin.on("data", c => d += c).on("end", () => {
    const m = d.match(/\{[\s\S]*\}/);
    if (!m) { console.error("hermes-critic.sh: no JSON object in critic response"); process.exit(3); }
    let j;
    try { j = JSON.parse(m[0]); }
    catch (e) { console.error("hermes-critic.sh: critic response is not valid JSON: " + e.message); process.exit(3); }
    for (const k of ["security_concerns", "logic_errors", "architectural_mismatches", "suggestions"])
        if (!Array.isArray(j[k])) j[k] = j[k] == null ? [] : [String(j[k])];
    // Fail-closed: findings beat the model self-assessment.
    if ((j.security_concerns.length + j.logic_errors.length) > 0) j.passed = false;
    if (typeof j.passed !== "boolean") j.passed = false;
    console.log(JSON.stringify(j, null, 2));
    process.exit(j.passed ? 0 : 1);
});
'
exit $?
