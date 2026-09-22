#!/usr/bin/env bash
# test-himmel-update-check.sh — hermetic cases for the --check (read-only) and
# --plugins-check / --only paths of scripts/himmel-update.sh (HIMMEL-426),
# split out of test-himmel-update.sh by HIMMEL-3450 so this file can run in CI
# (scripts/ci/run-shell-tests.sh SKIP_LIST'd the monolith wholesale, and a real
# bug — HIMMEL-3449 — shipped straight through that gap).
#
# Every case here is hermetic under the CI runner: local bare-git-repo
# fixtures under its own $TMP, PATH-independent (no real network, no station
# marketplace/plugin registration), and HOME/CLAUDE_CONFIG_DIR/HERMES_HOME are
# pinned to throwaway dirs below. The one case that genuinely needs the real
# station HOME (the `--only marketplace` sub-case of Test 19) stays behind in
# test-himmel-update.sh, which stays on SKIP_LIST for that reason alone.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-update-check.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# HIMMEL-2902: scope the profile lookup to this suite's own tmp dir and clear
# any inherited channel so a station's real install profile (e.g. channel:
# stable) cannot steer these plain --check scenarios.
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HIMMELCTL_CACHE_DIR"
unset HIMMEL_UPDATE_CHANNEL

# HIMMEL-3101: suite-level hermeticity. Several cases invoke the bare default
# chain (no --only/--check), which on a guard fall-through reaches the
# unconditional post-chain advisory block (rewire_statusline, update_hermes,
# ...) — that block writes into $HOME/.claude (or $CLAUDE_CONFIG_DIR if set)
# and can restart the real hermes-gateway service via the real ~/.hermes
# checkout. Per-test HOME/HERMES_HOME overrides (Test 7b, Test 23) aren't
# enough on their own — this is a suite-wide floor so no case, present or
# future, can reach real host state by omission.
export USERPROFILE=''
export HOME="$TMP/suite-home"
export CLAUDE_CONFIG_DIR="$TMP/suite-no-claude-config"
export HERMES_HOME="$TMP/suite-no-hermes"
mkdir -p "$HOME/.claude"

# shellcheck source=lib/himmel-update-fixtures.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/himmel-update-fixtures.sh"

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
# --selftest-hermetic builds one behind=2 mock clone and replays --check on
# it, printing its output — used only by the guard case below, recursing into
# THIS file once with a controlled ambient env, never the full suite.
if [ "${1:-}" = "--selftest-hermetic" ]; then
    make_repo_behind 2
    bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1
    exit $?
fi

echo "== suite hermeticity (HIMMEL-2902) =="
# A station's real install-profile.json (channel: stable) must not leak into
# these plain --check scenarios via an inherited HIMMELCTL_CACHE_DIR — this
# recurses with a station-like profile ambient exactly the way a caller's
# shell would carry it, before this file's own preamble override (above) runs.
STATION_DIR="$TMP/station-profile"
mkdir -p "$STATION_DIR"
printf '{"channel":"stable"}\n' > "$STATION_DIR/install-profile.json"
station="$(HIMMELCTL_CACHE_DIR="$STATION_DIR" bash "$0" --selftest-hermetic)"; station_rc=$?
clean="$(bash "$0" --selftest-hermetic)"; clean_rc=$?
if [ "$station_rc" -eq 0 ] && [ "$clean_rc" -eq 0 ] && grepq "$station" 'behind:   2' && grepq "$clean" 'behind:   2'; then
    assert_pass "suite is hermetic to a station install profile"
else
    assert_fail "suite is hermetic to a station install profile (station_rc=$station_rc clean_rc=$clean_rc station='$station' clean='$clean')"
fi

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
      CLAUDE_CONFIG_DIR="$TMP/th7-no-claude-config" \
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
if grepq "$out" -E "autostash (active|reapply conflicted)"; then
    assert_pass "dirty + .env opt-in: autostash-only pull detail"
else
    assert_fail "dirty + .env opt-in: autostash-only pull detail — got: $out"
