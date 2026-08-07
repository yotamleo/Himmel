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

# HIMMEL-1513 funded-bank fixtures. A fake project root carrying BOTH dispatchers
# (so claudex AND glm pass lane_runnable) but NO bank-status.ts — proves the
# default-path helper-missing branch fail-opens (lane treated as funded) rather
# than stranding the caller.
FAKE_REPO_NO_BANK="$TMP/fake-repo-no-bank"
mkdir -p "$FAKE_REPO_NO_BANK/scripts/lanes" "$FAKE_REPO_NO_BANK/scripts/telegram"
cp "$REPO_ROOT/scripts/lanes/resolve.mjs" "$FAKE_REPO_NO_BANK/scripts/lanes/resolve.mjs"
cp "$REPO_ROOT/scripts/lanes/probe.mjs" "$FAKE_REPO_NO_BANK/scripts/lanes/probe.mjs"
: > "$FAKE_REPO_NO_BANK/scripts/telegram/spawn-claudex.ts"
: > "$FAKE_REPO_NO_BANK/scripts/telegram/spawn-glm.ts"

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

# HIMMEL-1513 funded-bank fixtures. The guard's lane_funded() runs the
# bank-status probe under IMPL_GUARD_BANK_STATUS_CMD; stubbing it (rather than
# building live codex-rollout / glm-ledger fixtures) keeps the suite hermetic
# and independent of the operator's actual bank state (the codex weekly bank is
# spent on the operator's station right now — without this stub, RC34 and the
# claudex-refusal cases would flip to a glm/no-refusal verdict). run_hook
# injects a default ALL-FUNDED stub so the existing runnability cases behave
# unchanged; each funded-scenario test overrides it. The \\n stays literal
# through the env assignment and is interpreted by printf inside `bash -c`.
BANK_FUNDED_CMD="printf 'claudex funded\\nglm funded\\n'"
BANK_CLAUDEX_SPENT_CMD="printf 'claudex spent\\nglm funded\\n'"
BANK_BOTH_SPENT_CMD="printf 'claudex spent\\nglm spent\\n'"
BANK_GARBAGE_CMD="printf 'claudex ???\\nglm ???\\n'"
BANK_HANG_CMD="sleep 30"

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

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "FAIL $label — unexpectedly contains '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    else
        echo "ok   $label"
        pass=$((pass + 1))
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
    printf '%s' "$json" | env CLAUDE_PROJECT_DIR="$REPO_ROOT" LANES_REGISTRY="$registry" PATH="$STUB_BUN_DIR:$PATH" IMPL_GUARD_BANK_STATUS_CMD="$BANK_FUNDED_CMD" "$@" "$BASH_ABS" "$HOOK" \
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
echo "=== HIMMEL-1513: a runnable lane must also be FUNDED ==="

# Default (all-funded) baseline — RC34 above already proves both runnable +
# funded still prefers claudex; these cases override the funded verdict.

