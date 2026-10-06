#!/usr/bin/env bash
# Tests for scripts/hooks/mcp-policy.sh (HIMMEL-4676): MCP call tracking plus
# the gating seam.
#
#   observe (shipped): the hook NEVER denies — unknown server, unlisted tool,
#     destructive tool, egress-denied server, malformed or ANSI input are all
#     allowed and audited with the class and the verdict it WOULD give.
#   enforce (test fixtures only): the same calls are denied.
#   audit: one line per call, no argument content, size cap with rotation.
#   latency: p95 per call under a budget.
#
# Usage: bash scripts/hooks/test-mcp-policy.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$SCRIPT_DIR/mcp-policy.sh"
REGISTRY="$REPO_ROOT/scripts/guardrails/mcp-policy.json"
MATRIX="$REPO_ROOT/scripts/guardrails/egress-matrix.json"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export MCP_POLICY_AUDIT_LOG="$TMP/audit.jsonl"
unset MCP_POLICY_REGISTRY MCP_POLICY_EGRESS_MATRIX

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# run_hook <stdin> — sets RC, ERR; never inherits a stale audit line.
run_hook() {
    : > "$MCP_POLICY_AUDIT_LOG"
    ERR=$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)
    RC=$?
    LAST=$(tail -n 1 "$MCP_POLICY_AUDIT_LOG" 2>/dev/null || true)
}
call() { printf '{"session_id":"s-test","tool_name":"%s","tool_input":{"q":"SECRET-ARG-%s"}}' "$1" "$$"; }
field() { printf '%s' "$LAST" | jq -r ".$1" 2>/dev/null; }

# expect <name> <rc> <class> <verdict>
expect() {
    local name="$1" rc="$2" class="$3" verdict="$4"
    if [ "$RC" = "$rc" ] && [ "$(field class)" = "$class" ] && [ "$(field verdict)" = "$verdict" ]; then
        ok "$name"
    else
        bad "$name (rc=$RC class=$(field class) verdict=$(field verdict) want rc=$rc class=$class verdict=$verdict; stderr=$ERR)"
    fi
}

[ -f "$HOOK" ] || { echo "FAIL hook missing: $HOOK"; exit 1; }

