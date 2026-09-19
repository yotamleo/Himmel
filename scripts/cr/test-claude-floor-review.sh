#!/usr/bin/env bash
# test-claude-floor-review.sh — HIMMEL-3107: the context-free CR floor reviewer.
# A fake claude (HIMMEL_CLAUDE_BIN) records its argv, cwd and stdin, so the
# suite pins that the reviewer invocation carries NO session context, that it
# refuses to spend when the floor could not unlock, and that it stamps the
# provenance artifact + ledger rows the gate reads.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/cr/claude-floor-review.sh"
AGENT_MD="$REPO/marketplace/plugins/pr-review-toolkit-himmel/agents/code-reviewer.md"
PASS=0; FAIL=0
W="$(mktemp -d -t claude-floor-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
ok() { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2' got '$3'"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
hasnt() { if grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1: /$2/ found in $3"; else ok "$1"; fi; }

# Bank preflight + registry stubs (same shape as scripts/lib/test-claude-headless.sh).
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$(date +%s)" > "$W/bank.json"
export CADENCE_BANK_CACHE="$W/bank.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$W/no-fleet.sh"; chmod +x "$W/no-fleet.sh"
export FLEET_PS_CMD="$W/no-fleet.sh" HIMMEL_REGISTRY_DIR="$W/registry"

# The fake claude: records argv / cwd / stdin / whether cwd has a .git, then
# writes FAKE_OUT (verbatim) to .cr-floor-review.json and prints FAKE_ENV.
FAKE="$W/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
pwd > "$REC/cwd"
cat > "$REC/stdin"
[ -e .git ] && echo yes > "$REC/has-git" || echo no > "$REC/has-git"
prev=""; for a in "$@"; do [ "$prev" = "--system-prompt-file" ] && cp "$a" "$REC/system.md"; prev="$a"; done
[ -z "${FAKE_OUT:-}" ] || printf '%s' "$FAKE_OUT" > .cr-floor-review.json
printf '%s\n' "${FAKE_ENV:-{\"is_error\":false,\"session_id\":\"fake-sess-1\",\"permission_denials\":[],\"num_turns\":3}}"
EOF
chmod +x "$FAKE"
export HIMMEL_CLAUDE_BIN="$FAKE"

# mk_repo — main + one commit on feat/himmel-9-x; sets R and HEAD_SHA.
mk_repo() {
    R="$W/repo.$1"; rm -rf "$R"; mkdir -p "$R"
    ( cd "$R" && git init -q -b main . && git config user.email t@t.t && git config user.name t &&
      echo hi > f.txt && git add f.txt && git commit -qm base &&
      git checkout -qb feat/himmel-9-x && echo more >> f.txt && git commit -qam work ) >/dev/null 2>&1
    HEAD_SHA=$(git -C "$R" rev-parse HEAD)
    export CR_LEDGER="$R/.git/cr-critic-scores.jsonl"; : > "$CR_LEDGER"
    REC="$W/rec.$1"; rm -rf "$REC"; mkdir -p "$REC"; export REC
}
row() { printf '{"kind":"avail","head":"%s","model":"%s","status":"%s","reason":"%s"}\n' "$HEAD_SHA" "$1" "$2" "${3:-}" >> "$CR_LEDGER"; }
run_sut() { RC=0; ( cd "$R" && bash "$SUT" --branch feat/himmel-9-x --base main ) > "$W/out" 2>&1 || RC=$?; }

# 1. Eligible (CodeRabbit rate-limited + codex quota-5h): reviewed, recorded.
mk_repo 1; row coderabbit unavailable rate-limit; row codex unavailable quota-5h
export FAKE_OUT='{"findings":[{"severity":"imp","file":"f.txt","line":2,"text":"more is vague"}]}'
run_sut
check "1 eligible run exits 0" 0 "$RC"
# -- no session context reaches the reviewer --
check "1 reviewer cwd has no .git (a snapshot, not the worktree)" no "$(cat "$REC/has-git" 2>/dev/null)"
case "$(cat "$REC/cwd" 2>/dev/null)" in "$R"|"$R"/*) bad "1 reviewer cwd must not be inside the repo" ;; *) ok "1 reviewer cwd is outside the repo" ;; esac
has "1 --safe-mode (no CLAUDE.md/memory/skills/plugins/hooks)" "--safe-mode" "$REC/argv"
has "1 --strict-mcp-config (no MCP servers)" "--strict-mcp-config" "$REC/argv"
has "1 --no-session-persistence" "--no-session-persistence" "$REC/argv"
has "1 tools restricted to Read,Grep,Glob,Write" "Read,Grep,Glob,Write" "$REC/argv"
has "1 explicit acceptEdits permission mode" "acceptEdits" "$REC/argv"
has "1 --output-format json" "json" "$REC/argv"
hasnt "1 never resumes/continues a session" '^(--resume|-r|--continue|-c|--session-id|--fork-session)$' "$REC/argv"
hasnt "1 never bypassPermissions" 'bypassPermissions' "$REC/argv"
check "1 model from the agent frontmatter" opus "$(grep -A1 -x -- '--model' "$REC/argv" | tail -1)"
# stdin = the fixed header + the diff, nothing else
( cd "$R" && git diff --no-color --no-ext-diff main...HEAD ) > "$W/expect.diff"
tail -n +3 "$REC/stdin" > "$W/stdin.diff"
if cmp -s "$W/expect.diff" "$W/stdin.diff"; then ok "1 prompt body is exactly the diff"; else bad "1 prompt body is exactly the diff"; fi
check "1 prompt header names only the diff range" "Review this diff (" "$(head -1 "$REC/stdin" | cut -c1-18)"
# system prompt = the plugin's reviewer body verbatim, frontmatter stripped
awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$AGENT_MD" > "$W/agent-body.md"
if head -c "$(wc -c < "$W/agent-body.md")" "$REC/system.md" | cmp -s - "$W/agent-body.md"; then
    ok "1 system prompt starts with the reviewer agent body verbatim"; else bad "1 system prompt starts with the reviewer agent body verbatim"; fi
hasnt "1 system prompt carries no agent frontmatter" '^name: code-reviewer' "$REC/system.md"
# -- provenance + ledger --
ART="$R/.git/cr-floor/$HEAD_SHA.json"
check "1 artifact head" "$HEAD_SHA" "$(jq -r .head "$ART" 2>/dev/null)"
check "1 artifact diff hash = the gate's recompute" "$(git -C "$R" hash-object --stdin < "$W/expect.diff")" "$(jq -r .diff_hash "$ART" 2>/dev/null)"
check "1 artifact session id from the envelope" fake-sess-1 "$(jq -r .session_id "$ART" 2>/dev/null)"
check "1 artifact same_model/context_free" "true true" "$(jq -r '"\(.same_model) \(.context_free)"' "$ART" 2>/dev/null)"
check "1 artifact unlocked_by" "coderabbit(reason=rate-limit) codex(reason=quota-5h)" "$(jq -r '.unlocked_by|join(" ")' "$ART" 2>/dev/null)"
check "1 ledger floor ok row" 1 "$(jq -c 'select(.kind=="avail" and .model=="claude-floor" and .status=="ok")' "$CR_LEDGER" | wc -l | tr -d ' ')"
has "1 ledger row records same-model + context-free + unlocking lanes" "same-model context-free session=fake-sess-1 unlocked_by=coderabbit(reason=rate-limit) codex(reason=quota-5h)" "$CR_LEDGER"
check "1 finding recorded unadjudicated" '"claude-floor-1" "imp" ""' "$(jq -r 'select(.kind=="finding") | "\"\(.finding_id)\" \"\(.severity)\" \"\(.verdict)\""' "$CR_LEDGER")"
has "1 output says NOT cross-model" "NOT COVERED: cross-model review" "$W/out"

# 2. RED control: codex auth (401) — refuses, nothing spent.
mk_repo 2; row coderabbit unavailable rate-limit; row codex unavailable auth
run_sut
check "2 auth-faulted lane -> exit 3" 3 "$RC"
check "2 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"
has "2 names the lane" "codex(status=unavailable,reason=auth)" "$W/out"

# 3. vacuous is coderabbit-only.
mk_repo 3; row codex unavailable vacuous
run_sut
check "3 codex reason=vacuous -> exit 3" 3 "$RC"

# 4. A non-Claude critic already responded: no floor needed.
mk_repo 4; row codex ok
run_sut
check "4 cross-model already met -> exit 3" 3 "$RC"
check "4 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 5. Silence with the real (non-empty) panel is not exhaustion.
mk_repo 5
run_sut
check "5 no rows + non-empty panel -> exit 3" 3 "$RC"

# 6. is_error=true -> recorded failure, no provenance.
mk_repo 6; row codex unavailable quota
FAKE_ENV='{"is_error":true,"session_id":"fake-sess-6"}' run_sut
check "6 is_error -> exit 1" 1 "$RC"
check "6 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"
check "6 recorded claude-floor unavailable" 1 "$(jq -c 'select(.model=="claude-floor" and .status=="unavailable")' "$CR_LEDGER" | wc -l | tr -d ' ')"

# 7. malformed reviewer output -> recorded failure (malformed-output).
mk_repo 7; row codex unavailable quota
FAKE_OUT='here are my findings: none' run_sut
check "7 malformed output -> exit 1" 1 "$RC"
check "7 reason malformed-output" malformed-output "$(jq -r 'select(.model=="claude-floor") | .reason' "$CR_LEDGER")"
check "7 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"

echo "claude-floor-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
