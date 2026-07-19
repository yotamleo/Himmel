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
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected '$expected', got '$actual'"
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
    cp "$src_scripts/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$src_scripts/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
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

# ─── rewire_statusline ───────────────────────────────────────────────────────
echo "Test 5: rewire_statusline → migrates only existing himmel statusLine wiring"
REAL_ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
REAL_ROOT_FWD="${REAL_ROOT//\\//}"
EXPECTED_HUD_CMD="node \"$REAL_ROOT_FWD/marketplace/plugins/claude-hud/dist/index.js\""

run_rewire_statusline() {
    local p="$1"
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        HIMMEL_UPDATE_LIB=1 . "$SCRIPT"
        CLAUDE_USER_SETTINGS="$p" rewire_statusline
    )
}

# Case a: old bash bar wiring is migrated to the hud renderer, preserving env
# siblings and top-level settings.
printf '%s' '{"statusLine":{"type":"command","command":"bash \"C:/old/himmel/scripts/where-are-we/statusline.sh\""},"env":{"KEEP":"1"},"theme":"dark"}' > "$TMP/sl-old.json"
if run_rewire_statusline "$TMP/sl-old.json" >/dev/null 2>&1; then
    assert_pass "rewire old bash bar: rc 0"
else
    assert_fail "rewire old bash bar: rc non-zero"
fi
assert_eq "rewire old bash bar: hud command" "$EXPECTED_HUD_CMD" "$(jq -r '.statusLine.command' "$TMP/sl-old.json")"
assert_eq "rewire old bash bar: hud env gate" "1" "$(jq -r '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD' "$TMP/sl-old.json")"
assert_eq "rewire old bash bar: preserves env sibling" "1" "$(jq -r '.env.KEEP' "$TMP/sl-old.json")"
assert_eq "rewire old bash bar: preserves theme" "dark" "$(jq -r '.theme' "$TMP/sl-old.json")"

# Case a2: the OLD VENDORED path (pre-HIMMEL-538 installs) also migrates.
printf '%s' '{"statusLine":{"type":"command","command":"bash \"C:/old/himmel/scripts/statusline/bin/statusline.sh\""}}' > "$TMP/sl-vendored.json"
if run_rewire_statusline "$TMP/sl-vendored.json" >/dev/null 2>&1; then
    assert_pass "rewire old vendored bar: rc 0"
else
    assert_fail "rewire old vendored bar: rc non-zero"
fi
assert_eq "rewire old vendored bar: hud command" "$EXPECTED_HUD_CMD" "$(jq -r '.statusLine.command' "$TMP/sl-vendored.json")"

# Case b: custom statusLine is byte-unchanged.
printf '%s' '{"statusLine":{"type":"command","command":"bash /opt/mine.sh"}}' > "$TMP/sl-custom.json"
cp "$TMP/sl-custom.json" "$TMP/sl-custom.before"
if run_rewire_statusline "$TMP/sl-custom.json" >/dev/null 2>&1; then
    assert_pass "rewire custom statusLine: rc 0"
else
    assert_fail "rewire custom statusLine: rc non-zero"
fi
if cmp -s "$TMP/sl-custom.before" "$TMP/sl-custom.json"; then
    assert_pass "rewire custom statusLine: unchanged"
else
    assert_fail "rewire custom statusLine: changed unexpectedly"
fi

# Case c: no statusLine key is unchanged.
printf '%s' '{"theme":"dark"}' > "$TMP/sl-none.json"
cp "$TMP/sl-none.json" "$TMP/sl-none.before"
if run_rewire_statusline "$TMP/sl-none.json" >/dev/null 2>&1; then
    assert_pass "rewire no statusLine: rc 0"
else
    assert_fail "rewire no statusLine: rc non-zero"
fi
if cmp -s "$TMP/sl-none.before" "$TMP/sl-none.json"; then
    assert_pass "rewire no statusLine: unchanged"
else
    assert_fail "rewire no statusLine: changed unexpectedly"
fi

# Case d: absent settings path is a no-create no-op.
if run_rewire_statusline "$TMP/sl-missing.json" >/dev/null 2>&1; then
    assert_pass "rewire absent settings: rc 0"
else
    assert_fail "rewire absent settings: rc non-zero"
fi
if [ ! -e "$TMP/sl-missing.json" ]; then
    assert_pass "rewire absent settings: file not created"
