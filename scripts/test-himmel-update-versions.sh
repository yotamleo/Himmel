#!/usr/bin/env bash
# test-himmel-update-versions.sh — hermetic tests for HIMMEL-3400: the read-only
# `himmel-update.sh --versions` ecosystem report, and the `--help` / unknown-flag
# contract (before this ticket `--help` fell through to a REAL update).
#
# Same mock-clone technique as test-himmel-update-chain.sh: himmel-update.sh
# resolves its own repo root from BASH_SOURCE, so it is copied into a throwaway
# clone (with a local bare upstream) and run from there. Every external tool is
# a fixture (claude stub that LOGS every call, stub upgrade.sh, stub qmd-bin.sh,
# a fake cli-proxy stamp, a NousResearch-named local hermes checkout) — the
# real update chain is never run against the station.
#
# Covers:
#   1. --help / -h print usage, exit 0, run NOTHING (claude stub never called).
#   2. an unknown flag refuses (rc 2) instead of running the update.
#   3. --versions with every component behind: one row per component with
#      installed vs available, rc 1, and the repo/HOME/stub log are untouched.
#   4. --versions with everything current: rc 0.
#   5. --versions offline (origin unreachable): himmel reads `unknown`, the
#      other rows still print, rc 3 (undetermined is not "proved current").
#
# Bash 3.2 compatible.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-versions.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    if grepq "$3" "$2"; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got: $3"; fi
}
assert_not_contains() {
    local rc=0
    grepq "$3" "$2" || rc=$?
    if [ "$rc" -eq 0 ]; then
        assert_fail "$1 — did NOT expect '$2', got: $3"
    elif [ "$rc" -eq 1 ]; then
        assert_pass "$1"
    else
        assert_fail "$1 — grep errored (status $rc) evaluating '$2' against: $3"
    fi
}
assert_eq() {
    if [ "$2" = "$3" ]; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got '$3'"; fi
}

# Self-test: assert_not_contains must FAIL a grep error (status >= 2, e.g. an
# invalid pattern), not treat it as a passing "no match" (status 1). Runs in
# isolated counters so it never skews the suite's own pass/fail totals.
echo "Test 0: assert_not_contains distinguishes grep no-match from grep error"
_outer_pass=$pass; _outer_fail=$fail
pass=0; fail=0
assert_not_contains "self-test: genuine no-match is a pass" "nomatch" "hello world"
if [ "$pass" -ne 1 ] || [ "$fail" -ne 0 ]; then
    echo "FAIL: assert_not_contains mishandled a genuine no-match (pass=$pass fail=$fail)" >&2
    exit 1
fi
pass=0; fail=0
assert_not_contains "self-test: an invalid regex (grep error) must FAIL" "[" "hello world"
if [ "$fail" -ne 1 ] || [ "$pass" -ne 0 ]; then
    echo "FAIL: assert_not_contains treated a grep error (invalid regex) as a pass" >&2
    exit 1
fi
pass=$_outer_pass; fail=$_outer_fail
assert_pass "assert_not_contains: grep-status split (self-test)"

_repo_counter=0

# make_mock_clone — bare upstream + a clone carrying himmel-update.sh (+ the
# libs it sources), scaffolding COMMITTED so the tree starts clean.
# Sets CHECKOUT_DIR and UPSTREAM_BARE.
make_mock_clone() {
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${_repo_counter}"
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
    git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true
    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    local src_scripts; src_scripts="$(dirname "$SCRIPT")"
    cp "$src_scripts/guardrails/lib.sh"        "$clone/scripts/guardrails/lib.sh"
    cp "$src_scripts/lib/cadence-format.sh"    "$clone/scripts/lib/cadence-format.sh"
    cp "$src_scripts/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$src_scripts/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
    CHECKOUT_DIR="$clone"
    UPSTREAM_BARE="$bare"
}

commit_scaffold() { git -C "$CHECKOUT_DIR" add -A; git -C "$CHECKOUT_DIR" commit --quiet -m "scaffold"; }

# A `claude` stub that APPENDS every invocation to a log — the read-only
# assertions check the log stays empty.
make_claude_stub() {   # <path> <log>
    printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$2" > "$1"
    chmod +x "$1"
}