# --- 1. observe mode (the shipped registry) never denies ---------------------
run_hook "$(call mcp__nosuchserver__do_thing)"
expect "observe: unknown server allowed, would-deny" 0 unknown-server deny
run_hook "$(call mcp__qmd__drop_everything)"
expect "observe: unlisted tool on known server allowed, would-deny" 0 unlisted-tool deny
run_hook "$(call mcp__obsidian-vault__obsidian_delete_file)"
expect "observe: destructive tool allowed, would-deny" 0 destructive deny
run_hook "$(call mcp__obsidian-vault__obsidian_put_content)"
expect "observe: write tool allowed, would-allow" 0 write allow
run_hook '{"tool_name": "mcp__qmd__query", "tool_input": '
expect "observe: malformed JSON allowed, would-deny" 0 malformed deny
run_hook "$(printf '{"session_id":"s","tool_name":"mcp__qmd__\\u001b[31mquery"}')"
expect "observe: ANSI tool_name allowed, would-deny" 0 malformed deny
if printf '%s' "$LAST" | grep -q "$(printf '\033')"; then bad "audit line carries a raw ESC"; else ok "audit line strips ESC"; fi
run_hook '{"session_id":"s","tool_name":42}'
expect "observe: non-string tool_name allowed, would-deny" 0 malformed deny
run_hook '{"session_id":"s","tool_name":"mcp__qmd"}'
expect "observe: tool_name without a tool part allowed, would-deny" 0 malformed deny
run_hook ''
expect "observe: empty stdin allowed, would-deny" 0 malformed deny

# --- 2. every seeded read tool is allowed and classed read -------------------
seeded_fail=0
seeded_n=0
while IFS=$'\t' read -r srv tool; do
    seeded_n=$((seeded_n + 1))
    run_hook "$(call "mcp__${srv}__${tool}")"
    if [ "$RC" != 0 ] || [ "$(field class)" != read ] || [ "$(field verdict)" != allow ]; then
        seeded_fail=1
        bad "seeded read tool mcp__${srv}__${tool} (rc=$RC class=$(field class) verdict=$(field verdict))"
    fi
done < <(jq -r '.servers | to_entries[] | .key as $s | (.value.tools // {}) | to_entries[] | select(.value=="read") | [$s, .key] | @tsv' "$REGISTRY")
[ "$seeded_fail" = 0 ] && [ "$seeded_n" -gt 20 ] && ok "every seeded read tool allowed + classed read ($seeded_n)"
[ "$seeded_n" -gt 20 ] || bad "seeded read tools enumerated only $seeded_n"

# --- 3. audit line shape: fields present, no argument content ----------------
run_hook "$(call mcp__graphify__query_graph)"
if printf '%s' "$LAST" | jq -e '(.ts|type=="string") and .session=="s-test" and .server=="graphify" and .tool=="query_graph" and .class=="read" and .verdict=="allow" and .mode=="observe" and .egress=="local"' >/dev/null 2>&1; then
    ok "audit line carries ts/session/server/tool/class/verdict/mode/egress"
else
    bad "audit line shape: $LAST"
fi
if grep -q SECRET-ARG "$MCP_POLICY_AUDIT_LOG"; then bad "audit log carries argument content"; else ok "audit log carries no argument content"; fi
if [ "$(wc -l < "$MCP_POLICY_AUDIT_LOG" | tr -d ' ')" = 1 ]; then ok "exactly one audit line per call"; else bad "audit lines per call: $(wc -l < "$MCP_POLICY_AUDIT_LOG")"; fi

# --- 4. shipped registry ships nothing in enforce ----------------------------
if jq -e '.mode=="observe" and ([.servers[] | select(has("mode") and .mode!="observe")] | length == 0)' "$REGISTRY" >/dev/null; then
    ok "shipped registry: observe at top level and on every server"
else
    bad "shipped registry has an enforce mode"
fi
if jq -e '[.servers[] | (.tools // {})[] | select(. != "read" and . != "write" and . != "destructive")] | length == 0' "$REGISTRY" >/dev/null; then
    ok "every tool class is read|write|destructive"
else
    bad "registry has an unknown tool class"
fi
bad_prov=$(jq -r --slurpfile m "$MATRIX" '[.servers | to_entries[] | select(.value.provider != null) | select(($m[0].providers | has(.value.provider)) | not) | .key] | join(",")' "$REGISTRY")
if [ -z "$bad_prov" ]; then ok "every named egress provider exists in egress-matrix.json"; else bad "unknown egress provider on: $bad_prov"; fi

# --- 5. enforce mode (fixture registry) denies -------------------------------
jq '.mode="enforce"
    | .servers["fx-gemini"]={"verdict":"allow","egress":"off-box","provider":"google-gemini","tools":{"ask":"read"}}
    | .servers["fx-denied"]={"verdict":"deny","egress":"local","tools":{"ask":"read"}}
    | .servers["obsidian-vault"].allow_destructive=["obsidian_delete_file"]' "$REGISTRY" > "$TMP/enforce.json"
export MCP_POLICY_REGISTRY="$TMP/enforce.json"
run_hook "$(call mcp__nosuchserver__do_thing)"
expect "enforce: unknown server denied" 2 unknown-server deny
case "$ERR" in *mcp-policy.json*servers*nosuchserver*|*nosuchserver*mcp-policy.json*) ok "enforce: deny names the registry entry to add" ;; *) bad "enforce: deny message lacks the registry entry: $ERR" ;; esac
run_hook "$(call mcp__qmd__drop_everything)"
expect "enforce: unlisted tool denied" 2 unlisted-tool deny
run_hook "$(call mcp__claude_ai_Gmail__send_message)"
expect "enforce: destructive tool denied" 2 destructive deny
run_hook "$(call mcp__obsidian-vault__obsidian_delete_file)"
expect "enforce: destructive tool in allow_destructive allowed" 0 destructive allow
run_hook '{"tool_name": "mcp__qmd__query", "tool_input": '
expect "enforce: malformed JSON denied" 2 malformed deny
run_hook "$(printf '{"session_id":"s","tool_name":"mcp__qmd__\\u001b[31mquery"}')"
expect "enforce: ANSI tool_name denied" 2 malformed deny
run_hook "$(call mcp__fx-gemini__ask)"
expect "enforce: off-box server on an egress-matrix wildcard deny denied" 2 read deny
run_hook "$(call mcp__fx-denied__ask)"
expect "enforce: deny-verdict server denied" 2 read deny
run_hook "$(call mcp__qmd__query)"
expect "enforce: seeded read tool still allowed" 0 read allow

# per-server enforce under a global observe
jq '.servers["qmd"].mode="enforce"' "$REGISTRY" > "$TMP/perserver.json"
export MCP_POLICY_REGISTRY="$TMP/perserver.json"
run_hook "$(call mcp__qmd__drop_everything)"
expect "per-server enforce: that server's unlisted tool denied" 2 unlisted-tool deny
run_hook "$(call mcp__nosuchserver__do_thing)"
expect "per-server enforce: unknown server still observe-allowed" 0 unknown-server deny
run_hook "$(call mcp__obsidian-vault__obsidian_delete_file)"
expect "per-server enforce: other server still observe-allowed" 0 destructive deny

# --- 6. broken config never denies -------------------------------------------
export MCP_POLICY_REGISTRY="$TMP/absent.json"
run_hook "$(call mcp__qmd__query)"
if [ "$RC" = 0 ]; then ok "missing registry: allowed"; else bad "missing registry: rc=$RC"; fi
printf '{not json' > "$TMP/broken.json"
export MCP_POLICY_REGISTRY="$TMP/broken.json"
run_hook "$(call mcp__qmd__query)"
if [ "$RC" = 0 ]; then ok "malformed registry: allowed"; else bad "malformed registry: rc=$RC"; fi
unset MCP_POLICY_REGISTRY

NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for b in bash cat date mv mkdir wc tr head tail dirname; do
    p=$(command -v "$b") && ln -sf "$p" "$NOJQ/$b"
done
: > "$MCP_POLICY_AUDIT_LOG"
printf '%s' "$(call mcp__nosuchserver__x)" | PATH="$NOJQ" "$NOJQ/bash" "$HOOK" >/dev/null 2>&1
RC=$?
if [ "$RC" = 0 ]; then ok "jq missing: allowed"; else bad "jq missing: rc=$RC"; fi

export MCP_POLICY_AUDIT_LOG="$TMP/ro/sub/audit.jsonl"
mkdir -p "$TMP/ro" && chmod 500 "$TMP/ro"
printf '%s' "$(call mcp__qmd__query)" | bash "$HOOK" >/dev/null 2>&1
RC=$?
chmod 700 "$TMP/ro"
if [ "$RC" = 0 ]; then ok "unwritable audit dir: allowed"; else bad "unwritable audit dir: rc=$RC"; fi
export MCP_POLICY_AUDIT_LOG="$TMP/audit.jsonl"

# --- 7. size cap rotates -----------------------------------------------------
jq '.audit.max_bytes=400' "$REGISTRY" > "$TMP/small.json"
export MCP_POLICY_REGISTRY="$TMP/small.json"
: > "$MCP_POLICY_AUDIT_LOG"
rm -f "$MCP_POLICY_AUDIT_LOG.1"
for _ in 1 2 3 4 5 6 7 8; do printf '%s' "$(call mcp__qmd__query)" | bash "$HOOK" >/dev/null 2>&1; done
size=$(wc -c < "$MCP_POLICY_AUDIT_LOG" | tr -d ' ')
if [ -f "$MCP_POLICY_AUDIT_LOG.1" ] && [ "$size" -le 800 ]; then ok "audit log rotates past max_bytes (live $size bytes)"; else bad "no rotation (live $size bytes, .1 present: $([ -f "$MCP_POLICY_AUDIT_LOG.1" ] && echo y || echo n))"; fi
unset MCP_POLICY_REGISTRY

# --- 8. registration in both harnesses; Atlassian redirect unchanged ---------
if jq -e '[.hooks.PreToolUse[] | select(.matcher=="mcp__.*") | .hooks[].command | select(test("scripts/hooks/mcp-policy\\.sh"))] | length == 1' "$REPO_ROOT/.claude/settings.json" >/dev/null; then
    ok ".claude/settings.json registers mcp-policy.sh on mcp__.*"
else
    bad ".claude/settings.json lacks the mcp__.* registration"
fi
# Codex keeps its PreToolUse matchers disjoint (test-codex-hook-parity.sh), so
# there the tracker and the Atlassian redirect share ONE mcp__.* chain:
# mcp-policy.sh first, so a redirect deny still leaves an audit line.
# ponytail: in Codex only, block-backend-tier's fail-closed branches (jq
# missing, unparseable hook input) now also cover non-Atlassian MCP calls;
# upgrade path = a pre-jq tool_name prefix check in block-backend-tier so a
# non-registered prefix exits allow before those branches (8b pins the
# well-formed case).
if jq -e '[.hooks.PreToolUse[] | select(.matcher=="mcp__.*") | .hooks[].command | select(test("--sandbox mcp-policy\\.sh\\+block-backend-tier\\.sh\\z"))] | length == 1' "$REPO_ROOT/.codex/hooks.json" >/dev/null; then
    ok ".codex/hooks.json chains mcp-policy.sh then block-backend-tier.sh on mcp__.*"
else
    bad ".codex/hooks.json lacks the mcp__.* chain (mcp-policy.sh+block-backend-tier.sh)"
fi
if jq -e '[.hooks.PreToolUse[] | select(.matcher=="mcp__plugin_atlassian_atlassian__.*") | .hooks[].command | select(test("block-backend-tier\\.sh"))] | length == 1' "$REPO_ROOT/.claude/settings.json" >/dev/null; then
    ok ".claude/settings.json keeps the Atlassian redirect"
else
    bad ".claude/settings.json lost the Atlassian redirect"
fi

# --- 8b. the real Codex chain allows well-formed non-Atlassian MCP calls -----
# Runs .codex/run-hook.sh exactly as .codex/hooks.json wires it, so the
# adapter, the tracker and block-backend-tier all run.
CHAIN_CMD="$REPO_ROOT/.codex/run-hook.sh"
CHAIN_ARG="mcp-policy.sh+block-backend-tier.sh"
for t in mcp__qmd__query mcp__nosuch__thing mcp__claude_ai_Gmail__send_message mcp__claude_ai_Atlassian_MCP__executeRead; do
    : > "$MCP_POLICY_AUDIT_LOG"
    out=$(call "$t" | bash "$CHAIN_CMD" --sandbox "$CHAIN_ARG" 2>&1)
    rc=$?
    lines=$(wc -l < "$MCP_POLICY_AUDIT_LOG" | tr -d ' ')
    if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -qi 'deny' && [ "$lines" = 1 ]; then
        ok "codex chain allows $t and audits it"
    else
        bad "codex chain on $t: rc=$rc audit-lines=$lines out=$(printf '%s' "$out" | head -c 200)"
    fi
done

# --- 9. latency budget -------------------------------------------------------
# Budget: p95 under MCP_POLICY_P95_BUDGET_MS (default 300 ms; idle is ~10x
# under it, see the PR body for the idle and loaded measurements). The chain
# timeout around this hook is 15 s.
budget="${MCP_POLICY_P95_BUDGET_MS:-300}"
input=$(call mcp__obsidian-vault__obsidian_get_file_contents)
: > "$TMP/lat"
for _ in $(seq 1 40); do
    s=$(date +%s%N)
    printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1
    e=$(date +%s%N)
    echo $(( (e - s) / 1000000 )) >> "$TMP/lat"
done
p95=$(sort -n "$TMP/lat" | awk '{a[NR]=$1} END{i=int(NR*0.95); if (i<1) i=1; print a[i]}')
if [ "$p95" -lt "$budget" ]; then ok "latency p95 ${p95} ms < ${budget} ms"; else bad "latency p95 ${p95} ms >= ${budget} ms"; fi

# The whole Codex chain (adapter + tracker + block-backend-tier) on a normal
# call; its 60 s timeout is a ceiling, not the expected cost.
chain_budget="${MCP_POLICY_CHAIN_P95_BUDGET_MS:-1000}"
: > "$TMP/clat"
for _ in $(seq 1 20); do
    s=$(date +%s%N)
    printf '%s' "$input" | bash "$CHAIN_CMD" --sandbox "$CHAIN_ARG" >/dev/null 2>&1
    e=$(date +%s%N)
    echo $(( (e - s) / 1000000 )) >> "$TMP/clat"
done
cp95=$(sort -n "$TMP/clat" | awk '{a[NR]=$1} END{i=int(NR*0.95); if (i<1) i=1; print a[i]}')
if [ "$cp95" -lt "$chain_budget" ]; then ok "codex chain latency p95 ${cp95} ms < ${chain_budget} ms"; else bad "codex chain latency p95 ${cp95} ms >= ${chain_budget} ms"; fi

echo
echo "mcp-policy: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