else
    assert_fail "rewire absent settings: file created unexpectedly"
fi

# Case e: invalid JSON is unchanged and non-fatal.
printf '%s' '{"statusLine":' > "$TMP/sl-invalid.json"
cp "$TMP/sl-invalid.json" "$TMP/sl-invalid.before"
if run_rewire_statusline "$TMP/sl-invalid.json" >/dev/null 2>&1; then
    assert_pass "rewire invalid JSON: rc 0"
else
    assert_fail "rewire invalid JSON: rc non-zero"
fi
if cmp -s "$TMP/sl-invalid.before" "$TMP/sl-invalid.json"; then
    assert_pass "rewire invalid JSON: unchanged"
else
    assert_fail "rewire invalid JSON: changed unexpectedly"
fi

# Case f: idempotent — a second run leaves the migrated file identical.
cp "$TMP/sl-old.json" "$TMP/sl-old.once"
if run_rewire_statusline "$TMP/sl-old.json" >/dev/null 2>&1; then
    assert_pass "rewire idempotent second run: rc 0"
else
    assert_fail "rewire idempotent second run: rc non-zero"
fi
if cmp -s "$TMP/sl-old.once" "$TMP/sl-old.json"; then
    assert_pass "rewire idempotent second run: unchanged"
else
    assert_fail "rewire idempotent second run: changed unexpectedly"
fi

# ─── update_codex (HIMMEL-742/605) ───────────────────────────────────────────
echo "Test 6: update_codex → skips when codex absent/unprovisioned, re-sanitizes when provisioned"

run_update_codex() {   # <mode>; caller sets CODEX_BIN / CODEX_HOME in the env
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        HIMMEL_UPDATE_LIB=1 . "$SCRIPT"
        update_codex "$1"
    )
}

# Stub codex CLI: accepts any subcommand, exits 0. install-himmel-codex.sh drives
# `codex plugin marketplace list/add` + `codex plugin list/add`; the re-provision
# path needs no real output — phase 3 (sanitize) is what this test asserts.
CODEX_STUB="$TMP/codex-stub"
printf '#!/bin/sh\nexit 0\n' > "$CODEX_STUB"
chmod +x "$CODEX_STUB"

# Case a: codex absent (CODEX_BIN set but not executable) → skip, flow continues.
rc=0
out=$(CODEX_BIN="$TMP/no-such-codex" run_update_codex apply 2>&1) || rc=$?
assert_eq "update_codex codex-absent: rc 0" "0" "$rc"
assert_contains "update_codex codex-absent: skip notice" "skip: CODEX_BIN set but not executable" "$out"

# Case b: codex present but never provisioned (no plugin cache) → skip, rc 0.
rc=0
out=$(CODEX_BIN="$CODEX_STUB" CODEX_HOME="$TMP/codex-empty" run_update_codex apply 2>&1) || rc=$?
assert_eq "update_codex cache-absent: rc 0" "0" "$rc"
assert_contains "update_codex cache-absent: skip notice" "no codex plugin cache" "$out"

