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
unset CR_PROFILE CRITIC_PANEL_TIERS CR_TRIVIALITY_OVERRIDE 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0

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
# manual export and CWD inside a throwaway git repo (load_dotenv resolves .env
# via `git rev-parse --git-common-dir` of CWD). The sentinel value proves the
# panel read THIS .env, not himmel's.
# ---------------------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
( cd "$repo" && git init -q )
SENTINEL="sentinel-zai-9f3a7c"
printf 'ZAI_API_KEY=%s\n' "$SENTINEL" > "$repo/.env"
printf '%s' '{"panel":[{"slug":"glm","model":"glm-5.2","provider":"zai","tier":"free","route_provider":"glm"}]}' > "$tmp/t1-reg.json"
LOG1="$tmp/t1.log"; : > "$LOG1"
# Unset every alias so load_dotenv actually loads from the temp .env.
( cd "$repo" && env -u ZAI_API_KEY -u GLM_API_KEY -u Z_AI_API_KEY -u CR_PROFILE -u CRITIC_PANEL_TIERS \
    PANEL_TEST_LOG="$LOG1" CRITICS_JSON="$tmp/t1-reg.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" >/dev/null 2>&1 <<< "$DIFF" )
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

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
