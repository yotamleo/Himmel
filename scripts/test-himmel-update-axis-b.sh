#!/usr/bin/env bash
# test-himmel-update-axis-b.sh — hermetic tests for the machine-local ("Axis B")
# catch-up steps added to scripts/himmel-update.sh by HIMMEL-2134:
# the --only single-step mode, the cli-proxy-api host roll, the installed-
# marketplaces catch-up, and the qmd daemon-restart notice.
#
# Same mock-clone technique as test-himmel-update-chain.sh (himmel-update.sh
# resolves its own repo root via BASH_SOURCE/.. and cd's there, so it is tested
# by copying it into a throwaway clone and running it from inside that clone),
# with the scaffolding COMMITTED so the working tree starts clean.
#
# Fully offline and non-mutating: no real claude CLI (HIMMEL_UPDATE_CLAUDE_BIN
# stub), no real pwsh invocation (every cli-proxy case asserts on --check, which
# compares versions and shells out to nothing), no real marketplace, no real
# cli-proxy install, and a fake HOME with USERPROFILE cleared so the version
# stamp is read from the fixture rather than the developer machine.
#
# Covers:
#   1. --only rejects a missing / unknown item with rc 2 and names the items.
#   2. --only <item> runs THAT step and NOT the chain (no "[1/6]" header),
#      still printing the status table.
#   3. --only pull honours the dirty-tree pre-check.
#   4. cli-proxy roll: absent lane script -> skip; stamp == pin -> up-to-date;
#      stamp != pin -> reported BEHIND in check mode and rolls nothing.
#   5. cli-proxy roll: no install on this machine (no version stamp) -> skip
#      with the operator's first-install command, never a phantom roll.
#   6. marketplaces catch-up: --check lists the manual-tier rows and invokes
#      the claude stub ZERO times.
#   7. cli-proxy roll (HIMMEL-2152): APPLY mode (--only cli_proxy) completes
#      instead of errexiting on an ahead host or an uncomparable stamp, and
#      later steps still run.
#
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
SRC_SCRIPTS="$(dirname "$SCRIPT")"

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

# grepq — `grep -q` with NO pipeline (pipefail + SIGPIPE would report a
# SUCCESSFUL early match as a failed pipeline; HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then assert_pass "$desc"
    else assert_fail "$desc — expected '$pattern', got: $actual"; fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_fail "$desc — did NOT expect '$pattern', got: $actual"
    else assert_pass "$desc"; fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then assert_pass "$desc"
    else assert_fail "$desc — expected '$expected', got '$actual'"; fi
}

_repo_counter=0

# Build a mock upstream bare repo + a clone carrying himmel-update.sh and the
# libs it sources, all COMMITTED so the tree starts clean. Sets CHECKOUT_DIR.
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
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib" "$clone/scripts/upstreams"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    cp "$SRC_SCRIPTS/guardrails/lib.sh"        "$clone/scripts/guardrails/lib.sh"
    cp "$SRC_SCRIPTS/lib/cadence-format.sh"    "$clone/scripts/lib/cadence-format.sh"
    cp "$SRC_SCRIPTS/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$SRC_SCRIPTS/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
    cp "$SRC_SCRIPTS/upstreams/update-marketplaces.sh" "$clone/scripts/upstreams/update-marketplaces.sh"
    git -C "$clone" add -A
    git -C "$clone" commit --quiet -m "scaffold"
    CHECKOUT_DIR="$clone"
}

# A fake cli-proxy-lane.ps1 carrying ONLY the $Version pin literal the roll step
# greps for. Never executed by any case below (every cli-proxy assertion is on
# --check, which compares versions and shells out to nothing).
write_fake_lane() {   # <clone> <version>
    mkdir -p "$1/scripts/setup"
    # SC2016: the literal `$Version` is the POINT — it is the PowerShell pin
    # literal the roll step greps for, not a shell expansion.
    # shellcheck disable=SC2016
    printf '$Version = %s%s%s\n' "'" "$2" "'" > "$1/scripts/setup/cli-proxy-lane.ps1"
    git -C "$1" add -A
    git -C "$1" commit --quiet -m "fake lane"
}

make_claude_stub() {   # <path> <exit-code> [call-log]
    if [ -n "${3:-}" ]; then
        # SC2016: `$4` must reach the GENERATED stub verbatim — expanding it
        # here would bake this shell's own $4 into the stub.
        # shellcheck disable=SC2016
        printf '#!/bin/sh\necho "$4" >> "%s"\nexit %s\n' "$3" "$2" > "$1"
    else
        printf '#!/bin/sh\nexit %s\n' "$2" > "$1"
    fi
    chmod +x "$1"
}