fi
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
# ─── Test 8: unset channel → pull path unchanged (no channel line, no tags) ──
echo "Test 8: unset channel → --check output unchanged (no 'channel:' line)"
make_repo_channel
channel_tag_here "v0.1.0"
out=$(bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
if grepq "$out" "^channel:"; then
    assert_fail "unset channel: --check must not print a 'channel:' line"
else
    assert_pass "unset channel: --check has no 'channel:' line"
fi
assert_contains "unset channel: plain branch/upstream report still runs" "upstream:" "$out"

# ─── Test 9: stable channel, only pre tags exist → "no stable release yet" ───
echo "Test 9: channel=stable, only -pre.N tags exist → no stable release yet"
make_repo_channel
channel_tag_here "v0.1.0-pre.1"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "stable, no stable tag: --check rc 0" "0" "$rc"
assert_contains "stable, no stable tag: exact message" "no stable release yet — nothing to follow" "$out"

# ─── Test 10: stable channel, v0.1.0 present, HEAD behind it → detach ────────
echo "Test 10: channel=stable, HEAD behind v0.1.0 → --check reports behind, apply detaches"
make_repo_channel
INIT_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before release"
channel_tag_here "v0.1.0"
channel_commit "post-release change"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$INIT_SHA"
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "stable behind: exact wording" "behind stable v0.1.0 (at" "$out"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "stable behind: apply rc 0" "0" "$rc"
assert_eq "stable behind: HEAD lands on the tag" "v0.1.0" "$(git -C "$CHECKOUT_DIR" describe --tags)"
assert_eq "stable behind: HEAD is detached" "HEAD" "$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD)"

# ─── Test 11: pre channel picks the highest pre tag over an older stable ─────
echo "Test 11: channel=pre → detaches at the highest -pre.N tag"
make_repo_channel
channel_tag_here "v0.1.0"
channel_commit "pre release work"
channel_tag_here "v0.2.0-pre.1"
BEHIND_SHA=$(git -C "$CHECKOUT_DIR" rev-parse --short HEAD^)
git -C "$CHECKOUT_DIR" reset --quiet --hard "$BEHIND_SHA"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=pre bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "pre channel: apply rc 0" "0" "$rc"
assert_eq "pre channel: HEAD lands on the -pre.N tag" "v0.2.0-pre.1" "$(git -C "$CHECKOUT_DIR" describe --tags)"

# ─── Test 12: pre.10 vs pre.9 compares numerically, not lexically ────────────
echo "Test 12: pre.10 outranks pre.9 (numeric, not lexical, ordering)"
make_repo_channel
channel_tag_here "v0.1.0-pre.9"
channel_tag_here "v0.1.0-pre.10"
resolved=$(run_channel_lib '_channel_resolve_tag pre')
assert_eq "pre.10 vs pre.9: highest resolves to pre.10" "v0.1.0-pre.10" "$resolved"
max_ba=$(run_channel_lib '_channel_tag_max v0.1.0-pre.9 v0.1.0-pre.10')
max_ab=$(run_channel_lib '_channel_tag_max v0.1.0-pre.10 v0.1.0-pre.9')
assert_eq "_channel_tag_max(pre.9, pre.10) picks pre.10" "v0.1.0-pre.10" "$max_ba"
assert_eq "_channel_tag_max(pre.10, pre.9) picks pre.10" "v0.1.0-pre.10" "$max_ab"

# RED control: a naive LEXICAL comparison of the same two tags gets pre.9 and
# pre.10 backwards ('9' > '1' as characters) — proving this test would catch a
# regression to string comparison instead of numeric. The real code (asserted
# above) must NOT reproduce this.
# shellcheck disable=SC2050 # deliberately constant: proving lexical compare is wrong
if [[ "v0.1.0-pre.9" > "v0.1.0-pre.10" ]]; then
    assert_pass "RED control: lexical string compare picks the WRONG winner (pre.9 > pre.10)"
else
    assert_fail "RED control: expected lexical compare to be wrong here — fixture no longer demonstrates the bug class"
fi

# ─── Test 13: never downgrade — HEAD ahead of the resolved tag ──────────────
echo "Test 13: HEAD ahead of the resolved tag → 'not behind — leaving as-is', no mutation"
make_repo_channel
channel_tag_here "v0.1.0"
channel_commit "local work past the release"
AHEAD_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "never-downgrade: check reports leaving as-is" "not behind — leaving as-is" "$out"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "never-downgrade: apply rc 0" "0" "$rc"
assert_eq "never-downgrade: HEAD unchanged (no downgrade to v0.1.0)" "$AHEAD_SHA" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"

# ─── Test 14: dirty checkout is refused, never moved ─────────────────────────
echo "Test 14: channel apply refuses a dirty checkout, even with HIMMEL_UPDATE_AUTOSTASH=1"
make_repo_channel
INIT_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before release"
channel_tag_here "v0.1.0"
channel_commit "post-release change"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$INIT_SHA"
BEHIND_SHA="$INIT_SHA"
printf 'local-dirty-edit\n' > "$CHECKOUT_DIR/file.txt"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_contains "channel dirty: refuses" "uncommitted changes" "$out"
assert_eq "channel dirty: HEAD unchanged" "$BEHIND_SHA" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
rc=0
out=$(HIMMEL_UPDATE_AUTOSTASH=1 HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_contains "channel dirty + AUTOSTASH=1: still refuses (autostash doesn't apply to switch --detach)" "uncommitted changes" "$out"
assert_eq "channel dirty + AUTOSTASH=1: HEAD still unchanged" "$BEHIND_SHA" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
git -C "$CHECKOUT_DIR" restore file.txt 2>/dev/null || true

# ─── Test 15: env beats profile ──────────────────────────────────────────────
echo "Test 15: HIMMEL_UPDATE_CHANNEL env overrides the profile's channel"
make_repo_channel
channel_tag_here "v0.1.0"
PROFILE_DIR="$TMP/th15-profile"
mkdir -p "$PROFILE_DIR"
printf '{"channel":"pre"}\n' > "$PROFILE_DIR/install-profile.json"
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "profile alone: channel=pre picked up" "channel:  pre" "$out"
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "env overrides profile: channel=stable wins" "channel:  stable" "$out"

# ─── Test 16: --check never mutates ──────────────────────────────────────────
# HIMMEL-2827 (codex-3, PR #2273 round 3): the tag must land on a LATER
# commit than the reset target, or HEAD ends up ON the tag (up-to-date)
# instead of behind it, and the "even when behind" scenario this test
# claims to cover never actually runs — same INIT_SHA-then-tag-then-reset
# shape as Test 10.
echo "Test 16: channel --check never moves HEAD, even when behind"
make_repo_channel
BEHIND_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before release"
channel_tag_here "v0.1.0"
channel_commit "post-release change"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$BEHIND_SHA"
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || true
assert_contains "channel --check behind: fixture actually reports behind" "behind stable v0.1.0 (at" "$out"
HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check >/dev/null 2>&1 || true
HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check >/dev/null 2>&1 || true
assert_eq "channel --check: HEAD unchanged after two runs" "$BEHIND_SHA" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
assert_eq "channel --check: still attached (not detached)" "$CHECKOUT_ORIG_BRANCH" "$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD)"

# ─── Test 17 (HIMMEL-2705 codex-1): malformed profile channel fails loud ────
# jq's `// empty` coalesces both `null` and `false` to "absent" — a bare
# `channel: false` must be rejected the same way a bad string is, not
# silently treated as unset, and invalid JSON must not be swallowed either.
echo "Test 17: profile channel — malformed JSON and non-string values fail loud, null/absent stay silently unset"
make_repo_channel
channel_tag_here "v0.1.0"
PROFILE_DIR="$TMP/th17-profile"
mkdir -p "$PROFILE_DIR"
printf '{"channel":false}\n' > "$PROFILE_DIR/install-profile.json"
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "profile channel:false: rc 2" "2" "$rc"
assert_contains "profile channel:false: invalid channel message" "invalid channel" "$out"
printf '{ not valid json' > "$PROFILE_DIR/install-profile.json"
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "profile malformed JSON: rc 2" "2" "$rc"
assert_contains "profile malformed JSON: not valid JSON message" "not valid JSON" "$out"
printf '{"channel":null}\n' > "$PROFILE_DIR/install-profile.json"
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "profile channel:null: rc 0 (treated as unset)" "0" "$rc"

# ─── Test 18 (HIMMEL-2705 codex-1/codex-2, round 3): jq-missing and ─────────
# non-object profile roots fail loud too. A profile FILE existing is the
# signal that a channel *might* be set — without jq we cannot tell, so a
# missing jq must not silently fall through to "unset" the way a missing
# profile file legitimately does.
echo "Test 18: profile channel — jq unavailable and a non-object JSON root both fail loud"
make_repo_channel
channel_tag_here "v0.1.0"
PROFILE_DIR="$TMP/th18-profile"
mkdir -p "$PROFILE_DIR"
printf '{"channel":"stable"}\n' > "$PROFILE_DIR/install-profile.json"
NO_JQ_BIN="$TMP/th18-no-jq-bin"
mkdir -p "$NO_JQ_BIN"
# Mirror every directory on the REAL PATH (macOS keeps bash in /bin, not
# /usr/bin), minus jq -- the point of the fixture is an absent jq, not an
# absent interpreter.
saved_ifs="$IFS"
IFS=':'
for d in $PATH; do
    IFS="$saved_ifs"
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        [ "$bn" = "jq" ] && continue
        [ -e "$NO_JQ_BIN/$bn" ] && continue
        ln -s "$f" "$NO_JQ_BIN/$bn" 2>/dev/null || true
    done
    IFS=':'
done
IFS="$saved_ifs"
rc=0
out=$(PATH="$NO_JQ_BIN" HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "profile exists, jq missing: rc 2" "2" "$rc"
assert_contains "profile exists, jq missing: message names jq" "jq is not installed" "$out"
printf '[]' > "$PROFILE_DIR/install-profile.json"
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "profile is a JSON array, not object: rc 2" "2" "$rc"
assert_contains "profile is a JSON array: not a valid JSON object message" "not a valid JSON object" "$out"

# ─── Test 19 (HIMMEL-2705 codex-1, round 4): channel resolved lazily, not ────
# up front — a malformed channel must abort ONLY a mode that actually needs
# the pull configuration; --plugins-check and unrelated --only items must
# still succeed unconditionally, matching their own documented contract.
echo "Test 19: malformed profile channel does not abort --plugins-check or an unrelated --only item"
make_repo_channel
PROFILE_DIR="$TMP/th19-profile"
mkdir -p "$PROFILE_DIR"
printf '{"channel":false}\n' > "$PROFILE_DIR/install-profile.json"
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --plugins-check 2>&1) || rc=$?
assert_eq "malformed channel: --plugins-check still exits 0" "0" "$rc"
# The `--only marketplace` sub-case of this scenario (HIMMEL-2705 codex-1)
# needs the real station HOME/marketplace registration to pass, so it is not
# hermetic under CI (HIMMEL-3450) and lives in test-himmel-update.sh
# (SKIP_LIST) instead of here.
rc=0
out=$(HIMMELCTL_CACHE_DIR="$PROFILE_DIR" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "malformed channel: --only pull (the item that DOES need it) still fails" "1" "$rc"
assert_contains "malformed channel: --only pull failure names the channel problem" "invalid channel" "$out"

# ─── Test 20 (HIMMEL-2705 codex-1, round 5): a stray LOCAL-only tag never ────
# outranks or substitutes for an origin-advertised one — channel resolution
# must be sourced from origin, not a plain `git tag --list` scan of every
# local tag (which would also pick up a tag from some other remote, or one a
# local `git tag` command created by mistake).
echo "Test 20: a stray local-only tag (never pushed to origin) is not a channel candidate"
make_repo_channel
INIT_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before release"
channel_tag_here "v0.1.0"
git -C "$CHECKOUT_DIR" tag "v9.9.9"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$INIT_SHA"
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1)
assert_contains "stray local tag: resolves to the origin tag, not the local-only one" "behind stable v0.1.0" "$out"
case "$out" in
    *v9.9.9*) fail=$((fail + 1)); echo "  FAIL: stray local tag: v9.9.9 must not appear in --check output" ;;
    *) pass=$((pass + 1)); echo "  PASS: stray local tag: v9.9.9 must not appear in --check output" ;;
