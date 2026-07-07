#!/usr/bin/env bash
# Smoke test for scripts/claude-glm-seed-check.sh (HIMMEL-654 WS5 Task 1).
#
# Verifies the glm-launcher config-seed drift check against injected fixture
# trees: identical -> exit 0; a mutated seeded skills/ file -> exit 1 AND the
# output names it; a settings.json-only difference -> still exit 0 (excluded);
# an empty/unseeded config dir -> exit 2. Also asserts the check NEVER mutates
# the config dir (read-only contract).
#
# Platform guard (gitbash-only): this harness exercises the BASH twin
# (scripts/claude-glm-seed-check.sh) and relies on Git-Bash coreutils
# (mktemp -d, find -type f, cmp, cp -R). A test harness needs no .ps1 twin;
# the PowerShell twin scripts/claude-glm-seed-check.ps1 is behaviour-parallel
# but is not driven here. Invoke as: bash scripts/hooks/test-claude-glm-seed-check.sh
#
# Usage: bash scripts/hooks/test-claude-glm-seed-check.sh
# Exit codes: 0 - all cases passed; 1 - at least one failed
set -uo pipefail

CHECK="$(cd "$(dirname "$0")/.." && pwd)/claude-glm-seed-check.sh"

FAILED=0
CASES=0

assert_rc() {  # <label> <expected-rc> <actual-rc>
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {  # <label> <haystack> <needle>
    local label="$1" haystack="$2" needle="$3"
    CASES=$((CASES + 1))
    case "$haystack" in
        *"$needle"*) echo "PASS $label (output names the file)" ;;
        *) echo "FAIL $label - output did not name '$needle'"; FAILED=$((FAILED + 1)) ;;
    esac
}

# Build a representative SOURCE tree (~/.claude shape) under $1: every seeded
# entry populated, PLUS non-seeded junk (projects/, todos/, settings.json) the
# check must IGNORE, so a clean CFG that lacks them still reads as in-sync.
build_src() {  # $1 = SRC dir
    local s="$1"
    mkdir -p "$s"/{commands,skills,hooks,agents,plugins/marketplaces/m1,plugins/claude-hud,projects,todos}
    printf 'src CLAUDE\n'         > "$s/CLAUDE.md"
    printf 'src RTK\n'            > "$s/RTK.md"
    printf 'cmd one\n'            > "$s/commands/c1.md"
    printf 'skill one\n'          > "$s/skills/s1.md"
    printf 'hook one\n'           > "$s/hooks/h1.sh"
    printf 'agent one\n'          > "$s/agents/a1.md"
    printf '{"installed":true}\n' > "$s/plugins/installed_plugins.json"
    printf '{"mk":true}\n'        > "$s/plugins/known_marketplaces.json"
    printf '{"mp":1}\n'           > "$s/plugins/marketplaces/m1/manifest.json"
    printf '{"hud":true}\n'       > "$s/plugins/claude-hud/config.json"
    # Non-seeded: present in SOURCE, absent in CFG, must NOT register as drift.
    printf '{"model":"glm-5.2","env":{"ANTHROPIC_API_KEY":"sekret"}}\n' > "$s/settings.json"
    printf 'junk projects\n'      > "$s/projects/p.json"
    printf 'junk todos\n'         > "$s/todos/t.json"
}