# Run himmel-update.sh in the mock clone under a fake HOME. Extra env is passed
# through the caller's own `env` prefix via RUN_ENV (space-separated K=V).
run_update() {   # <clone> <fake-home> <claude-stub> [args...]
    local clone="$1" fh="$2" stub="$3"; shift 3
    mkdir -p "$fh"
    USERPROFILE='' HOME="$fh" \
    HIMMEL_UPDATE_CLAUDE_BIN="$stub" \
    HERMES_HOME="$TMP/no-hermes" \
    HIMMEL_UPDATE_AUTOSTASH='' \
    DRIFT_KNOWN_MARKETPLACES="${FIXTURE_MKTS:-$TMP/no-such-mkts.json}" \
    CLAUDE_USER_SETTINGS="$fh/.claude/settings.json" \
        bash "$clone/scripts/himmel-update.sh" "$@" 2>&1
}

echo "Test 1: --only argument validation"
make_mock_clone
CLONE1="$CHECKOUT_DIR"
STUB1="$TMP/claude1"; make_claude_stub "$STUB1" 0
FH1="$TMP/home1"
OUT="$(run_update "$CLONE1" "$FH1" "$STUB1" --only)"; RC=$?
assert_eq "--only with no item exits 2" "2" "$RC"
assert_contains "--only with no item names the valid items" "cli_proxy" "$OUT"
OUT="$(run_update "$CLONE1" "$FH1" "$STUB1" --only bogus-item)"; RC=$?
assert_eq "--only with an unknown item exits 2" "2" "$RC"
assert_contains "--only unknown item is named back" "bogus-item" "$OUT"

echo ""
echo "Test 2: --only <item> runs ONE step, not the chain"
OUT="$(run_update "$CLONE1" "$FH1" "$STUB1" --only marketplace)"; RC=$?
assert_eq "--only marketplace exits 0" "0" "$RC"
# EVERY selectable item must have its function defined ABOVE the dispatch. Two
# of the three advisory ones were moved there when --only was added and
# sync_graphify was missed, so `--only graphify` died with
# "sync_graphify: command not found" and exited 127 before the status table
# (CodeRabbit, PR #1928). Walk the whole list rather than spot-checking one:
# a spot check is what let this through the first time.
for _item in pull marketplace jira_cli qmd_fork hermes luna_template graphify cli_proxy marketplaces; do
    _o="$(run_update "$CLONE1" "$FH1" "$STUB1" --only "$_item")"; _r=$?
    assert_not_contains "--only $_item resolves its function" "command not found" "$_o"
    if [ "$_r" -eq 127 ]; then
        assert_fail "--only $_item exited 127 (unresolved function)"
    else
        assert_pass "--only $_item did not exit 127"
    fi
    assert_contains "--only $_item still prints the status table" "==> update chain status" "$_o"
done
assert_contains "--only marketplace ran the marketplace step" "marketplace  *updated" "$OUT"
# The whole point of --only: the dependency chain is NOT walked.
assert_not_contains "--only did NOT run the chain" "\\[1/6\\]" "$OUT"
assert_not_contains "--only did NOT run the jira dist rebuild" "\\[3/6\\]" "$OUT"
assert_contains "--only still prints the status table" "==> update chain status" "$OUT"

echo ""
echo "Test 3: --only pull honours the dirty-tree pre-check"
printf 'dirty\n' >> "$CLONE1/file.txt"
OUT="$(run_update "$CLONE1" "$FH1" "$STUB1" --only pull)"; RC=$?
assert_eq "--only pull on a dirty tree exits 1" "1" "$RC"
assert_contains "--only pull names the dirty tree" "refusing to pull into a dirty tree" "$OUT"
assert_contains "--only pull hints at the autostash opt-in" "HIMMEL_UPDATE_AUTOSTASH=1 to autostash" "$OUT"
git -C "$CLONE1" checkout --quiet -- file.txt

echo ""
echo "Test 3b: --only pull + HIMMEL_UPDATE_AUTOSTASH=1 autostashes and proceeds (HIMMEL-2152)"
printf 'dirty\n' >> "$CLONE1/file.txt"
OUT="$(USERPROFILE='' HOME="$FH1" HIMMEL_UPDATE_CLAUDE_BIN="$STUB1" HERMES_HOME="$TMP/no-hermes" \
      HIMMEL_UPDATE_AUTOSTASH=1 CLAUDE_USER_SETTINGS="$FH1/.claude/settings.json" \
      bash "$CLONE1/scripts/himmel-update.sh" --only pull 2>&1)"; RC=$?