# A stub luna upgrade.sh: `--check` prints upgrade.sh's own one-line contract.
make_luna_fixture() {   # <template-version> <vault-version>
    mkdir -p "$CHECKOUT_DIR/templates/luna-second-brain/scripts" "$TMP/vault"
    cat > "$CHECKOUT_DIR/templates/luna-second-brain/scripts/upgrade.sh" <<EOF
#!/usr/bin/env bash
if [ "$1" = "$2" ]; then
    echo "luna-second-brain: vault is current (v$2)."
else
    echo "luna-second-brain: template v$1 available (vault is v$2). Run: bash scripts/upgrade.sh (or /luna-upgrade)."
fi
exit 0
EOF
}
# (the heredoc above expands \$1/\$2 at WRITE time — the two versions are baked in)

run_update() {   # <fake-home> <claude-stub> args...
    local fh="$1" cl="$2"; shift 2
    USERPROFILE='' HOME="$fh" HIMMEL_UPDATE_CLAUDE_BIN="$cl" HERMES_HOME="$TMP/no-hermes" \
        HIMMEL_UPDATE_AUTOSTASH='' CLAUDE_USER_SETTINGS="$fh/.claude/settings.json" \
        LUNA_VAULT_PATH="${LUNA_VAULT_PATH:-}" \
        bash "$CHECKOUT_DIR/scripts/himmel-update.sh" "$@" 2>&1
}

# ─── 1 + 2: --help / -h / unknown flag run NOTHING ───────────────────────────
echo "Test 1: --help / -h print usage, exit 0, run nothing"
make_mock_clone; commit_scaffold
fh="$TMP/home-help"; mkdir -p "$fh"
log1="$TMP/claude-help.log"; : > "$log1"; make_claude_stub "$TMP/claude-help" "$log1"
head_before=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
for flag in --help -h; do
    rc=0; out=$(run_update "$fh" "$TMP/claude-help" "$flag") || rc=$?
    assert_eq "$flag: rc 0" "0" "$rc"
    assert_contains "$flag: prints usage" "[Uu]sage" "$out"
    assert_contains "$flag: documents --versions" "[-]-versions" "$out"
    assert_not_contains "$flag: never reached the chain" "\\[1/6\\]" "$out"
    assert_not_contains "$flag: no status table" "update chain status" "$out"
done
assert_eq "--help: claude stub never invoked" "" "$(cat "$log1")"
assert_eq "--help: HEAD unchanged" "$head_before" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"

echo "Test 2: an unknown flag refuses instead of running the update"
for flag in --bogus --versoins foo; do
    rc=0; out=$(run_update "$fh" "$TMP/claude-help" "$flag") || rc=$?
    assert_eq "$flag: rc 2" "2" "$rc"
    assert_contains "$flag: names the unknown flag" "unknown.*$flag" "$out"
    assert_not_contains "$flag: never reached the chain" "\\[1/6\\]" "$out"
done
assert_eq "unknown flag: claude stub never invoked" "" "$(cat "$log1")"

