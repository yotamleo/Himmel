#!/usr/bin/env bash
# scripts/cr/test-critic-panel-registry.sh — regression guards for HIMMEL-1221:
#   T1  the Z.ai critic credential is loaded from the primary checkout's .env and
#       reaches the dispatched critic (credential-path guard).
#   T2  critics.local.json MERGES per-slug over critics.json (override / append /
#       drop-tombstone), instead of wholesale replacement.
#   T3  CRITICS_JSON env still wins outright (no merge) — the tests/CI contract.
# Hermetic: no network, no real key, bash 3.2 safe. Uses a stub critic (via
# CRITIC_FIRST_PASS) that records what it was dispatched with; no hermes call.
set -uo pipefail

# Clear ambient tier controls so the panel's tier filter is deterministic
# (.env often exports CR_PROFILE); each case sets what it needs explicitly.
unset CR_PROFILE CRITIC_PANEL_TIERS CR_TRIVIALITY_OVERRIDE \
    CRITIC_LEDGER_APPEND CR_LEDGER CRITIC_FIRST_PASS CRITICS_JSON \
    CRITIC_PARALLEL CRITIC_TIMEOUT_SECS CRITIC_PANEL_TOTAL_TIMEOUT_SECS \
    CRITIC_PANEL_STARTED_AT 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d -t critic-panel-registry-test.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0
LEDGER_NOOP="$tmp/ledger-noop.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$LEDGER_NOOP"
chmod +x "$LEDGER_NOOP"
export CRITIC_LEDGER_APPEND="$LEDGER_NOOP"

check() {
    if [ "$2" = "$3" ]; then echo "ok - $1"; else
        echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

# A stub critic: records "slug=<slug> model=<model> zai=<ZAI_API_KEY or MISSING>"
# to $PANEL_TEST_LOG, then emits a valid empty findings block so the panel counts
# it as responded. Ignores stdin (the diff).
STUB="$tmp/stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
slug=""; model=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug)  slug="$2";  shift 2 ;;
        --model) model="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'slug=%s model=%s zai=%s\n' "$slug" "$model" "${ZAI_API_KEY:-MISSING}" >> "$PANEL_TEST_LOG"
printf '# %s First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$slug"
STUBEOF
chmod +x "$STUB"

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,4 @@
 line
+added one
+added two
+added three'

# ---------------------------------------------------------------------------
# T1 — credential path: .env ZAI_API_KEY reaches the dispatched critic, with NO
# manual export. HIMMEL-1648 pinned critic-panel.sh's credential load_dotenv to
# SCRIPT-ROOT resolution (`load_dotenv --root "$(_load_dotenv_primary_for
# "$SCRIPT_DIR/../..")"`), so the loader reads the .env at the PANEL's own
# himmel root, NOT the process cwd's. This block therefore plants its .env
# where the pinned loader actually resolves: a fake himmel-root tree with the
# panel (and scripts/lib/load-dotenv.sh) copied in so $SCRIPT_DIR/../.. lands on
# the fixture root, and the .env planted THERE (mirrors test-critic-panel.sh's
# HIMMEL-1648 block; failure-classify.sh / triviality-gate.sh are [ -r ]-guarded
# fail-open sources, so they degrade when absent and the panel still runs). The
# sentinel value proves the panel read THIS .env, not himmel's.
# ---------------------------------------------------------------------------
T1_ROOT="$tmp/t1-root"; mkdir -p "$T1_ROOT/scripts/cr" "$T1_ROOT/scripts/lib"
cp "$PANEL" "$T1_ROOT/scripts/cr/critic-panel.sh"
cp "$HERE/../lib/load-dotenv.sh" "$T1_ROOT/scripts/lib/load-dotenv.sh"
SENTINEL="sentinel-zai-9f3a7c"
printf 'ZAI_API_KEY=%s\n' "$SENTINEL" > "$T1_ROOT/.env"
printf '%s' '{"panel":[{"slug":"glm","model":"glm-5.2","provider":"zai","tier":"free","route_provider":"glm"}]}' > "$tmp/t1-reg.json"
LOG1="$tmp/t1.log"; : > "$LOG1"
# Unset every alias so load_dotenv actually loads from the temp .env.
( env -u ZAI_API_KEY -u GLM_API_KEY -u Z_AI_API_KEY -u CR_PROFILE -u CRITIC_PANEL_TIERS \
    PANEL_TEST_LOG="$LOG1" CRITICS_JSON="$tmp/t1-reg.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$T1_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 <<< "$DIFF" )
check "T1: glm critic was dispatched"                 "$(grep -c 'slug=glm ' "$LOG1")" "1"
check "T1: .env ZAI_API_KEY reached the critic env"   "$(grep -c "zai=$SENTINEL" "$LOG1")" "1"
check "T1: credential was NOT missing"                "$(grep -c 'zai=MISSING' "$LOG1")" "0"

# ---------------------------------------------------------------------------
# T2 — merge semantics: BASE {glm, dup(base), keepme} + LOCAL {dup(local override),
# lagunaor(append), keepme drop:true}. Expect dispatched: glm (base), dup (LOCAL
# model), lagunaor (append); keepme dropped. CR_TRIVIALITY_OVERRIDE=full so the
# triviality gate cannot strip the paid tier and confound the glm assertion.
# ---------------------------------------------------------------------------
printf '%s' '{"panel":[
  {"slug":"glm","model":"glm-5.2","provider":"zai","tier":"paid","route_provider":"glm"},
  {"slug":"dup","model":"base/dup","provider":"test","tier":"paid"},
  {"slug":"keepme","model":"base/keepme","provider":"test","tier":"paid"}]}' > "$tmp/t2-base.json"