assert_eq "--only pull + autostash exits 0" "0" "$RC"
assert_contains "--only pull + autostash prints the autostashing notice" "autostashing local changes" "$OUT"
assert_not_contains "--only pull + autostash does not refuse" "refusing to pull into a dirty tree" "$OUT"
# A no-op --autostash (e.g. `pull` alone, upstream not actually conflicting)
# would also print the notice and exit 0 — assert the reapply actually
# happened: the dirty content survived, the stash was popped (not left
# dangling), and the tree is still dirty with that same edit.
assert_contains "--only pull + autostash preserves the dirty edit's content" "dirty" "$(cat "$CLONE1/file.txt")"
assert_eq "--only pull + autostash leaves no stash behind" "" "$(git -C "$CLONE1" stash list)"
assert_contains "--only pull + autostash leaves the tree dirty with the restored edit" "file.txt" "$(git -C "$CLONE1" status --porcelain -- file.txt)"
# --autostash reapplies the dirty edit after the pull — reset so later tests
# reusing CLONE1 cannot depend on test order.
git -C "$CLONE1" checkout --quiet -- file.txt

echo ""
echo "Test 4: cli-proxy roll — absent lane script is a clean skip"
OUT="$(run_update "$CLONE1" "$FH1" "$STUB1" --check)"; RC=$?
assert_eq "--check exits 0 with no lane script" "0" "$RC"
assert_contains "absent lane script is reported as a skip" "cli-proxy-lane.ps1 not found" "$OUT"

echo ""
echo "Test 5: cli-proxy roll — no version stamp = not installed, never a roll"
make_mock_clone
CLONE5="$CHECKOUT_DIR"
write_fake_lane "$CLONE5" "9.9.9"
FH5="$TMP/home5"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_contains "no install on this machine is a skip" "no cli-proxy-api install on this machine" "$OUT"
assert_contains "the skip names the operator's first-install command" "\\-Install \\-Start" "$OUT"
assert_not_contains "an absent install never reports BEHIND" "behind: host" "$OUT"

echo ""
echo "Test 6: cli-proxy roll — stamp == pin is up-to-date"
mkdir -p "$FH5/.cli-proxy-api"
printf '9.9.9\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_contains "stamp == pin reports up-to-date" "up-to-date: host at v9.9.9" "$OUT"
assert_not_contains "an up-to-date host is never rolled" "rolling host" "$OUT"

echo ""
echo "Test 7: cli-proxy roll — stamp != pin reports BEHIND in check mode, rolls nothing"
printf '1.0.0\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_eq "--check exits 0 with a behind host" "0" "$RC"
assert_contains "behind host names both versions" "behind: host v1.0.0 < pin v9.9.9" "$OUT"
# --check must stay a zero-mutation dry run: no roll, no pwsh shell-out.
assert_not_contains "--check never rolls the host" "rolling host" "$OUT"

echo ""
echo "Test 8: marketplaces catch-up — --check lists rows and calls claude zero times"
FIXTURE_MKTS="$TMP/mkts.json"
cat > "$FIXTURE_MKTS" <<'JSON'
{
  "himmel":          { "source": { "source": "directory" }, "autoUpdate": true },
  "obsidian-skills": { "source": { "source": "github", "repo": "k/o" }, "autoUpdate": true },
  "openai-codex":    { "source": { "source": "github", "repo": "openai/codex-plugin-cc" } }
}
JSON
export FIXTURE_MKTS
CALLLOG="$TMP/claude-calls"; : > "$CALLLOG"
STUB8="$TMP/claude8"; make_claude_stub "$STUB8" 0 "$CALLLOG"
FH8="$TMP/home8"
OUT="$(run_update "$CLONE5" "$FH8" "$STUB8" --check)"; RC=$?
assert_eq "--check exits 0" "0" "$RC"
assert_contains "--check lists the manual-tier marketplace" "openai-codex" "$OUT"
assert_not_contains "--check does not list an autoUpdate row" "^ *obsidian-skills$" "$OUT"
assert_eq "--check invoked the claude stub ZERO times" "" "$(cat "$CALLLOG")"