# 1. claudex runnable + bank SPENT, glm runnable + funded -> the preferred lane
# falls through to the funded one. The refusal must name GLM, not claudex, and
# must not strand the caller toward the spent claudex lane.
RC35=$(run_hook claudex-spent-glm-funded "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="$BANK_CLAUDEX_SPENT_CMD" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "spent claudex falls through to funded glm, refuses" 2 "$RC35"
assert_contains "spent-claudex refusal names the glm dispatcher" "bun scripts/telegram/spawn-glm.ts '<prompt>' --name <slug> --timeout-mins <n>" "$(cat "$TMP/err-claudex-spent-glm-funded")"
assert_contains "spent-claudex warns why claudex was skipped" "bank is spent" "$(cat "$TMP/err-claudex-spent-glm-funded")"
assert_not_contains "spent-claudex does NOT name the claudex dispatcher" "spawn-claudex" "$(cat "$TMP/err-claudex-spent-glm-funded")"

# 2. BOTH lanes spent -> NO lane refusal is emitted; control falls through to
# the independent HIMMEL-920 bank guard (low bank here -> allow). This is the
# intended behaviour: an unfunded lane never produces a new hard-block.
RC36=$(run_hook both-spent "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="$BANK_BOTH_SPENT_CMD" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "both lanes spent falls through to the bank guard (low bank -> allow)" 0 "$RC36"
assert_contains "both-spent warns claudex spent" "lane 'claudex' is runnable but its bank is spent" "$(cat "$TMP/err-both-spent")"
assert_contains "both-spent warns glm spent" "lane 'glm' is runnable but its bank is spent" "$(cat "$TMP/err-both-spent")"
assert_not_contains "both-spent emits NO lane refusal" "refusing implementation-shaped" "$(cat "$TMP/err-both-spent")"

# 2b. A probe that emits `spent` AND exits NON-ZERO must be treated as FUNDED.
# `spent` is the one arm that refuses a lane, and a timed-out or crashed probe
# can still have written a partial `<lane> spent` line — so accepting it would
# skip a lane on evidence the probe never finished producing. rc is checked
# BEFORE the output is parsed: non-zero means "no verdict", which is fail-OPEN.
# Without that ordering this case reports "bank is spent" and skips claudex.
RC35B=$(run_hook spent-but-rc-nonzero "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="printf 'claudex spent\\nglm spent\\n'; exit 3" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "spent+rc!=0 fails OPEN: claudex stays eligible, hook refuses toward it" 2 "$RC35B"
assert_contains "spent+rc!=0 warns the probe did not finish cleanly" "did not finish cleanly (rc=3)" "$(cat "$TMP/err-spent-but-rc-nonzero")"
assert_contains "spent+rc!=0 treats the lane as funded" "treating it as funded (fail-open)" "$(cat "$TMP/err-spent-but-rc-nonzero")"
assert_not_contains "spent+rc!=0 does NOT accept the partial spent verdict" "bank is spent" "$(cat "$TMP/err-spent-but-rc-nonzero")"

# 3. A spent preferred lane with NO other lane available also falls through
# (no claudex in the registry, glm spent) — no refusal, just the bank guard.
RC37=$(run_hook glm-spent-no-claudex "$REG_GLM" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="printf 'glm spent\\n'" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "spent glm with no claudex falls through (low bank -> allow)" 0 "$RC37"
assert_not_contains "spent-glm emits NO lane refusal" "refusing implementation-shaped" "$(cat "$TMP/err-glm-spent-no-claudex")"

# 4. Fail-open: every probe failure treats the lane as FUNDED, so the refusal is
# unchanged from the funded behaviour (still refuses toward claudex, never
# strands the caller). Covers helper-missing (default path: bank-status.ts
# absent from a fake checkout), helper times out, and garbage output.
RC38=$(run_hook bank-helper-missing "$REG_BOTH" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" CLAUDE_PROJECT_DIR="$FAKE_REPO_NO_BANK" IMPL_GUARD_BANK_STATUS_CMD="" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "missing probe helper fail-opens to claudex refusal" 2 "$RC38"
assert_contains "missing-helper fail-open warns" "bank-status probe is missing" "$(cat "$TMP/err-bank-helper-missing")"
assert_contains "missing-helper still names the claudex dispatcher" "spawn-claudex" "$(cat "$TMP/err-bank-helper-missing")"

RC39=$(run_hook bank-timeout "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="$BANK_HANG_CMD" IMPL_GUARD_BANK_BUDGET_SECS=1 IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "timed-out probe fail-opens to claudex refusal" 2 "$RC39"
assert_contains "timeout fail-open warns" "did not finish cleanly" "$(cat "$TMP/err-bank-timeout")"
assert_contains "timeout still names the claudex dispatcher" "spawn-claudex" "$(cat "$TMP/err-bank-timeout")"

RC40=$(run_hook bank-garbage "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Implement HIMMEL-1513' 'Write the code and commit it.')" IMPL_GUARD_BANK_STATUS_CMD="$BANK_GARBAGE_CMD" IMPL_GUARD_CACHE_PATH="$CACHE_LOW")
assert_rc "garbage probe output fail-opens to claudex refusal" 2 "$RC40"
assert_contains "garbage fail-open warns" "unrecognised state" "$(cat "$TMP/err-bank-garbage")"
assert_contains "garbage still names the claudex dispatcher" "spawn-claudex" "$(cat "$TMP/err-bank-garbage")"

# RC1 above (general-purpose + claudex available refuses) is the regression guard
# proving a general-purpose implementation dispatch is still REFUSED — it runs
# under the default all-funded stub, so it must keep passing unchanged.

echo ""
echo "=== HIMMEL-1617: descriptive fix mentions and plan-shaped briefs ==="

# A read-only / analysis-only judgment brief must reach its lane even though it
# is judgment/taste-shaped (the sanctioned escalation this guard otherwise
# strands mid-session). claudex is available + funded here, so the ONLY thing
# that can refuse is the classifier reading the brief as implementation.
RC41=$(run_hook judgment-no-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Judge doc placement' 'Analysis only. Do not edit any file. Decide whether this doc section belongs in the always-loaded file or a reference. Return a recommendation as text.')")
assert_rc "analysis-only judgment brief with no fix word allows" 0 "$RC41"
assert_empty "analysis-only judgment brief is silent" "$(combined_output judgment-no-fix)"

# The reproduction: the identical brief blocked (rc=2) purely for describing
# prior work with the noun "fix" ("committed a fix"). The descriptive strip
# (and the read-only declaration gate) must let it through.
RC42=$(run_hook judgment-committed-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Judge doc placement' 'Analysis only. Do not edit any file. The parent already committed a fix that expanded the bullet. Return a recommendation as text.')")
assert_rc "judgment brief describing a committed fix allows" 0 "$RC42"
assert_empty "judgment brief describing a committed fix is silent" "$(combined_output judgment-committed-fix)"

# "fix" as past-tense context ("fixed") is description, not an imperative.
RC43=$(run_hook judgment-past-tense-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Judge doc placement' 'Analysis only. Do not edit any file. The earlier work fixed the routing drift. Return a recommendation as text.')")
assert_rc "judgment brief with past-tense fixed allows" 0 "$RC43"
assert_empty "judgment brief with past-tense fixed is silent" "$(combined_output judgment-past-tense-fix)"

# A plan-shaped dispatch that declares no edits is categorically not
# implementation, even though it asks for a plan to FIX something. "to fix the
# flaky suite" sets implementation=1 (bare verb survives the strip), so this
# exercises the HIMMEL-1617 declaration gate — the earlier phrasing never
# tripped implementation and passed trivially (CR round 1, glm-3).
RC44=$(run_hook plan-shaped "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Plan the X subsystem' 'Plan only. Do not edit, create, or commit any file. Produce an implementation plan to fix the flaky X suite and return it as text.')")
assert_rc "plan-shaped brief allows" 0 "$RC44"
assert_empty "plan-shaped brief is silent" "$(combined_output plan-shaped)"

# The read-only declaration gate rescues a descriptive "fix" noun the strip does
# not enumerate ("proposed fix") — proving the HIMMEL-1617 override gate, not
# just the strip. implementation trips on "fix", but the declaration + no action
# transition + no operational context still allows.
RC49=$(run_hook judgment-proposed-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Judge doc placement' 'Read-only. Do not edit any file. The proposed fix is large. Return a recommendation as text.')")
assert_rc "read-only declaration rescues a non-enumerated fix noun" 0 "$RC49"
assert_empty "read-only declaration rescue is silent" "$(combined_output judgment-proposed-fix)"

# Genuine implementation dispatches still refuse. claudex available + funded.
RC45=$(run_hook bare-implement "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'implement this')")
assert_rc "bare 'implement this' still refuses" 2 "$RC45"

RC46=$(run_hook imperative-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'fix the bug in X')")
assert_rc "imperative 'fix the bug in X' still refuses" 2 "$RC46"

# "apply the fix" is imperative and must keep matching despite the descriptive
# "fix" strip (it is masked then restored).
RC47=$(run_hook apply-fix-commit "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'apply the fix and commit')")
assert_rc "imperative 'apply the fix and commit' still refuses" 2 "$RC47"

# A read-only declaration does NOT rescue a prompt that then transitions to
# action — followed_by_action stays a veto.
RC48=$(run_hook readonly-then-implement "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only first. Do not edit any file. then implement it')")
assert_rc "read-only declaration followed by 'then implement it' still refuses" 2 "$RC48"

# CR round 1 regressions (glm-1, glm-2): the descriptive strip and the loose
# read-only match must not launder genuine imperatives.
# "commit the fix" is imperative — the action-verb mask must protect it from
# the article strip (the apply-only mask let it classify as non-implementation).
RC50=$(run_hook commit-the-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'commit the fix')")
assert_rc "imperative 'commit the fix' still refuses" 2 "$RC50"

RC51=$(run_hook push-the-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'push the fix to the branch')")
assert_rc "imperative 'push the fix to the branch' still refuses" 2 "$RC51"

# "readonly"/"read-only" as an ADJECTIVE on a noun is not a declaration — the
# imperative "fix" must still refuse (the loose match rescued both of these).
RC52=$(run_hook readonly-adjective "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'fix the readonly field in the config parser')")
assert_rc "imperative 'fix the readonly field' still refuses" 2 "$RC52"

RC53=$(run_hook read-only-adjective "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'fix the read-only field in the config parser')")
assert_rc "imperative 'fix the read-only field' still refuses" 2 "$RC53"

# CR round 2 (CodeRabbit, PR #1605): a standalone imperative at a clause head
# is genuine implementation intent — the read-only declaration must NOT rescue
# it (imperative_verb vetoes the override, like followed_by_action).
RC54=$(run_hook readonly-then-imperative "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only. Do not edit any file. Fix the bug in X.')")
assert_rc "read-only declaration with a clause-head imperative still refuses" 2 "$RC54"

RC55=$(run_hook imperative-at-start "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Fix the flaky retry loop. Return a summary as text.')")
assert_rc "text-initial imperative with a trailing return-as-text still refuses" 2 "$RC55"

# CR round 3 (glm, PR #1605): an adverb-prefixed imperative ("Please fix",
# "Now implement") defeated the bare clause-head anchor; the verb+determiner
# shape and the adverb run must both veto the read-only override.
RC56=$(run_hook readonly-please-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only. Do not edit any file. Please fix the bug in X.')")
assert_rc "read-only declaration with 'Please fix the bug' still refuses" 2 "$RC56"

RC57=$(run_hook readonly-now-implement "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only. Do not edit any file. Now implement the retry logic.')")
assert_rc "read-only declaration with 'Now implement the retry logic' still refuses" 2 "$RC57"

# The masked action-verb restore ("commit the fix" -> "apply the fix") must
# also read as imperative under a declaration.
RC58=$(run_hook readonly-commit-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only. Do not edit any file. Commit the fix.')")
assert_rc "read-only declaration with 'Commit the fix' still refuses" 2 "$RC58"

# CR round 2 (HIMMEL-1617): the descriptive strip carries the original ALLOW
# cases (no clause-initial bare verb survives), so they keep allowing. Probe (a)
# is the full descriptive brief — it must stay allowed even though "committed a
# fix" appears, because the strip removes the noun and no imperative remains.
RC56=$(run_hook probe-descriptive-allows "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Judge doc placement' 'Analysis only. Do not edit any file. Decide whether this doc section belongs in the always-loaded file or a reference. The parent already committed a fix that expanded the bullet. Return a recommendation as text.')")
assert_rc "descriptive analysis brief with a committed fix allows" 0 "$RC56"
assert_empty "descriptive analysis brief is silent" "$(combined_output probe-descriptive-allows)"

# imperative_verb covers (implement|fix|land), not just "fix": a clause-initial
# "implement" under an analysis-only declaration refuses via the new veto alone
# (followed_by_action and operational_context are both 0 here, so this isolates
# imperative_verb as the only thing blocking the override).
RC57=$(run_hook standalone-implement-blocks "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Analysis only. Do not edit any file. Implement the new handler and report.')")
assert_rc "analysis-only declaration does not rescue a standalone implement" 2 "$RC57"

# CR round (HIMMEL-1624): the catch-all "fixed" descriptive strip is now
# word-boundary anchored, so "prefixed"/"unfixed"/"affixed" survive intact.
# As descriptive context under a read-only declaration they must still ALLOW
# (the "fix" inside them never trips the bounded implementation grep), and a
# genuine imperative must not be laundered by a descriptive neighbour.
RC59=$(run_hook descriptive-prefixed-unfixed "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Review the diff' 'Read-only. Do not edit any file. Review the prefixed log lines and the unfixed test cases. Return a recommendation as text.')")
assert_rc "descriptive prefixed/unfixed brief allows" 0 "$RC59"
assert_empty "descriptive prefixed/unfixed brief is silent" "$(combined_output descriptive-prefixed-unfixed)"

RC60=$(run_hook imperative-fix-prefixed-field "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'fix the prefixed field in the parser')")
assert_rc "imperative 'fix the prefixed field' still refuses" 2 "$RC60"

# The infinitive strip's "to" is left-boundary anchored, so the "to " inside
# "auto fix"/"into fix" is no longer eaten — a genuine imperative under a
# read-only declaration must still refuse (an unbounded s/to fix/ let this ALLOW).
RC61=$(run_hook readonly-auto-fix "$REG_CLAUDEX" "$(payload general-purpose sonnet 'Do the work' 'Read-only. Do not edit any file. Auto fix the parser.')")
assert_rc "read-only declaration with 'Auto fix the parser' still refuses" 2 "$RC61"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