# Case c: codex present + cache with a description-bearing hooks.json → after
# apply, the top-level description key is stripped (installer phase 3 ran).
CODEX_HOME_C="$TMP/codex-present"
CACHE_C="$CODEX_HOME_C/plugins/cache/ext-desc/hooks"
mkdir -p "$CACHE_C"
cat > "$CACHE_C/hooks.json" <<'JSON'
{ "description": "ext plugin", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo hi" } ] } ] } }
JSON
rc=0
out=$(CODEX_BIN="$CODEX_STUB" CODEX_HOME="$CODEX_HOME_C" run_update_codex apply 2>&1) || rc=$?
assert_eq "update_codex provisioned: rc 0" "0" "$rc"
if jq -e 'has("description")' "$CACHE_C/hooks.json" >/dev/null 2>&1; then
    assert_fail "update_codex provisioned: description NOT stripped"
else
    assert_pass "update_codex provisioned: description stripped"
fi
assert_eq "update_codex provisioned: hooks block preserved" "echo hi" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$CACHE_C/hooks.json")"

# Case d: --check mode is read-only advisory — reports provisioned, mutates nothing.
cat > "$CACHE_C/hooks.json" <<'JSON'
{ "description": "ext plugin", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo hi" } ] } ] } }
JSON
rc=0
out=$(CODEX_BIN="$CODEX_STUB" CODEX_HOME="$CODEX_HOME_C" run_update_codex check 2>&1) || rc=$?
assert_eq "update_codex check: rc 0" "0" "$rc"
assert_contains "update_codex check: advisory notice" "codex provisioned" "$out"
if jq -e 'has("description")' "$CACHE_C/hooks.json" >/dev/null 2>&1; then
    assert_pass "update_codex check: read-only (description left in place)"
else
    assert_fail "update_codex check: MUTATED cache in read-only mode"
fi

# ─── Test 7: dirty-tree autostash opt-in reads repo-root .env (HIMMEL-1205) ───
# HIMMEL_UPDATE_AUTOSTASH set in the checkout's .env must flip the dirty-tree
# guard from "refusing" to "autostashing" — the same .env source the Jira CLI
# reads. A live shell var still wins (load_dotenv fills only UNSET keys), so the
# cases below unset it (the harness shell itself may export it) to isolate .env.
echo "Test 7: dirty tree — .env HIMMEL_UPDATE_AUTOSTASH=1 flips refuse → autostash"
make_repo_behind 1
printf 'local-dirty-edit\n' > "$CHECKOUT_DIR/file.txt"   # dirty the working tree

# Case a — no .env opt-in: refuses (exits at the guard, before the chain).
out=$(env -u HIMMEL_UPDATE_AUTOSTASH bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || true
assert_contains "dirty + no opt-in: refuses to pull" "refusing to pull into a dirty tree" "$out"

# Case b — .env opt-in (shell var still unset): autostashes instead of refusing.
# No `timeout` (not portable — macOS lacks GNU timeout). The run stays bounded +
# offline via a throwaway HOME/HERMES_HOME: the autostash reapply conflicts on
# the shared file, so the pull fails and the chain aborts fast; the "autostashing"
# line prints at the guard, before the pull. The chain's remaining steps also
# fail fast (the mock clone has no marketplace/jira/qmd dirs) with no network.
printf 'HIMMEL_UPDATE_AUTOSTASH=1\n' > "$CHECKOUT_DIR/.env"
th7_home="$TMP/th7-home"; mkdir -p "$th7_home/.claude"
rc=0
out=$(env -u HIMMEL_UPDATE_AUTOSTASH USERPROFILE='' HOME="$th7_home" \
      HERMES_HOME="$TMP/th7-no-hermes" CLAUDE_USER_SETTINGS="$th7_home/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_contains "dirty + .env opt-in: autostashes (not refuses)" "autostashing local changes" "$out"
# The guard line above would still print if the pull dropped --autostash, so
# assert the CONTRACT at the pull: a stash entry exists only because the pull
# ran with --autostash (the guard itself never stashes), and update_pull's
# autostash-only failure detail only renders when $autostash was non-empty.
if [ -n "$(git -C "$CHECKOUT_DIR" stash list 2>/dev/null)" ]; then
    assert_pass "dirty + .env opt-in: pull ran with --autostash (stash entry created)"
else
    assert_fail "dirty + .env opt-in: no stash entry — pull did NOT get --autostash"
fi
assert_contains "dirty + .env opt-in: autostash-only pull detail" \
    "autostash \(active\|reapply conflicted\)" "$out"
# The reapply conflicts on the shared file, so the chain aborts non-zero. Assert
# it rather than masking with `|| true` (a 0 here would mean the guard never
# reached the failing pull).
if [ "$rc" -ne 0 ]; then
    assert_pass "dirty + .env opt-in: chain aborts non-zero on the conflicted reapply"
else
    assert_fail "dirty + .env opt-in: expected non-zero exit, got 0"
fi

# Case c — live shell var WINS over .env: .env says 1, live says 0 → refuses.
# load_dotenv fills only UNSET keys, so an explicit live 0 must not be overridden.
make_repo_behind 1
printf 'local-dirty-edit\n' > "$CHECKOUT_DIR/file.txt"
printf 'HIMMEL_UPDATE_AUTOSTASH=1\n' > "$CHECKOUT_DIR/.env"
out=$(HIMMEL_UPDATE_AUTOSTASH=0 bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || true
assert_contains "live 0 overrides .env 1: refuses to pull" "refusing to pull into a dirty tree" "$out"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