# Seed a CFG dir with EXACTLY the launcher's seeded set (no settings.json, no
# junk) + the .seeded sentinel the launcher writes last. $1=SRC $2=CFG.
seed_cfg() {
    local s="$1" c="$2"
    # Pre-create ONLY $c/plugins; do NOT pre-create $c/plugins/marketplaces or
    # `cp -R src/plugins/marketplaces $c/plugins/marketplaces` would copy INTO
    # the existing dir (nesting marketplaces/marketplaces). Each seeded subtree
    # is copied to a dest that does not yet exist, so cp creates it at the right
    # depth -- mirrors the launcher's own rm-then-cp clean re-mirror.
    mkdir -p "$c/plugins"
    cp "$s/CLAUDE.md"                       "$c/CLAUDE.md"
    cp "$s/RTK.md"                          "$c/RTK.md"
    cp -R "$s/commands"                     "$c/commands"
    cp -R "$s/skills"                       "$c/skills"
    cp -R "$s/hooks"                        "$c/hooks"
    cp -R "$s/agents"                       "$c/agents"
    cp "$s/plugins/installed_plugins.json"  "$c/plugins/installed_plugins.json"
    cp "$s/plugins/known_marketplaces.json" "$c/plugins/known_marketplaces.json"
    cp -R "$s/plugins/marketplaces"         "$c/plugins/marketplaces"
    mkdir -p "$c/plugins/claude-hud"
    cp "$s/plugins/claude-hud/config.json"  "$c/plugins/claude-hud/config.json"
    : > "$c/.seeded"
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# --- (a) identical trees -> exit 0 -------------------------------------------
SRC="$ROOT/src-a"; CFG="$ROOT/cfg-a"
build_src "$SRC"; seed_cfg "$SRC" "$CFG"
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
assert_rc "(a) identical trees in sync" 0 "$rc"

# --- (b) mutate a seeded skills/ file -> exit 1 AND output names it ----------
SRC="$ROOT/src-b"; CFG="$ROOT/cfg-b"
build_src "$SRC"; seed_cfg "$SRC" "$CFG"
printf 'CHANGED skill one\n' > "$CFG/skills/s1.md"
# Read-only contract: snapshot CFG content+count, run, assert UNCHANGED.
before=$(find "$CFG" -type f -exec cksum {} \; | sort)
count_before=$(find "$CFG" -type f | wc -l)
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
after=$(find "$CFG" -type f -exec cksum {} \; | sort)
count_after=$(find "$CFG" -type f | wc -l)
assert_rc "(b) mutated skills file drifts" 1 "$rc"
assert_contains "(b) drift output names the file" "$out" "skills/s1.md"
CASES=$((CASES + 1))
if [ "$before" = "$after" ] && [ "$count_before" = "$count_after" ]; then
    echo "PASS (b) check did not mutate CFG (read-only)"
else
    echo "FAIL (b) check MUTATED the config dir (must be read-only)"
    FAILED=$((FAILED + 1))
fi

# --- (c) ONLY settings.json differs -> still exit 0 (excluded) ---------------
SRC="$ROOT/src-c"; CFG="$ROOT/cfg-c"
build_src "$SRC"; seed_cfg "$SRC" "$CFG"
# CFG has no settings.json from seed_cfg; add a DIFFERENT one - must be ignored.
printf '{"model":"DIFFERENT","env":{"ANTHROPIC_API_KEY":"other"}}\n' > "$CFG/settings.json"
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
assert_rc "(c) settings.json-only diff ignored" 0 "$rc"

# --- (c2) a seeded dir (hooks) lags -> exit 1 (exclusion is settings-only) ---
SRC="$ROOT/src-c2"; CFG="$ROOT/cfg-c2"
build_src "$SRC"; seed_cfg "$SRC" "$CFG"
printf 'changed hook\n' > "$CFG/hooks/h1.sh"
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
assert_rc "(c2) non-settings seeded diff still drifts" 1 "$rc"
assert_contains "(c2) drift output names hooks file" "$out" "hooks/h1.sh"

# --- (d) empty/unseeded CFG -> exit 2 ----------------------------------------
CFG="$ROOT/cfg-d"
mkdir -p "$CFG"   # present but empty: no .seeded sentinel, no seeded set
SRC="$ROOT/src-d"; build_src "$SRC"
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
assert_rc "(d) empty CFG is unseeded" 2 "$rc"

# --- (d2) CFG dir entirely absent -> exit 2 ----------------------------------
CFG="$ROOT/cfg-d2-missing"
SRC="$ROOT/src-d2"; build_src "$SRC"
out=$(bash "$CHECK" --check --source "$SRC" --config-dir "$CFG" 2>&1); rc=$?
assert_rc "(d2) absent CFG dir is unseeded" 2 "$rc"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS ($CASES cases)"
    exit 0
fi
echo "$FAILED/$CASES case(s) FAILED"
exit 1
