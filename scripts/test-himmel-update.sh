#!/usr/bin/env bash
# test-himmel-update.sh — smoke test for the --check (read-only) path of
# scripts/himmel-update.sh (HIMMEL-426).
#
# himmel-update.sh resolves its own repo root via BASH_SOURCE/.. and cd's there,
# so we test it by COPYING it into a throwaway mock clone and running it from
# inside that clone. This exercises the real --check logic (git fetch + behind
# count + the operator-facing wording) with no network and without touching the
# himmel checkout itself.
#
# Covers:
#   1. --check, behind=N → reports "behind:   N" + points at /himmel-update.
#   2. --check, behind=0 → reports "up to date".
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}

_repo_counter=0

# Build a mock upstream bare repo + a clone that is N commits behind it, with
# himmel-update.sh dropped into the clone's scripts/ dir so it resolves the
# clone as its root. Sets CHECKOUT_DIR.
make_repo_behind() {
    local n="${1:-1}"
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${n}_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"
    mkdir -p "$bare" "$clone"

    git init --bare --quiet "$bare"
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"

    local defbranch
    defbranch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)
    git -C "$clone" push --quiet origin "HEAD:$defbranch" 2>/dev/null
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    if [ "$n" -gt 0 ]; then
        local work="$base/work"
        git clone --quiet "$bare" "$work" 2>/dev/null
        git -C "$work" config user.email "test@test.test"
        git -C "$work" config user.name "Test"
        local i
        for i in $(seq 1 "$n"); do
            printf '%s\n' "upstream-commit-$i" > "$work/file.txt"
            git -C "$work" add file.txt
            git -C "$work" commit --quiet -m "upstream $i"
        done
        git -C "$work" push --quiet origin "$defbranch" 2>/dev/null
    fi

    # Drop the script under test into the clone so BASH_SOURCE/.. == clone root.
    mkdir -p "$clone/scripts"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    # himmel-update.sh sources guardrails/lib.sh + lib/cadence-format.sh relative
    # to its resolved root, so the mock clone needs them too — otherwise the
    # script dies at the source line under `set -e` before any --check logic runs.
    local src_scripts; src_scripts="$(dirname "$SCRIPT")"
    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib"
    cp "$src_scripts/guardrails/lib.sh"      "$clone/scripts/guardrails/lib.sh"
    cp "$src_scripts/lib/cadence-format.sh"  "$clone/scripts/lib/cadence-format.sh"
    CHECKOUT_DIR="$clone"
}

# ─── Test 1: --check, behind=2 ───────────────────────────────────────────────
echo "Test 1: --check behind=2 → reports count + /himmel-update"
make_repo_behind 2
out=$(bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "behind=2: behind count reported" "behind:   2" "$out"
assert_contains "behind=2: points at /himmel-update" "/himmel-update" "$out"
assert_contains "behind=2: references himmel-update.sh" "scripts/himmel-update.sh" "$out"

# ─── Test 2: --check, behind=0 ───────────────────────────────────────────────
echo "Test 2: --check behind=0 → reports up to date"
make_repo_behind 0
out=$(bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "behind=0: behind count is 0" "behind:   0" "$out"
assert_contains "behind=0: up to date message" "up to date" "$out"

# ─── Test 3: --plugins-check gap report (HIMMEL-434) ─────────────────────────
# Fixtures: marketplace declares a/b/c. installed has a@himmel (ok),
# b@ext-market (shadowed), c absent (missing). Drive the detection via the
# env-overridable input paths so no real ~/.claude state is touched.
echo "Test 3: --plugins-check → classifies installed / shadowed / missing"
make_repo_behind 0   # reuse a mock clone so the script resolves a valid ROOT
PFIX="$TMP/plugins_fix"
mkdir -p "$PFIX"
cat > "$PFIX/marketplace.json" <<'JSON'
{ "name": "himmel", "plugins": [ {"name":"a"}, {"name":"b"}, {"name":"c"} ] }
JSON
cat > "$PFIX/installed.json" <<'JSON'
{ "version": 1, "plugins": { "a@himmel": [], "b@ext-market": [], "z@himmel": [] } }
JSON
out=$(HIMMEL_MARKETPLACE_JSON="$PFIX/marketplace.json" \
      HIMMEL_INSTALLED_PLUGINS_JSON="$PFIX/installed.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --plugins-check 2>&1) || true
assert_contains "gap: counts 1/3 from @himmel" "1/3 @himmel plugins installed" "$out"
assert_contains "gap: missing 'c' → install hint" "claude plugin install c@himmel" "$out"
assert_contains "gap: shadowed 'b' names the foreign market" "b@ext-market" "$out"
assert_contains "gap: shadowed section points at migrate script" "migrate-plugin-to-himmel.sh" "$out"

# ─── Test 4: --plugins-check all-installed → clean line ──────────────────────
echo "Test 4: --plugins-check → all installed from @himmel reports clean"
cat > "$PFIX/installed-all.json" <<'JSON'
{ "version": 1, "plugins": { "a@himmel": [], "b@himmel": [], "c@himmel": [] } }
JSON
out=$(HIMMEL_MARKETPLACE_JSON="$PFIX/marketplace.json" \
      HIMMEL_INSTALLED_PLUGINS_JSON="$PFIX/installed-all.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --plugins-check 2>&1) || true
assert_contains "all-installed: clean message" "all 3 @himmel plugins installed" "$out"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