esac
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "stray local tag: apply rc 0" "0" "$rc"
landed=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
expected=$(git -C "$CHECKOUT_DIR" rev-parse "refs/tags/v0.1.0^{commit}")
assert_eq "stray local tag: HEAD lands on the origin tag's commit, not v9.9.9" "$expected" "$landed"

# ─── Test 21 (HIMMEL-2705 codex-2, round 6): an ANNOTATED release tag ────────
# resolves to its target COMMIT, not its own tag-object id — the narrowed
# `git ls-remote --tags origin "$want"` query never returns the peeled
# `^{}` entry on its own, so the unpeeled tag-object id never string-equals
# `git rev-parse HEAD` even once HEAD is genuinely at the release, and
# merge-base peels both sides to the same commit in EITHER direction —
# so the mismatch used to be misreported as "HEAD ahead", not "already at".
echo "Test 21: an ANNOTATED release tag resolves to its commit, not its tag-object id"
make_repo_channel
INIT_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before annotated release"
channel_annotated_tag_here "v0.1.0"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$INIT_SHA"
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1)
assert_contains "annotated tag: --check reports behind" "behind stable v0.1.0" "$out"
rc=0
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only pull 2>&1) || rc=$?
assert_eq "annotated tag: apply rc 0" "0" "$rc"
landed=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
expected=$(git -C "$CHECKOUT_DIR" rev-parse "refs/tags/v0.1.0^{commit}")
assert_eq "annotated tag: HEAD lands on the peeled commit" "$expected" "$landed"
out=$(HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1)
assert_contains "annotated tag: second check reports up to date, not 'ahead'" "up to date — at stable v0.1.0" "$out"