# ─── 3: --versions, every component behind ───────────────────────────────────
echo "Test 3: --versions with components behind -> rows, rc 1, nothing mutated"
make_mock_clone
# jira CLI: source newer than the built dist -> behind
mkdir -p "$CHECKOUT_DIR/scripts/jira/src" "$CHECKOUT_DIR/scripts/jira/dist"
printf '{"name":"jira"}\n' > "$CHECKOUT_DIR/scripts/jira/package.json"
printf 'x\n' > "$CHECKOUT_DIR/scripts/jira/src/index.ts"
# toolchain: a pin far above any real node
printf '999\n' > "$CHECKOUT_DIR/.nvmrc"
# cli-proxy: both twins carry the pin (the script picks by pwsh availability)
mkdir -p "$CHECKOUT_DIR/scripts/setup"
printf 'VERSION="1.2.3"\n' > "$CHECKOUT_DIR/scripts/setup/cli-proxy-lane.sh"
printf "\$Version = '1.2.3'\n" > "$CHECKOUT_DIR/scripts/setup/cli-proxy-lane.ps1"
# qmd fork: a stub qmd-bin.sh that is NOT served
cat > "$CHECKOUT_DIR/scripts/lib/qmd-bin.sh" <<'EOF'
qmd_fork_served() { return 1; }
qmd_cmd() { echo "qmd 1.0.0"; }
_qmd_fork_ref() { printf '%s\n' "abcdef1234567890"; }
EOF
make_luna_fixture "0.4.47" "0.4.30"
commit_scaffold
touch -d '2020-01-01 00:00:00' "$CHECKOUT_DIR/scripts/jira/dist/index.js" 2>/dev/null || { : > "$CHECKOUT_DIR/scripts/jira/dist/index.js"; touch -d '2020-01-01 00:00:00' "$CHECKOUT_DIR/scripts/jira/dist/index.js"; }
# hermes: a NousResearch-named local checkout whose upstream advanced
hb="$TMP/NousResearch/hermes-agent.git"; mkdir -p "$hb"; git init --bare --quiet "$hb"
hseed="$TMP/hermes-seed"; git clone --quiet "$hb" "$hseed" 2>/dev/null
git -C "$hseed" config user.email t@t.t; git -C "$hseed" config user.name T
printf 'a\n' > "$hseed/a"; git -C "$hseed" add a; git -C "$hseed" commit --quiet -m one
hdef=$(git -C "$hseed" rev-parse --abbrev-ref HEAD); git -C "$hseed" push --quiet origin "HEAD:$hdef" 2>/dev/null
mkdir -p "$TMP/hermes-home"; git clone --quiet "$hb" "$TMP/hermes-home/hermes-agent" 2>/dev/null
printf 'b\n' > "$hseed/b"; git -C "$hseed" add b; git -C "$hseed" commit --quiet -m two
git -C "$hseed" push --quiet origin "HEAD:$hdef" 2>/dev/null
# himmel checkout: upstream advanced
seed2="$TMP/himmel-seed"; git clone --quiet "$UPSTREAM_BARE" "$seed2" 2>/dev/null
git -C "$seed2" config user.email t@t.t; git -C "$seed2" config user.name T
printf 'new\n' > "$seed2/new.txt"; git -C "$seed2" add new.txt; git -C "$seed2" commit --quiet -m "upstream advance"
git -C "$seed2" push --quiet origin "HEAD:$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD)" 2>/dev/null
# cli-proxy stamp older than the pin
fh3="$TMP/home-versions"; mkdir -p "$fh3/.cli-proxy-api"; printf '1.2.0\n' > "$fh3/.cli-proxy-api/cli-proxy-api.version"
log3="$TMP/claude-versions.log"; : > "$log3"; make_claude_stub "$TMP/claude-versions" "$log3"
export LUNA_VAULT_PATH="$TMP/vault"

