#!/usr/bin/env bash
# Tests for the composed HIMMEL-1513 lane-routing and HIMMEL-920 bank policies.
# Hermetic: lane availability, usage caches, and override logs use fixtures.
#
# Usage: bash scripts/hooks/test-guard-implementor-dispatch.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits as soon as it matches, the producer takes
# SIGPIPE writing the remainder, and a successful match reports failure on
# sufficiently large input. A here-string exposes grep's verdict. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$SCRIPT_DIR/guard-implementor-dispatch.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-impl-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

REG_CLAUDEX="$TMP/claudex.json"
REG_GLM="$TMP/glm.json"
REG_NONE="$TMP/none.json"
REG_BOTH="$TMP/both.json"
printf '%s\n' '{"lanes":[{"id":"claudex","class":"impl","probe":{"kind":"always"}}]}' > "$REG_CLAUDEX"
printf '%s\n' '{"lanes":[{"id":"glm","class":"impl","probe":{"kind":"always"}}]}' > "$REG_GLM"
printf '%s\n' '{"lanes":[{"id":"sonnet","class":"claude-tier","probe":{"kind":"always"}}]}' > "$REG_NONE"
printf '%s\n' '{"lanes":[{"id":"claudex","class":"impl","probe":{"kind":"always"}},{"id":"glm","class":"impl","probe":{"kind":"always"}}]}' > "$REG_BOTH"

# HIMMEL-1513 runnability fixtures. A fake project root carrying a real,
# working lane resolver (copied, not symlinked — Windows worktrees can't rely
# on symlink privileges) but a scripts/telegram/ that is missing the claudex
# dispatcher and only has the glm one. Used to prove the guard checks
# runnability (bun + dispatcher-file-on-disk), not just registry presence.
FAKE_REPO_NO_CLAUDEX="$TMP/fake-repo-no-claudex"
mkdir -p "$FAKE_REPO_NO_CLAUDEX/scripts/lanes" "$FAKE_REPO_NO_CLAUDEX/scripts/telegram"
cp "$REPO_ROOT/scripts/lanes/resolve.mjs" "$FAKE_REPO_NO_CLAUDEX/scripts/lanes/resolve.mjs"
cp "$REPO_ROOT/scripts/lanes/probe.mjs" "$FAKE_REPO_NO_CLAUDEX/scripts/lanes/probe.mjs"
: > "$FAKE_REPO_NO_CLAUDEX/scripts/telegram/spawn-glm.ts"

# PATH stub with bun's directory removed (mandatory negative test — a live
# credential but no Bun runtime). Stubbing PATH rather than mutating the real
# environment; jq/node/bash stay reachable since only bun's dir is dropped.
if BUN_PATH=$(command -v bun 2>/dev/null); then
    BUN_DIR=$(dirname "$BUN_PATH")
else
    BUN_DIR=""
fi
# grep -x anchors the pattern to the WHOLE line, so an empty BUN_DIR (bun
# already absent from this machine's PATH) matches nothing — no PATH entry is
# ever the literal empty string — and every line survives -v unchanged. That
# is exactly the desired no-op: PATH already lacks bun in that case, so
# nothing needs stripping and jq/node/bash stay reachable. (A plain `grep -v`
# without `-x` would collapse the whole PATH here, since an empty pattern is
# a substring of every line — that is NOT what this uses.)
STUB_PATH_NO_BUN=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$BUN_DIR" | tr '\n' ':')

# Resolve bash ONCE from the suite's own unmodified PATH, before any test
# hands `env` a narrowed one (HIMMEL-1567). run_hook invokes this absolute
# path so a PATH override decides what the HOOK sees, never whether the hook
# can be started at all.
BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi

# HIMMEL-1567: the suite is not hermetic to whether the real `bun` binary is
# on the runner's PATH -- it isn't on the CI (ubuntu-latest) box, so every
# assertion below that expects the guard to treat claudex/glm as runnable
# silently degraded to the "bun is not on PATH — skipping it" branch and
# never reached the refusal it was asserting. Force runnability by default: a
# stub `bun` (the guard only ever does `command -v bun`, never executes it)
# on a directory prepended to PATH. The one test that must see a REAL absence
# of bun (RC31 below) overrides PATH wholesale via run_hook's env seam, which
# wins over this default.
STUB_BUN_DIR="$TMP/stub-bun-bin"
mkdir -p "$STUB_BUN_DIR"
cat > "$STUB_BUN_DIR/bun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_BUN_DIR/bun"

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