# ─── Test 22 (HIMMEL-2705 codex-1, round 6): an origin `ls-remote` failure ───
# AFTER `git fetch --tags origin` already succeeded fails loud, instead of
# being silently swallowed by a process-substitution loop into an empty
# candidate list indistinguishable from "no release on this channel yet".
echo "Test 22: origin ls-remote failure (network blip after fetch succeeds) fails loud, not 'no release yet'"
make_repo_channel
INIT_SHA=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
channel_commit "work before release"
channel_tag_here "v0.1.0"
git -C "$CHECKOUT_DIR" reset --quiet --hard "$INIT_SHA"
REAL_GIT=$(command -v git)
LSREMOTE_FAIL_BIN="$TMP/th22-git-shim"
mkdir -p "$LSREMOTE_FAIL_BIN"
cat > "$LSREMOTE_FAIL_BIN/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "ls-remote" ]; then
    exit 1
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$LSREMOTE_FAIL_BIN/git"
rc=0
out=$(PATH="$LSREMOTE_FAIL_BIN:$PATH" HIMMEL_UPDATE_CHANNEL=stable bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "ls-remote failure: --check fails loud (rc 1)" "1" "$rc"
assert_contains "ls-remote failure: names the query failure" "could not query origin" "$out"
case "$out" in
    *"no stable release yet"*) fail=$((fail + 1)); echo "  FAIL: ls-remote failure: must not be misreported as 'no stable release yet'" ;;
    *) pass=$((pass + 1)); echo "  PASS: ls-remote failure: must not be misreported as 'no stable release yet'" ;;