before_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
before_status=$(git -C "$CHECKOUT_DIR" status --porcelain --ignore-submodules)
before_home=$(find "$fh3" \( -type f -exec cksum {} \; -o -type d -print \) 2>/dev/null | sort)
before_hermes=$(git -C "$TMP/hermes-home/hermes-agent" rev-parse HEAD)
rc=0
out=$(USERPROFILE='' HOME="$fh3" HIMMEL_UPDATE_CLAUDE_BIN="$TMP/claude-versions" \
      HERMES_HOME="$TMP/hermes-home" HIMMEL_UPDATE_AUTOSTASH='' CLAUDE_USER_SETTINGS="$fh3/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --versions 2>&1) || rc=$?
# shellcheck disable=SC2001  # indent every line; a ${//} rewrite reads worse
echo "$out" | sed 's/^/    | /'
assert_eq "versions: rc 1 (something is behind)" "1" "$rc"
assert_contains "versions: header" "ecosystem versions" "$out"
assert_contains "versions: himmel row is behind" "^ *himmel  *behind" "$out"
assert_contains "versions: jira_cli row is behind" "^ *jira_cli  *behind" "$out"
assert_contains "versions: qmd_fork row is behind, names the pin" "^ *qmd_fork  *behind .*abcdef1" "$out"
assert_contains "versions: hermes row is behind" "^ *hermes  *behind" "$out"
assert_contains "versions: luna_template installed vs available" "^ *luna_template  *behind  *v0\\.4\\.30  *v0\\.4\\.47" "$out"
assert_contains "versions: cli_proxy installed vs pin" "^ *cli_proxy  *behind  *v\\?1\\.2\\.0  *v\\?1\\.2\\.3" "$out"
assert_contains "versions: node behind the .nvmrc pin" "^ *node  *behind .*999" "$out"
assert_contains "versions: npm row present" "^ *npm " "$out"
assert_contains "versions: bun row present" "^ *bun " "$out"
assert_contains "versions: plugins row present" "^ *plugins " "$out"
assert_not_contains "versions: not the chain" "\\[1/6\\]" "$out"
assert_eq "versions: claude stub never invoked" "" "$(cat "$log3")"
assert_eq "versions: himmel HEAD unchanged (no pull)" "$before_head" "$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
assert_eq "versions: himmel tree unchanged" "$before_status" "$(git -C "$CHECKOUT_DIR" status --porcelain --ignore-submodules)"
assert_eq "versions: fake HOME unchanged" "$before_home" "$(find "$fh3" \( -type f -exec cksum {} \; -o -type d -print \) 2>/dev/null | sort)"
assert_eq "versions: hermes checkout unchanged (no pull)" "$before_hermes" "$(git -C "$TMP/hermes-home/hermes-agent" rev-parse HEAD)"

# ─── 4: everything current -> rc 0 ───────────────────────────────────────────
echo "Test 4: --versions with everything current -> rc 0"
make_mock_clone
make_luna_fixture "0.4.47" "0.4.47"
commit_scaffold
fh4="$TMP/home-current"; mkdir -p "$fh4"
rc=0
out=$(LUNA_VAULT_PATH="$TMP/vault" run_update "$fh4" "$TMP/claude-versions" --versions) || rc=$?
assert_eq "current: rc 0" "0" "$rc"
assert_contains "current: himmel current" "^ *himmel  *current" "$out"
assert_contains "current: luna_template current" "^ *luna_template  *current  *v0\\.4\\.47" "$out"
assert_not_contains "current: nothing marked behind" "  behind " "$out"

# ─── 5: offline -> himmel unknown, others still print, rc 3 ──────────────────
echo "Test 5: --versions offline -> himmel unknown, rows still print, rc 3"
make_mock_clone
make_luna_fixture "0.4.47" "0.4.47"
commit_scaffold
git -C "$CHECKOUT_DIR" remote set-url origin "$TMP/does-not-exist.git"
fh5="$TMP/home-offline"; mkdir -p "$fh5"
rc=0
out=$(LUNA_VAULT_PATH="$TMP/vault" run_update "$fh5" "$TMP/claude-versions" --versions) || rc=$?
assert_eq "offline: rc 3" "3" "$rc"
assert_contains "offline: himmel unknown" "^ *himmel  *unknown" "$out"
assert_contains "offline: luna row still printed" "^ *luna_template  *current" "$out"

# ─── 6: plugins row — installed @himmel plugin vs marketplace source ─────────
echo "Test 6: --versions plugins row: current, version drift, not installed"
make_mock_clone
mkdir -p "$CHECKOUT_DIR/marketplace/plugins/alpha/.claude-plugin"
printf '{"name":"alpha","version":"2.0.0"}\n' > "$CHECKOUT_DIR/marketplace/plugins/alpha/.claude-plugin/plugin.json"
printf '{"name":"himmel","plugins":[{"name":"alpha"}]}\n' > "$TMP/market.json"
commit_scaffold
fh6="$TMP/home-plugins"; mkdir -p "$fh6"
plugins_row() {   # <installed-version|""> -> the --versions output
    if [ -n "$1" ]; then
        printf '{"plugins":{"alpha@himmel":[{"version":"%s"}]}}\n' "$1" > "$TMP/installed.json"
    else
        printf '{"plugins":{}}\n' > "$TMP/installed.json"
    fi
    rc=0
    HIMMEL_MARKETPLACE_JSON="$TMP/market.json" HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed.json" \
        LUNA_VAULT_PATH="$TMP/vault" run_update "$fh6" "$TMP/claude-versions" --versions || rc=$?
}
out=$(plugins_row "2.0.0") || true
assert_contains "plugins: installed = source -> current" "^ *plugins  *current  *1/1 installed" "$out"
out=$(plugins_row "1.0.0") || true
assert_contains "plugins: older installed copy -> behind, names the drift" "^ *plugins  *behind .*alpha(1\\.0\\.0->2\\.0\\.0)" "$out"
out=$(plugins_row "") || true
assert_contains "plugins: declared but not installed -> behind" "^ *plugins  *behind  *0/1 installed" "$out"

# HIMMEL-3416: an unreadable installed OR source version must report unknown,
# never claim "current" (version equality was never established).
printf '{"plugins":{"alpha@himmel":[{}]}}\n' > "$TMP/installed-noiv.json"
rc=0
out=$(HIMMEL_MARKETPLACE_JSON="$TMP/market.json" HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed-noiv.json" \
    LUNA_VAULT_PATH="$TMP/vault" run_update "$fh6" "$TMP/claude-versions" --versions) || rc=$?
assert_eq "plugins: unreadable installed version -> rc 3" "3" "$rc"
assert_contains "plugins: unreadable installed version -> unknown, not current" "^ *plugins  *unknown" "$out"
assert_not_contains "plugins: unreadable installed version -> never current" "^ *plugins  *current" "$out"

mkdir -p "$CHECKOUT_DIR/marketplace/plugins/beta/.claude-plugin"
printf '{"name":"beta"}\n' > "$CHECKOUT_DIR/marketplace/plugins/beta/.claude-plugin/plugin.json"
printf '{"name":"himmel","plugins":[{"name":"beta"}]}\n' > "$TMP/market-beta.json"
printf '{"plugins":{"beta@himmel":[{"version":"1.0.0"}]}}\n' > "$TMP/installed-nosv.json"
rc=0
out=$(HIMMEL_MARKETPLACE_JSON="$TMP/market-beta.json" HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed-nosv.json" \
    LUNA_VAULT_PATH="$TMP/vault" run_update "$fh6" "$TMP/claude-versions" --versions) || rc=$?
assert_eq "plugins: unreadable source version -> rc 3" "3" "$rc"
assert_contains "plugins: unreadable source version -> unknown, not current" "^ *plugins  *unknown" "$out"
assert_not_contains "plugins: unreadable source version -> never current" "^ *plugins  *current" "$out"

# ─── 7: release channel — the himmel row follows the tag, not the upstream ────
echo "Test 7: --versions with HIMMEL_UPDATE_CHANNEL follows release tags"
make_mock_clone
make_luna_fixture "0.4.47" "0.4.47"
commit_scaffold
git -C "$CHECKOUT_DIR" push --quiet origin "HEAD:$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD)" 2>/dev/null
git -C "$CHECKOUT_DIR" tag v9.9.9
git -C "$CHECKOUT_DIR" push --quiet origin v9.9.9 2>/dev/null
fh7="$TMP/home-channel"; mkdir -p "$fh7"
rc=0; out=$(HIMMEL_UPDATE_CHANNEL=stable LUNA_VAULT_PATH="$TMP/vault" run_update "$fh7" "$TMP/claude-versions" --versions) || rc=$?
assert_contains "channel: at the latest tag -> current, names the tag" "^ *himmel  *current .*v9\\.9\\.9" "$out"
seed7="$TMP/himmel-seed7"; git clone --quiet "$UPSTREAM_BARE" "$seed7" 2>/dev/null
git -C "$seed7" config user.email t@t.t; git -C "$seed7" config user.name T
printf 'next\n' > "$seed7/next.txt"; git -C "$seed7" add next.txt; git -C "$seed7" commit --quiet -m "next release"
git -C "$seed7" tag v9.9.10; git -C "$seed7" push --quiet origin v9.9.10 2>/dev/null
rc=0; out=$(HIMMEL_UPDATE_CHANNEL=stable LUNA_VAULT_PATH="$TMP/vault" run_update "$fh7" "$TMP/claude-versions" --versions) || rc=$?
assert_eq "channel: a newer tag -> rc 1" "1" "$rc"
assert_contains "channel: behind the newer tag" "^ *himmel  *behind .*v9\\.9\\.10" "$out"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