echo ""
echo "Test 8b: cli-proxy roll — an AHEAD host is left alone, never downgraded"
# A bare `!=` treated newer-than-pin as drift and rolled the host BACKWARDS
# while printing it as an upgrade (CR round 4, codex-2). Pin is 9.9.9.
printf '99.0.0\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_eq "--check exits 0 with an ahead host" "0" "$RC"
assert_contains "an ahead host is reported as not-behind" "not behind: host" "$OUT"
# Match the check-mode BEHIND line's own shape ("v… < pin v…"), not the bare
# word "behind" — the not-behind message contains it as a substring.
assert_not_contains "an ahead host is never called behind" "< pin" "$OUT"
assert_not_contains "an ahead host is never rolled" "rolling host" "$OUT"

echo ""
echo "Test 8c: cli-proxy roll — an UNPARSEABLE stamp is never rolled"
# 'custom' used to parse to (0,0,0) and read as behind everything, triggering an
# unattended roll that clobbered a hand-built install (CR round 5, codex-2).
# "Cannot compare" must be its own outcome, not a silent "behind".
# 'custom' is the obvious shape; '1.custom' is the one that got through a
# leading-component-only check by degrading its tail to 0 -> (1,0,0) -> "behind"
# -> rolled anyway. Both must land in cannot-compare.
for _bad in custom 1.custom 1.2.x ""; do
    printf '%s\n' "$_bad" > "$FH5/.cli-proxy-api/cli-proxy-api.version"
    OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
    assert_eq "--check exits 0 with stamp '${_bad:-<empty>}'" "0" "$RC"
    assert_not_contains "stamp '${_bad:-<empty>}' is never called behind" "< pin" "$OUT"
    assert_not_contains "stamp '${_bad:-<empty>}' is never rolled" "rolling host" "$OUT"
done
# The last iteration's output still holds; assert the operator-facing text once.
printf 'custom\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"
assert_contains "an unparseable stamp is reported as unverifiable" "cannot verify" "$OUT"
assert_contains "and hands over the manual roll command" "Install -Restart" "$OUT"

echo ""
echo "Test 8d: cli-proxy roll — a PRERELEASE is behind the same stable pin"
# Pin is 9.9.9. A prerelease sorts below the same stable core (semver), so
# 9.9.9-rc1 must roll FORWARD to the pin — convergence, not a downgrade. Build
# metadata carries no ordering, so 9.9.9+build must read as equal (leave alone).
printf '9.9.9-rc1\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_eq "--check exits 0 with a prerelease stamp" "0" "$RC"
assert_contains "a prerelease is behind the stable pin" "< pin v9.9.9" "$OUT"
assert_not_contains "a prerelease is not treated as unverifiable" "cannot verify" "$OUT"

printf '9.9.9+build17\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_update "$CLONE5" "$FH5" "$STUB1" --check)"; RC=$?
assert_eq "--check exits 0 with build metadata" "0" "$RC"
# The literal-equality fast path does not fire (the strings differ), so this
# lands in the comparator and must come out EQUAL -> "not behind" -> left alone.
assert_contains "build metadata carries no ordering — reads as not-behind" "not behind: host v9.9.9+build17" "$OUT"
assert_not_contains "build metadata is never called behind" "< pin" "$OUT"
assert_not_contains "build metadata is never rolled" "rolling host" "$OUT"

echo ""
echo "Test 9: cli-proxy roll — APPLY mode actually rolls the host"
# The state-changing path (CR round 3, codex-2): every case above asserts on
# --check, which shells out to nothing. Here a fake `pwsh` is put first on PATH
# and `--only cli_proxy` drives JUST that step, so the roll is exercised without
# a pull/marketplace/jira-dist cycle and without touching a real proxy.
PSDIR="$TMP/fakebin"; mkdir -p "$PSDIR"
PSLOG="$TMP/pwsh-calls"; : >"$PSLOG"
make_pwsh_stub() {   # <exit-code>
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit %s\n' "$PSLOG" "$1" > "$PSDIR/pwsh"
    chmod +x "$PSDIR/pwsh"
}
run_only_cli_proxy() {   # <clone> <fake-home>
    local clone="$1" fh="$2"
    mkdir -p "$fh"
    PATH="$PSDIR:$PATH" USERPROFILE='' HOME="$fh" \
    HIMMEL_UPDATE_CLAUDE_BIN="$STUB1" HERMES_HOME="$TMP/no-hermes" \
    HIMMEL_UPDATE_AUTOSTASH='' \
    CLAUDE_USER_SETTINGS="$fh/.claude/settings.json" \
        bash "$clone/scripts/himmel-update.sh" --only cli_proxy 2>&1
}
printf '1.0.0\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
make_pwsh_stub 0
OUT="$(run_only_cli_proxy "$CLONE5" "$FH5")"; RC=$?
assert_eq "a successful roll exits 0" "0" "$RC"
assert_contains "names both versions before rolling" "rolling host v1.0.0 -> v9.9.9" "$OUT"
assert_contains "reports the roll landed" "cli-proxy-api rolled to v9.9.9" "$OUT"
# Patterns must not START with '-' — assert_contains passes them straight to
# grep, which would read a leading dash as a flag.
assert_contains "invoked the lane with -Install -Restart" "Install -Restart" "$(cat "$PSLOG")"
assert_contains "invoked the lane script itself" "cli-proxy-lane.ps1" "$(cat "$PSLOG")"