payload() {
    jq -nc --arg st "$1" --arg m "$2" --arg d "$3" --arg p "$4" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:$d,prompt:$p,model:$m}}'
}

payload_no_model() {
    jq -nc --arg st "$1" --arg d "$2" --arg p "$3" \
        '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:$st,description:$d,prompt:$p}}'
}

large_payload() {
    jq -nc '{tool_name:"Agent",session_id:"sess-test",tool_input:{subagent_type:"general-purpose",description:"large classifier fixture",prompt:("implement the fix "+("padding "*20000)),model:"sonnet"}}'
}

mkcache() {
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"}}' "$2" "$(( $(date +%s) + 3600 ))" > "$1"
}

run_hook() {
    local name="$1" registry="$2" json="$3"; shift 3
    # PATH default (stub bun prepended) comes before "$@" so a caller-supplied
    # PATH override (e.g. the bun-missing negative test) wins -- env applies
    # repeated assignments in order, last one takes effect.
    # Invoke bash by ABSOLUTE path (HIMMEL-1567): `env` resolves the command
    # name using the PATH it was just handed, so a caller-supplied override
    # decides whether `bash` is findable at all. STUB_PATH_NO_BUN strips bun's
    # WHOLE directory, and on a runner where bash lives in that same directory
    # env would fail 127 before the hook ever ran -- RC31 would then be a
    # platform-dependent false RED that says nothing about the guard. BASH_ABS
    # is resolved once, above, from the suite's own unmodified PATH.
    printf '%s' "$json" | env CLAUDE_PROJECT_DIR="$REPO_ROOT" LANES_REGISTRY="$registry" PATH="$STUB_BUN_DIR:$PATH" "$@" "$BASH_ABS" "$HOOK" \
        >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

echo "=== lane-routing policy ==="

RC1=$(run_hook impl-claudex "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the guard and commit the changes.')")
assert_rc "implementation + claudex available refuses" 2 "$RC1"
ERR1=$(cat "$TMP/err-impl-claudex")
assert_contains "claudex refusal names dispatcher" "bun scripts/telegram/spawn-claudex.ts '<prompt>' --name <slug> --timeout-mins <n> --effort high" "$ERR1"
assert_rc "claudex refusal is one line" 1 "$(wc -l < "$TMP/err-impl-claudex" | tr -d ' ')"

RC2=$(run_hook impl-glm "$REG_GLM" "$(payload claude sonnet 'Fix the failing shell test' 'Land the fix.')")
assert_rc "implementation + glm available refuses" 2 "$RC2"
assert_contains "glm refusal names dispatcher" "bun scripts/telegram/spawn-glm.ts '<prompt>' --name <slug> --timeout-mins <n>" "$(cat "$TMP/err-impl-glm")"

RC3=$(run_hook research "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Research HIMMEL-1513' 'Investigate how to fix the routing drift; report findings only, read-only.')")
assert_rc "research-shaped dispatch allowed" 0 "$RC3"
assert_empty "research-shaped dispatch silent" "$(combined_output research)"

RC4=$(run_hook research-then-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Investigate and fix HIMMEL-1513' 'Research the cause and then implement the fix.')")
assert_rc "research followed by implementation refuses" 2 "$RC4"

RC4A=$(run_hook resolve-review-findings "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Resolve review findings' 'Resolve the review findings.')")
assert_rc "resolve review findings refuses" 2 "$RC4A"

RC4B=$(run_hook review-address-findings "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Review and address findings' 'Review and address findings.')")
assert_rc "review and address findings refuses" 2 "$RC4B"

RC4C=$(run_hook review-then-resolve "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Review then resolve feedback' 'Review, then resolve feedback.')")
assert_rc "review then resolve feedback refuses" 2 "$RC4C"

RC4D=$(run_hook pure-research "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Research lane routing' 'Research how the lane router picks a model.')")
assert_rc "pure lane-router research remains allowed" 0 "$RC4D"
assert_empty "pure lane-router research remains silent" "$(combined_output pure-research)"

RC5=$(run_hook worktree "$REG_CLAUDEX" "$(payload general-purpose sonnet 'HIMMEL-1513 worker' 'C:/repo/.claude/worktrees/fix-lane; Platforms tested: windows')")
assert_rc "worktree/trailer-shaped dispatch refuses" 2 "$RC5"

RC6=$(run_hook ticket-only "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Summarize HIMMEL-1513' 'Summarize HIMMEL-1513 for the handover.')")
assert_rc "bare ticket ID does not imply implementation" 0 "$RC6"
assert_empty "bare ticket summary silent" "$(combined_output ticket-only)"

RC7=$(run_hook large "$REG_CLAUDEX" "$(large_payload)")
assert_rc "large early-match prompt still classifies" 2 "$RC7"

CACHE_LOW="$TMP/cache-low.json"; mkcache "$CACHE_LOW" 20
RC8=$(run_hook unavailable-low "$REG_NONE" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "lane unavailable + low bank allows" 0 "$RC8"
assert_empty "lane unavailable + low bank silent" "$(combined_output unavailable-low)"

RC9=$(run_hook explore "$REG_CLAUDEX" "$(payload Explore sonnet 'Find implementation sites' 'Explore where to implement the fix; do not edit.')")
assert_rc "Explore agent allowed" 0 "$RC9"
RC10=$(run_hook lane-wrapper "$REG_CLAUDEX" "$(payload himmel-ops:claudex-subagent sonnet 'Implement HIMMEL-1513' 'Implement and commit the guard.')")
assert_rc "claudex lane wrapper allowed" 0 "$RC10"

# Plan remains exempt from lane routing, while the independent bank policy can
# still act. At low utilization, a Plan implementation prompt is allowed.
RC11=$(run_hook plan-low "$REG_CLAUDEX" "$(payload Plan sonnet 'Implementation worker' 'Write the implementation.')" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "Plan is lane-exempt at low bank" 0 "$RC11"
assert_empty "Plan lane exemption is silent at low bank" "$(combined_output plan-low)"

echo ""
echo "=== overrides and fail-open seams ==="

OVERRIDE_LOG="$TMP/override.jsonl"
RC12=$(run_hook override "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write and commit the fix.')" IMPL_GUARD_OK=1 IMPL_GUARD_LOG="$OVERRIDE_LOG")
assert_rc "override allows" 0 "$RC12"
assert_contains "override warns" "explicit session override" "$(cat "$TMP/err-override")"
assert_contains "override audit log records env" '"override":"IMPL_GUARD_OK"' "$(cat "$OVERRIDE_LOG" 2>/dev/null || true)"
assert_contains "override audit log records model" '"model":"sonnet"' "$(cat "$OVERRIDE_LOG" 2>/dev/null || true)"

DISABLE_LOG="$TMP/disable.jsonl"
RC13=$(run_hook disable "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write and commit the fix.')" IMPL_GUARD_DISABLE=1 IMPL_GUARD_LOG="$DISABLE_LOG")
assert_rc "kill switch allows" 0 "$RC13"
assert_contains "kill switch audit log records env" '"override":"IMPL_GUARD_DISABLE"' "$(cat "$DISABLE_LOG" 2>/dev/null || true)"

RC14=$(run_hook malformed "$REG_CLAUDEX" 'not-json{{{')
assert_rc "malformed input allows" 0 "$RC14"

MISSING_ROOT="$TMP/no-repo"
mkdir -p "$MISSING_ROOT"
printf '%s' "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code.')" \
    | env CLAUDE_PROJECT_DIR="$MISSING_ROOT" LANES_REGISTRY="$REG_CLAUDEX" IMPL_GUARD_CACHE_PATH="$CACHE_LOW" bash "$HOOK" \
        >"$TMP/out-missing" 2>"$TMP/err-missing"
RC15=$?
assert_rc "missing resolver allows when bank cannot be checked" 0 "$RC15"
assert_contains "missing resolver reports lane fail-open" "lane resolver missing" "$(cat "$TMP/err-missing")"

BASH_ABS=$(command -v bash)
EMPTY_DIR="$TMP/empty-path"
mkdir -p "$EMPTY_DIR"
printf '%s' "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code.')" \
    | env PATH="$EMPTY_DIR" "$BASH_ABS" "$HOOK" >"$TMP/out-no-jq" 2>"$TMP/err-no-jq"
RC16=$?
assert_rc "missing jq allows" 0 "$RC16"
assert_contains "missing jq reports fail-open" "jq not on PATH" "$(cat "$TMP/err-no-jq")"

echo ""
echo "=== bank-aware policy when no lane is available ==="

CACHE_HARD="$TMP/cache-hard.json"; mkcache "$CACHE_HARD" 85
RC17=$(run_hook bank-hard "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "no lane + live HARD bank refuses" 2 "$RC17"
assert_contains "bank refusal keeps HIMMEL-920 message" "5-hour bank at 85%" "$(cat "$TMP/err-bank-hard")"
assert_contains "bank refusal names cheaper-lane choices" "himmel-ops:glm-subagent" "$(cat "$TMP/err-bank-hard")"

CACHE_WARN="$TMP/cache-warn.json"; mkcache "$CACHE_WARN" 70
RC18=$(run_hook bank-warn "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_WARN")
assert_rc "WARN bank allows" 0 "$RC18"
assert_contains "WARN bank emits visible allow decision" '"permissionDecision":"allow"' "$(cat "$TMP/out-bank-warn")"
assert_contains "WARN bank emits permissionDecisionReason" "permissionDecisionReason" "$(cat "$TMP/out-bank-warn")"

RC19=$(run_hook bank-low "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "low bank allows" 0 "$RC19"
assert_empty "low bank silent" "$(combined_output bank-low)"

RC20=$(run_hook bank-missing "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$TMP/does-not-exist.json")
assert_rc "missing cache allows" 0 "$RC20"
assert_contains "missing cache warns" "cache not found" "$(cat "$TMP/err-bank-missing")"

CACHE_STALE="$TMP/cache-stale.json"; mkcache "$CACHE_STALE" 85
touch -d "1 hour ago" "$CACHE_STALE" 2>/dev/null \
    || touch -t "$(date -v -1H +%Y%m%d%H%M.%S 2>/dev/null)" "$CACHE_STALE" 2>/dev/null \
    || true
RC21=$(run_hook bank-stale "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_STALE")
assert_rc "stale cache allows" 0 "$RC21"
assert_contains "stale cache warns" "stale" "$(cat "$TMP/err-bank-stale")"

CACHE_UNKNOWN="$TMP/cache-unknown.json"; mkcache "$CACHE_UNKNOWN" 1783836000
RC22=$(run_hook bank-unknown "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_UNKNOWN")
assert_rc "unusable utilization allows" 0 "$RC22"
assert_contains "unusable utilization warns" "unusable" "$(cat "$TMP/err-bank-unknown")"

CACHE_EXPIRED="$TMP/cache-expired.json"
printf '{"five_hour":{"utilization":85,"resets_at":"%s"}}' "$(( $(date +%s) - 100 ))" > "$CACHE_EXPIRED"
RC23=$(run_hook bank-expired "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_EXPIRED")
assert_rc "expired five_hour window allows" 0 "$RC23"
assert_contains "expired five_hour window warns" "window expired" "$(cat "$TMP/err-bank-expired")"

CACHE_NO_RESET="$TMP/cache-no-reset.json"
printf '%s' '{"five_hour":{"utilization":85}}' > "$CACHE_NO_RESET"
RC24=$(run_hook bank-no-reset "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_NO_RESET")
assert_rc "HARD without resets_at downgrades to allow" 0 "$RC24"
assert_contains "missing resets_at downgrade is visible allow" '"permissionDecision":"allow"' "$(cat "$TMP/out-bank-no-reset")"
assert_contains "missing resets_at downgrade carries reason" "permissionDecisionReason" "$(cat "$TMP/out-bank-no-reset")"

CACHE_FLOAT="$TMP/cache-float.json"; mkcache "$CACHE_FLOAT" 84.5
RC25=$(run_hook bank-float "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_FLOAT")
assert_rc "float utilization compares safely at HARD" 2 "$RC25"

RC26=$(run_hook bank-absent-model "$REG_NONE" "$(payload_no_model general-purpose 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "absent model remains HARD-eligible" 2 "$RC26"
assert_contains "absent-model bank refusal names shape" "general-purpose/<no-model>" "$(cat "$TMP/err-bank-absent-model")"

RC27=$(run_hook bank-noneligible "$REG_NONE" "$(payload custom-worker sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "non-allow-listed worker warns, never HARD-refuses" 0 "$RC27"
assert_contains "non-allow-listed HARD utilization gets advisory" '"permissionDecision":"allow"' "$(cat "$TMP/out-bank-noneligible")"

RC28=$(run_hook plan-hard "$REG_CLAUDEX" "$(payload Plan sonnet 'Implementation worker' 'Write the implementation.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "Plan lane exemption still retains bank HARD guard" 2 "$RC28"
assert_contains "Plan bank refusal names Plan shape" "Plan/sonnet" "$(cat "$TMP/err-plan-hard")"

RC29=$(run_hook haiku "$REG_CLAUDEX" "$(payload general-purpose HaIkU 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "Haiku always allows despite lane and HARD bank" 0 "$RC29"
assert_empty "Haiku always-allow is silent" "$(combined_output haiku)"

RC29B=$(run_hook haiku-full-id "$REG_CLAUDEX" "$(payload general-purpose claude-haiku-4-5-20251001 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_HARD")
assert_rc "full Haiku model identifier also always allows" 0 "$RC29B"
assert_empty "full Haiku identifier always-allow is silent" "$(combined_output haiku-full-id)"

CACHE_ISO="$TMP/cache-iso.json"
ISO_FUTURE=$(node -e "console.log(new Date(Date.now()+3600000).toISOString())")
printf '{"five_hour":{"utilization":85,"resets_at":"%s"}}' "$ISO_FUTURE" > "$CACHE_ISO"
RC30=$(run_hook bank-iso "$REG_NONE" "$(payload general-purpose sonnet 'Implement the fix' 'Write the code.')" IMPL_GUARD_CACHE_PATH="$CACHE_ISO")
assert_rc "fractional ISO future resets_at authorizes HARD" 2 "$RC30"

echo ""
echo "=== HIMMEL-1513: a registry-available lane must also be runnable ==="

# 1. MANDATORY negative test — credential present (registry says claudex is
# available) but bun is NOT resolvable on PATH. The caller must not be
# stranded on a refusal toward a command that cannot execute.
RC31=$(run_hook bun-missing "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" PATH="$STUB_PATH_NO_BUN" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "credential present but bun missing does not strand the caller" 0 "$RC31"
assert_contains "bun-missing warns why claudex was skipped" "bun is not on PATH" "$(cat "$TMP/err-bun-missing")"

# 2. Dispatcher script missing — registry reports claudex, bun exists, but
# scripts/telegram/spawn-claudex.ts is absent from the (fake) checkout.
RC32=$(run_hook dispatcher-missing "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" CLAUDE_PROJECT_DIR="$FAKE_REPO_NO_CLAUDEX" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "missing dispatcher script does not strand the caller" 0 "$RC32"
assert_contains "dispatcher-missing warns why claudex was skipped" "dispatcher is missing" "$(cat "$TMP/err-dispatcher-missing")"

# 3. Fallback to the runnable lane — claudex is registry-available but not
# runnable (its dispatcher is missing), glm is registry-available AND fully
# runnable. The guard must refuse toward glm, not strand the caller.
RC33=$(run_hook fallback-to-glm "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" CLAUDE_PROJECT_DIR="$FAKE_REPO_NO_CLAUDEX" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "unrunnable claudex falls back to runnable glm, refuses" 2 "$RC33"
assert_contains "fallback refusal names the glm dispatcher" "bun scripts/telegram/spawn-glm.ts '<prompt>' --name <slug> --timeout-mins <n>" "$(cat "$TMP/err-fallback-to-glm")"

# 4. Unchanged happy path — when BOTH lanes are registry-available AND
# actually runnable (real checkout, real bun), the guard still refuses and
# still prefers claudex over glm. Proves the runnability check does not
# defeat the guard or disturb the resolver-preference order.
RC34=$(run_hook both-runnable "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "both lanes runnable still refuses, prefers claudex" 2 "$RC34"
assert_contains "preference-order refusal names the claudex dispatcher" "bun scripts/telegram/spawn-claudex.ts '<prompt>' --name <slug> --timeout-mins <n> --effort high" "$(cat "$TMP/err-both-runnable")"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