esac

# ─── Test 23 (HIMMEL-3101): an uninspectable repo must NOT be pulled ────────
# is_dirty_tracked() returning "clean" on a `git status` it could not even run
# would let the pull gate below wave a repo it never actually inspected
# through to `git pull --ff-only` — the exact silent-mix-in failure the dirty
# guard exists to prevent. A PATH-stub intercepts ONLY the is_dirty_tracked
# call shape (`status --porcelain --untracked-files=no`) and fails it; every
# other git subcommand (fetch, rev-parse, pull, ...) passes through to the
# real binary so the rest of the chain runs normally.
echo "Test 23: git status failure inside is_dirty_tracked fails safe — refuses to pull, not silently proceeds"
make_repo_behind 0
REAL_GIT=$(command -v git)
TH23_STUB="$TMP/th23-git-stub"
mkdir -p "$TH23_STUB"
cat > "$TH23_STUB/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "status" ] && [ "\$4" = "--porcelain" ] && [ "\$5" = "--untracked-files=no" ]; then
    exit 128
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TH23_STUB/git"
# Precondition: the stub is the git actually resolved on this PATH.
resolved_git=$(PATH="$TH23_STUB:$PATH" command -v git)
assert_eq "git-status-fails: stub is the git resolved on PATH" "$TH23_STUB/git" "$resolved_git"
head_before=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
# The guard should refuse BEFORE the chain ever reaches marketplace/hermes, but
# sandbox anyway (same shape as Test 7 Case b) so a regression that lets the
# chain run doesn't fall through to the real ~/.hermes checkout or the real
# `claude` marketplace registry.
th23_home="$TMP/th23-home"; mkdir -p "$th23_home/.claude"
rc=0
out=$(PATH="$TH23_STUB:$PATH" USERPROFILE='' HOME="$th23_home" \
      HERMES_HOME="$TMP/th23-no-hermes" CLAUDE_USER_SETTINGS="$th23_home/.claude/settings.json" \
      CLAUDE_CONFIG_DIR="$TMP/th23-no-claude-config" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "git-status-fails: refuses (rc 1), not a silent pass-through" "1" "$rc"
assert_contains "git-status-fails: warns on stderr naming the dir" "is_dirty_tracked: git status failed in $CHECKOUT_DIR" "$out"
assert_contains "git-status-fails: refuses to pull into a dirty tree" "refusing to pull into a dirty tree" "$out"
head_after=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
assert_eq "git-status-fails: HEAD unchanged — never pulled" "$head_before" "$head_after"
# ─── Non-git install (HIMMEL-3247, P1 of HIMMEL-3059) ────────────────────────
# A tarball / native-package install has no .git, so `git pull` has nothing to
# pull. himmel-update.sh must either update it or REFUSE with an accurate message
# naming the packaged route — never a silent no-op, and never a `git pull` aimed
# at whatever repo happens to enclose the install dir. The install root is a
# COPY of the script + its libs in a .git-less prefix; the network is a PATH
# `curl` stub (a suite must never hit the live releases API).
NG_STUB="$TMP/ng-stubbin"; mkdir -p "$NG_STUB"
cat > "$NG_STUB/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CURL_LOG:-/dev/null}"
case "${STUB_CURL_MODE:-ok}" in
    ok)       printf '{\n  "tag_name": "%s"\n}\n200' "${STUB_CURL_TAG:-v9.9.9}" ;;
    notfound) printf '{"message":"Not Found"}\n404' ;;
    ratelim)  printf '{"message":"API rate limit exceeded"}\n403' ;;
    netfail)  exit 6 ;;