echo ""
echo "Test 10: cli-proxy roll — a REFUSED bounce warns, never aborts the update"
# Assert-BounceSafe refusing under a live codex-lane client is the expected
# non-zero here. It must stay advisory: warn with the re-run command, rc 0.
: >"$PSLOG"
make_pwsh_stub 1
OUT="$(run_only_cli_proxy "$CLONE5" "$FH5")"; RC=$?
# --only cli_proxy PROPAGATES the failure: the operator asked for exactly this
# step and is entitled to a truthful exit code. (Inside the full run the
# advisory block still swallows it — asserted by test 13 below.)
assert_eq "--only cli_proxy propagates a failed roll (rc 1)" "1" "$RC"
assert_contains "warns that the roll did not complete" "roll did not complete" "$OUT"
assert_contains "names the host version it stayed on" "host stays on v1.0.0" "$OUT"
assert_contains "prints the idle re-run command" "Install -Restart" "$OUT"
assert_not_contains "never retries with -Force on the operator's behalf" "Force" "$(cat "$PSLOG")"

echo ""
echo "Test 11: cli-proxy roll — APPLY mode with an AHEAD host completes (HIMMEL-2152)"
# Regression: _cli_proxy_version_cmp's bare `cmd; rc=$?` tripped errexit on a
# non-zero cmp_rc (1 = not behind) and killed the whole script BEFORE cmp_rc
# was ever captured — masked in --check mode by the `|| true` at the check
# call site, but --only (like the apply block) calls sync_cli_proxy bare.
: >"$PSLOG"
printf '99.0.0\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_only_cli_proxy "$CLONE5" "$FH5")"; RC=$?
assert_eq "an ahead host in apply mode still exits 0" "0" "$RC"
assert_contains "an ahead host reports not-behind in apply mode" "not behind: host v99.0.0" "$OUT"
assert_not_contains "an ahead host is never rolled in apply mode" "rolling host" "$OUT"
assert_contains "later steps still run (status table prints)" "==> update chain status" "$OUT"
assert_eq "an ahead host never invokes pwsh" "" "$(cat "$PSLOG")"

echo ""
echo "Test 12: cli-proxy roll — APPLY mode with an UNCOMPARABLE stamp completes (HIMMEL-2152)"
: >"$PSLOG"
printf 'custom\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(run_only_cli_proxy "$CLONE5" "$FH5")"; RC=$?
assert_eq "an uncomparable stamp in apply mode still exits 0" "0" "$RC"
assert_contains "an uncomparable stamp reports cannot-verify in apply mode" "cannot verify" "$OUT"
assert_not_contains "an uncomparable stamp is never rolled in apply mode" "rolling host" "$OUT"
assert_contains "later steps still run (status table prints)" "==> update chain status" "$OUT"
assert_eq "an uncomparable stamp never invokes pwsh" "" "$(cat "$PSLOG")"

echo ""
echo "Test 13: a failed cli-proxy roll never aborts a FULL himmel update"
# The other half of the same contract: advisory inside the chain run, truthful
# under --only. A roll failure must not take down an entire update.
: >"$PSLOG"
make_pwsh_stub 1
printf '1.0.0\n' > "$FH5/.cli-proxy-api/cli-proxy-api.version"
OUT="$(PATH="$PSDIR:$PATH" run_update "$CLONE5" "$FH5" "$STUB1")"; RC=$?
assert_eq "a full run still exits 0 despite the failed roll" "0" "$RC"
assert_contains "the failed roll is still reported" "roll did not complete" "$OUT"
assert_contains "and the run reaches its status table" "==> update chain status" "$OUT"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