printf '%s' '{"panel":[
  {"slug":"dup","model":"local/dup","provider":"test","tier":"paid"},
  {"slug":"lagunaor","model":"free/laguna","provider":"test","tier":"free"},
  {"slug":"keepme","drop":true}]}' > "$tmp/t2-local.json"
LOG2="$tmp/t2.log"; : > "$LOG2"
env -u CRITICS_JSON \
    PANEL_TEST_LOG="$LOG2" CR_PROFILE="free,paid" CR_TRIVIALITY_OVERRIDE=full \
    CRITICS_BASE_JSON="$tmp/t2-base.json" CRITICS_LOCAL_JSON="$tmp/t2-local.json" \
    CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1 <<< "$DIFF"
check "T2: glm restored from base (core regression)"  "$(grep -c 'slug=glm '      "$LOG2")" "1"
check "T2: local-only row appended (lagunaor)"        "$(grep -c 'slug=lagunaor ' "$LOG2")" "1"
check "T2: overridden slug dispatched exactly once"   "$(grep -c 'slug=dup '      "$LOG2")" "1"
check "T2: override used the LOCAL model"              "$(grep -c 'model=local/dup' "$LOG2")" "1"
check "T2: base model NOT dispatched for override"    "$(grep -c 'model=base/dup'  "$LOG2")" "0"
check "T2: drop-tombstone removed the base row"       "$(grep -c 'slug=keepme '    "$LOG2")" "0"

# ---------------------------------------------------------------------------
# T3 — CRITICS_JSON wins outright: merge is bypassed even when a local overlay is
# pointed at a different fixture.
# ---------------------------------------------------------------------------
printf '%s' '{"panel":[{"slug":"onlyme","model":"m/only","provider":"test","tier":"free"}]}' > "$tmp/t3-json.json"
printf '%s' '{"panel":[{"slug":"other","model":"m/other","provider":"test","tier":"free"}]}' > "$tmp/t3-local.json"
LOG3="$tmp/t3.log"; : > "$LOG3"
env -u CR_PROFILE -u CRITIC_PANEL_TIERS \
    PANEL_TEST_LOG="$LOG3" CRITICS_JSON="$tmp/t3-json.json" CRITICS_LOCAL_JSON="$tmp/t3-local.json" \
    CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1 <<< "$DIFF"
check "T3: CRITICS_JSON row dispatched"                "$(grep -c 'slug=onlyme ' "$LOG3")" "1"
check "T3: local overlay NOT merged (CRITICS_JSON wins)" "$(grep -c 'slug=other ' "$LOG3")" "0"

# ---------------------------------------------------------------------------
# T4 — HIMMEL-2546: the SHIPPED default registry (scripts/cr/critics.json, no
# CRITICS_JSON/CRITICS_BASE_JSON/CRITICS_LOCAL_JSON override) actually dispatches
# the codex row with the model the operator's codex CLI default now expects
# (gpt-6-astra, re-pinned from gpt-5.6-sol). CR_PROFILE=paid selects the codex
# row's tier; CR_TRIVIALITY_OVERRIDE=full stops the triviality gate from
# stripping the paid tier for this tiny fixture diff.
# ---------------------------------------------------------------------------
LOG4="$tmp/t4.log"; : > "$LOG4"
env -u CRITICS_JSON -u CRITICS_BASE_JSON -u CRITICS_LOCAL_JSON \
    PANEL_TEST_LOG="$LOG4" CR_PROFILE="paid" CR_TRIVIALITY_OVERRIDE=full \
    CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1 <<< "$DIFF"
check "T4: default registry dispatched codex"           "$(grep -c 'slug=codex ' "$LOG4")" "1"
check "T4: default registry pinned codex to gpt-6-astra" "$(grep -c 'model=gpt-6-astra' "$LOG4")" "1"
check "T4: default registry did NOT pin the retired id" "$(grep -c 'model=gpt-5.6-sol' "$LOG4")" "0"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