esac
STUB
chmod +x "$NG_STUB/curl"

_ng_counter=0
# make_nongit_install <version|""> [parent-dir] — sets NG (install root) and NGS (script).
make_nongit_install() {
    _ng_counter=$((_ng_counter + 1))
    NG="${2:-$TMP/ng_$_ng_counter}"
    mkdir -p "$NG/scripts"
    cp "$SCRIPT" "$NG/scripts/himmel-update.sh"
    cp -R "$(dirname "$SCRIPT")/guardrails" "$NG/scripts/guardrails"
    cp -R "$(dirname "$SCRIPT")/lib" "$NG/scripts/lib"
    [ -z "$1" ] || printf '%s\n' "$1" > "$NG/VERSION"
    NGS="$NG/scripts/himmel-update.sh"
}
# run_ng [ENV=val ...] -- args... — the copied script with curl stubbed. Sets rc.
run_ng() {
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    rc=0
    out=$(env PATH="$NG_STUB:$PATH" ${envs[@]+"${envs[@]}"} bash "$NGS" "$@" 2>&1) || rc=$?
}

echo "Test 24: non-git --check, newer release published → says so, names the packaged route, exits 0"
make_nongit_install "0.3.0"
NGLOG="$TMP/ng24.log"; : > "$NGLOG"
run_ng STUB_CURL_LOG="$NGLOG" STUB_CURL_TAG=v0.4.0 -- --check
assert_eq "non-git --check newer: rc 0" "0" "$rc"
assert_contains "non-git --check newer: names the installed version" "0\.3\.0" "$out"
assert_contains "non-git --check newer: names the latest release" "v0\.4\.0" "$out"
assert_contains "non-git --check newer: says it is not a git checkout" "not a git checkout" "$out"
assert_contains "non-git --check newer: names the pacman route" "pacman -Syu himmel" "$out"
assert_contains "non-git --check newer: names the tarball route" "tarball" "$out"
assert_contains "non-git --check newer: asked only the fixed releases URL" "https://api.github.com/repos/yotamleo/Himmel/releases/latest" "$(cat "$NGLOG")"
if grepq "$out" "up to date"; then assert_fail "non-git --check newer: must not say 'up to date'"; else assert_pass "non-git --check newer: does not say 'up to date'"; fi

echo "Test 25: non-git --check, already on the latest release → up to date"
make_nongit_install "0.4.0"
run_ng STUB_CURL_TAG=v0.4.0 -- --dry-run
assert_eq "non-git --dry-run current: rc 0" "0" "$rc"
assert_contains "non-git --dry-run current: reports up to date" "up to date" "$out"

echo "Test 26: non-git --check, the release check FAILED → distinguishable from 'up to date', still exit 0"
for mode in netfail ratelim; do
    make_nongit_install "0.3.0"
    run_ng STUB_CURL_MODE=$mode -- --check
    assert_eq "non-git --check $mode: rc 0 (non-blocking)" "0" "$rc"
    assert_contains "non-git --check $mode: says the check could not run" "could not check" "$out"
    if grepq "$out" "up to date"; then assert_fail "non-git --check $mode: a failed check must NOT read as 'up to date'"; else assert_pass "non-git --check $mode: a failed check does not read as 'up to date'"; fi
done
make_nongit_install "0.3.0"; run_ng STUB_CURL_MODE=netfail -- --check
assert_contains "non-git --check netfail: names the reason" "network" "$out"
make_nongit_install "0.3.0"; run_ng STUB_CURL_MODE=ratelim -- --check
assert_contains "non-git --check ratelim: names the reason" "http-403" "$out"
make_nongit_install "0.3.0"; run_ng STUB_CURL_MODE=notfound -- --check
assert_contains "non-git --check 404: says no release is published (definite answer)" "no release" "$out"
make_nongit_install ""; run_ng STUB_CURL_TAG=v0.4.0 -- --check
assert_eq "non-git --check, no VERSION file: rc 0" "0" "$rc"
assert_contains "non-git --check, no VERSION file: says so" "VERSION" "$out"

echo "Test 27: non-git real update / --only pull → refuse (rc 1), name both routes, touch no network"
for args in "" "--only pull"; do
    make_nongit_install "0.3.0"
    NGLOG="$TMP/ng27.log"; : > "$NGLOG"
    # shellcheck disable=SC2086  # $args is a fixed literal, intentionally split
    run_ng STUB_CURL_LOG="$NGLOG" STUB_CURL_TAG=v0.4.0 -- $args
    assert_eq "non-git update '$args': refuses (rc 1)" "1" "$rc"
    assert_contains "non-git update '$args': says it is not a git checkout" "not a git checkout" "$out"
    assert_contains "non-git update '$args': names the pacman route" "pacman -Syu himmel" "$out"
    assert_contains "non-git update '$args': names the tarball route" "tarball" "$out"
    assert_eq "non-git update '$args': refusal made no network call" "0" "$(wc -l < "$NGLOG" | tr -d ' ')"
    if grepq "$out" "git pull"; then assert_fail "non-git update '$args': must not run or advertise a git pull"; else assert_pass "non-git update '$args': no git pull"; fi
done

echo "Test 28: non-git install NESTED inside another git repo never pulls the enclosing repo"
make_repo_behind 1
PARENT_BEFORE=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
make_nongit_install "0.3.0" "$CHECKOUT_DIR/vendor/himmel"
run_ng -- --only pull
assert_eq "nested --only pull: refuses (rc 1)" "1" "$rc"
run_ng --
assert_eq "nested full update: refuses (rc 1)" "1" "$rc"
assert_eq "nested: the enclosing repo's HEAD did not move" "$PARENT_BEFORE" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"

echo "Test 29: the git-checkout path is unchanged (and never talks about a non-git install)"
make_repo_behind 1
rc=0
out=$(bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_eq "git checkout --check: rc 0" "0" "$rc"
assert_contains "git checkout --check: still reports the behind count" "behind:   1" "$out"
if grepq "$out" "not a git checkout"; then assert_fail "git checkout --check: must not claim to be a non-git install"; else assert_pass "git checkout --check: no non-git wording"; fi
make_nongit_install "0.3.0"
run_ng -- --plugins-check
assert_eq "non-git --plugins-check: still exits 0 (no git needed)" "0" "$rc"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
