#!/usr/bin/env bash
# Smoke test for scripts/graphify/graph-refresh.sh (HIMMEL-1644).
#
# graph-refresh.sh is a thin wrapper that resolves the vault + fires
# refresh-graph-map.sh per corpus serially, then appends `graphmap-cadence.sh
# status`. Strategy (hermetic — mirrors test-graphmap-cadence.sh): stub the
# runner via the GRAPH_REFRESH_RUNNER env seam (a fake that logs its argv,
# appended so invocation ORDER is preserved, and can fail a named corpus via
# FAIL_REFRESH) and the cadence via GRAPH_REFRESH_CADENCE_SCRIPT (a fake whose
# `status` prints a known stub line). The wrapper forwards the caller's env, so
# RUNNER_LOG + FAIL_REFRESH reach the fake. Runs on EVERY platform (the wrapper
# is platform-agnostic; it delegates the OS-scheduler status to the stubbed
# cadence).
#
# Covers:
#   1. arg parsing — invalid corpus / unknown flag -> rc=1.
#   2. missing-vault -> rc=2.
#   3. default_vault unit — honors LUNA_VAULT_PATH verbatim, else
#      $HOME/Documents/luna (mirrors the cadence resolution exactly).
#   4. --dry-run both -> rc=0, runner NOT invoked, plan shows both corpora +
#      the cadence-status plan, makes no calls.
#   5. serial both -> runner invoked luna THEN himmel (order), with the
#      canonical per-corpus arg sets (luna corpus-root = vault, himmel
#      corpus-root = the repo, both maps-dir = vault/60-Maps, fixed
#      claude-cli backend, identical title/slug/tag literals); the
#      /graph-publish NEXT hint appears; cadence status is appended.
#   6. luna-only -> exactly one invocation, no himmel, no /graph-publish hint.
#   7. himmel-only -> exactly one invocation, /graph-publish hint appears.
#   8. vault override -> luna corpus-root + maps-dir reflect --vault.
#   9. failure propagation -> FAIL_REFRESH=himmel: luna OK + himmel FAIL,
#      both legs still ran (serial continues), rc=3.
set -euo pipefail

# grepq <text> [grep-args...] — `grep -q` against <text> with NO pipeline, so a
# match never takes SIGPIPE under this file's `set -o pipefail` (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/graph-refresh.sh"

PASS=0
FAIL=0
SKIP=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected='$expected' actual='$actual'"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
echo "test: TMP_ROOT=$TMP_ROOT"

# Hermetic PHI config dir for the vault preflight (HIMMEL-1644 codex-adv-1):
# graph-refresh.sh reads phi-roots / egress-denylist under CLAUDE_GLM_CONFIG_DIR
# (mirroring graphify-fence.sh). Point it at an EMPTY temp dir so no real PHI
# list can cause an unexpected refusal across the suite; Test 11 writes a
# phi-roots entry here and removes it.
export CLAUDE_GLM_CONFIG_DIR="$TMP_ROOT/phi-config"
mkdir -p "$CLAUDE_GLM_CONFIG_DIR"

# The interpreter that runs the script under test (resolved BEFORE the PATH
# games below, same rationale as test-graphmap-cadence).
REAL_BASH="$(command -v bash)"

# The himmel root the wrapper resolves from its own location (scripts/graphify/
# -> ../..). The himmel corpus-root passed to the runner must equal this.
HIMMEL_ROOT_EXP="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Stub vault carries the luna-vault sentinels the preflight now requires
# (HIMMEL-1644 codex-adv-1): a 60-Maps/ dir (the publish target) + an .obsidian/
# dir (luna vault marker). Every test pointing a luna leg at $VAULT relies on
# these; $VAULT2 below is upgraded the same way.
VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT/60-Maps" "$VAULT/.obsidian"

# --- fake refresh-graph-map.sh runner -----------------------------------------
# Logs its full argv to RUNNER_LOG (appended -> order preserved), parses --name
# to know which corpus, and exits 1 when FAIL_REFRESH matches that corpus. The
# wrapper forwards the caller's env, so RUNNER_LOG + FAIL_REFRESH reach it.
FAKE_RUNNER="$TMP_ROOT/runner-fake.sh"
cat >"$FAKE_RUNNER" <<'FAKE'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$RUNNER_LOG"
name=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "${FAIL_REFRESH:-}" ] && [ "$name" = "$FAIL_REFRESH" ]; then
    echo "fake-runner: failing on $name (FAIL_REFRESH)" >&2
    exit 1
fi
exit 0
FAKE
chmod +x "$FAKE_RUNNER"
export RUNNER_LOG="$TMP_ROOT/runner.log"

# --- fake graphmap-cadence.sh -------------------------------------------------
# Its `status` prints a known stub line so the test can assert the wrapper
# delegated the cadence-status step.
FAKE_CADENCE="$TMP_ROOT/cadence-fake.sh"
cat >"$FAKE_CADENCE" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "status" ]; then
    echo "CADENCE-STATUS-STUB: luna not armed"
    echo "CADENCE-STATUS-STUB: himmel not armed"
    exit 0
fi
exit 0
FAKE
chmod +x "$FAKE_CADENCE"

# Run the wrapper under test with both seams wired (runner + cadence stubbed).
# LUNA_VAULT_PATH is pinned to the stub $VAULT so the codex-adv-1-r3
# configured-identity containment holds for the standard fixtures. Pinned via
# TEST_LUNA_ROOT (a harness-only channel), NOT "${LUNA_VAULT_PATH:-$VAULT}":
# the operator's machine env commonly carries a REAL LUNA_VAULT_PATH, and
# inheriting it would make every stub fixture fail containment against the
# real vault (observed live). A test that uses a different vault ratifies it
# with an env prefix on the call (TEST_LUNA_ROOT="$OTHER" run_refresh ...),
# mirroring how an operator ratifies a non-conventional vault location.
run_refresh() {
    GRAPH_REFRESH_RUNNER="$FAKE_RUNNER" GRAPH_REFRESH_CADENCE_SCRIPT="$FAKE_CADENCE" \
    LUNA_VAULT_PATH="${TEST_LUNA_ROOT:-$VAULT}" \
        "$REAL_BASH" "$SCRIPT" "$@"
}
reset_runner_log() { : > "$RUNNER_LOG"; }

# ============================================================================
# Test 1: arg parsing — invalid corpus / unknown flag -> rc=1
# ============================================================================
echo "TEST: invalid corpus / unknown flag rejected (rc=1)"
rc=0; out=$(run_refresh bogus --vault "$VAULT" 2>&1) || rc=$?
assert_rc "invalid corpus -> rc 1" 1 "$rc"
assert_contains "invalid corpus names itself" "unknown arg" "$out"
rc=0; out=$(run_refresh both --vault "$VAULT" --bogus-flag 2>&1) || rc=$?
assert_rc "unknown flag -> rc 1" 1 "$rc"

# ============================================================================
# Test 2: missing vault dir -> rc=2
# ============================================================================
echo "TEST: missing vault dir -> rc=2"
rc=0; out=$(run_refresh --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "missing vault -> rc 2" 2 "$rc"
assert_contains "missing vault message" "not a directory" "$out"

# ============================================================================
# Test 3: default_vault unit — mirrors graphmap-cadence's resolution exactly
# ============================================================================
echo "TEST: default_vault honors LUNA_VAULT_PATH, else \$HOME/Documents/luna"
DV_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$SCRIPT"; sed -n '/^default_vault()/,/^}/p' "$SCRIPT")"
run_dv() { env "$@" bash -c "$DV_SRC"$'\n'"default_vault"; }

dv_a=$(run_dv LUNA_VAULT_PATH="/some/explicit/vault" USERPROFILE='C:\Users\x')
assert_contains "default_vault honors LUNA_VAULT_PATH verbatim" "/some/explicit/vault" "$dv_a"
assert_not_contains "LUNA_VAULT_PATH used verbatim (no Documents/luna append)" "Documents/luna" "$dv_a"

dv_b=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE HOME="/posix/home")
assert_contains "default_vault POSIX shape is \$HOME/Documents/luna" "/posix/home/Documents/luna" "$dv_b"

# ============================================================================
# Test 4: --dry-run both -> runner NOT invoked, plan printed
# ============================================================================
echo "TEST: --dry-run prints plan, invokes nothing"
reset_runner_log
rc=0; out=$(run_refresh both --vault "$VAULT" --dry-run 2>&1) || rc=$?
assert_rc "dry-run rc 0" 0 "$rc"
assert_contains "dry-run names the backend" "backend claude-cli" "$out"
assert_contains "dry-run plan has luna leg" "--name luna" "$out"
assert_contains "dry-run plan has himmel leg" "--name himmel" "$out"
assert_contains "dry-run plan has luna slug" "--slug graphify-luna-map" "$out"
assert_contains "dry-run plan has himmel slug" "--slug graphify-himmel-map" "$out"
assert_contains "dry-run plan has luna tag" "--corpus-tag luna" "$out"
assert_contains "dry-run plan has himmel tag" "--corpus-tag himmel" "$out"
# corpus-class is luna-leg-only (mirrors graphmap-cadence.sh, which passes no
# class for himmel): the luna dry-run leg carries it, the himmel leg does not.
assert_contains "dry-run luna leg has explicit corpus-class" "--corpus-class luna-personal" "$out"
himmel_dry=$(printf '%s\n' "$out" | grep '\[himmel\]' || true)
assert_not_contains "dry-run himmel leg has no corpus-class" "--corpus-class" "$himmel_dry"
# printf %q-escapes spaces in the title -> strip backslashes before asserting.
out_plain=${out//\\/}
assert_contains "dry-run plan has luna title" "Graphify Luna Map" "$out_plain"
assert_contains "dry-run plan has himmel title" "Graphify Himmel Map" "$out_plain"
assert_contains "dry-run mentions cadence status plan" "status" "$out"
assert_eq "dry-run invoked the runner zero times" "" "$(cat "$RUNNER_LOG")"

# ============================================================================
# Test 5: serial both -> order luna then himmel, canonical arg sets, hint, status
# ============================================================================
echo "TEST: serial both invokes luna then himmel with the canonical arg sets"
reset_runner_log
rc=0; out=$(run_refresh both --vault "$VAULT" 2>&1) || rc=$?
assert_rc "both rc 0" 0 "$rc"
# Order: first invocation luna, second himmel.
line1=$(sed -n '1p' "$RUNNER_LOG")
line2=$(sed -n '2p' "$RUNNER_LOG")
assert_contains "first leg is luna"   "--name luna"   "$line1"
assert_contains "second leg is himmel" "--name himmel" "$line2"
assert_eq "exactly two invocations" "2" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')"
# Canonical per-corpus arg sets (identical literals to the cadence payloads).
assert_contains "luna corpus-root is the vault"          "--corpus-root $VAULT"      "$line1"
assert_contains "luna maps-dir is the vault 60-Maps"      "--maps-dir $VAULT/60-Maps"  "$line1"
assert_contains "luna slug"                              "--slug graphify-luna-map"   "$line1"
assert_contains "luna corpus-tag"                        "--corpus-tag luna"          "$line1"
assert_contains "luna fixed claude-cli backend"          "--backend claude-cli"       "$line1"
assert_contains "luna title"                             "Graphify Luna Map"          "$line1"
assert_contains "luna leg passes explicit corpus-class" "--corpus-class luna-personal" "$line1"
assert_contains "himmel corpus-root is the himmel repo"  "--corpus-root $HIMMEL_ROOT_EXP" "$line2"
assert_contains "himmel maps-dir is the vault 60-Maps"   "--maps-dir $VAULT/60-Maps"  "$line2"
assert_contains "himmel slug"                            "--slug graphify-himmel-map" "$line2"
assert_contains "himmel corpus-tag"                      "--corpus-tag himmel"        "$line2"
assert_contains "himmel fixed claude-cli backend"        "--backend claude-cli"       "$line2"
assert_contains "himmel title"                           "Graphify Himmel Map"        "$line2"
assert_not_contains "himmel leg passes no corpus-class"  "--corpus-class"             "$line2"
# Summary + next-step hint + cadence status delegation.
assert_contains "luna OK summary"   "[luna] OK"   "$out"
assert_contains "himmel OK summary" "[himmel] OK" "$out"
assert_contains "himmel /graph-publish hint" "/graph-publish" "$out"
assert_contains "cadence status appended" "CADENCE-STATUS-STUB" "$out"
# Reworked (codex/glm-2): the OLD assert grepped $line1 (the runner argv log),
# which could never carry the wrapper's /graph-publish hint, so it was vacuous.
# Assert against the wrapper's actual combined stdout/stderr ($out): the hint
# is printed ONLY on the himmel leg (the luna leg extracts the vault, which has
# no tracked graphify-out/ to ship), so it must be [himmel]-anchored and there
# must be NO [luna] NEXT line.
hint_lines=$(printf '%s\n' "$out" | grep '/graph-publish' || true)
assert_contains "publish hint anchored to the himmel leg" "[himmel]" "$hint_lines"
assert_not_contains "no luna-leg publish hint" "[luna] NEXT" "$out"

# ============================================================================
# Test 6: luna-only -> exactly one invocation, no himmel, no publish hint
# ============================================================================
echo "TEST: luna-only refreshes luna alone"
reset_runner_log
rc=0; out=$(run_refresh luna --vault "$VAULT" 2>&1) || rc=$?
assert_rc "luna-only rc 0" 0 "$rc"
assert_eq "exactly one invocation" "1" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')"
assert_contains "the one invocation is luna" "--name luna" "$(sed -n '1p' "$RUNNER_LOG")"
assert_not_contains "no himmel leg ran" "--name himmel" "$(cat "$RUNNER_LOG")"
assert_not_contains "no /graph-publish hint on luna-only" "/graph-publish" "$out"

# ============================================================================
# Test 7: himmel-only -> exactly one invocation, publish hint appears
# ============================================================================
echo "TEST: himmel-only refreshes himmel alone + prints publish hint"
reset_runner_log
rc=0; out=$(run_refresh himmel --vault "$VAULT" 2>&1) || rc=$?
assert_rc "himmel-only rc 0" 0 "$rc"
assert_eq "exactly one invocation" "1" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')"
assert_contains "the one invocation is himmel" "--name himmel" "$(sed -n '1p' "$RUNNER_LOG")"
assert_contains "himmel /graph-publish hint" "/graph-publish" "$out"

# ============================================================================
# Test 8: vault override -> luna corpus-root + maps-dir reflect --vault
# ============================================================================
echo "TEST: --vault override flows into the runner corpus-root + maps-dir"
VAULT2="$TMP_ROOT/vault2"
mkdir -p "$VAULT2/60-Maps" "$VAULT2/.obsidian"
# The wrapper now reassigns $VAULT to the preflight's CANONICAL resolved form
# (codex-adv-2 r3), so the runner argv carries that form — compute the same
# expectation the resolver chain produces (plain temp dirs: usually identical).
V2_CANON=$(realpath "$VAULT2" 2>/dev/null || printf '%s' "$VAULT2")
reset_runner_log
# LUNA_VAULT_PATH prefix = ratify vault2 as the configured root (containment).
rc=0; out=$(TEST_LUNA_ROOT="$VAULT2" run_refresh luna --vault "$VAULT2" 2>&1) || rc=$?
assert_rc "vault-override rc 0" 0 "$rc"
line1=$(sed -n '1p' "$RUNNER_LOG")
assert_contains "luna corpus-root is the override vault (canonical form)" "--corpus-root $V2_CANON" "$line1"
assert_contains "luna maps-dir is the override vault 60-Maps (canonical form)" "--maps-dir $V2_CANON/60-Maps" "$line1"

# ============================================================================
# Test 9: failure propagation -> both legs run, rc=3
# ============================================================================
echo "TEST: himmel failure propagates rc=3; luna leg still ran (serial continues)"
reset_runner_log
rc=0; out=$(FAIL_REFRESH=himmel run_refresh both --vault "$VAULT" 2>&1) || rc=$?
assert_rc "failure-propagation rc 3" 3 "$rc"
assert_contains "luna OK despite himmel failure" "[luna] OK" "$out"
assert_contains "himmel FAIL reported" "[himmel] FAIL" "$out"
assert_eq "both legs still ran (serial continues)" "2" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')"
assert_contains "summary names the failure count" "1 of 2 corpus(corpora) FAILED" "$out"
# A failed himmel leg must NOT print the publish hint (nothing to publish).
assert_not_contains "no publish hint on failed himmel leg" "[himmel] NEXT" "$out"

# ============================================================================
# Test 10: vault preflight — refuse a salus/PHI-marked vault (codex-adv-1)
# ============================================================================
echo "TEST: salus-marked vault refused before any leg fires (rc=2)"
SALUS_TREE="$TMP_ROOT/salus-tree"
mkdir -p "$SALUS_TREE/vault"
touch "$SALUS_TREE/.salus"   # PHI marker on an ancestor of the vault
reset_runner_log
rc=0; out=$(run_refresh luna --vault "$SALUS_TREE/vault" 2>&1) || rc=$?
assert_rc "salus-marked vault -> rc 2" 2 "$rc"
assert_contains "salus refuse message names salus/PHI" "salus" "$out"
assert_eq "salus refusal fired no runner leg" "" "$(cat "$RUNNER_LOG")"

# ============================================================================
# Test 11: vault preflight — refuse a vault under a stubbed phi-roots entry
# ============================================================================
echo "TEST: phi-roots-listed vault refused before any leg fires (rc=2)"
PHI_ZONE="$TMP_ROOT/phi-zone"
mkdir -p "$PHI_ZONE/vault"
printf '%s\n' "$PHI_ZONE" > "$CLAUDE_GLM_CONFIG_DIR/phi-roots"
reset_runner_log
rc=0; out=$(run_refresh luna --vault "$PHI_ZONE/vault" 2>&1) || rc=$?
assert_rc "phi-roots vault -> rc 2" 2 "$rc"
assert_contains "phi-roots refuse message names the list" "phi-roots" "$out"
assert_eq "phi-roots refusal fired no runner leg" "" "$(cat "$RUNNER_LOG")"
rm -f "$CLAUDE_GLM_CONFIG_DIR/phi-roots"

# ============================================================================
# Test 12: vault preflight — refuse a filesystem root and the operator HOME
# ============================================================================
echo "TEST: filesystem-root + HOME vaults refused (rc=2)"
reset_runner_log
rc=0; out=$(run_refresh luna --vault "/" 2>&1) || rc=$?
assert_rc "filesystem root -> rc 2" 2 "$rc"
assert_contains "root refuse message" "root" "$out"
# The operator HOME the wrapper resolves (the same resolve_user_home the
# preflight compares against) -- reuse the source extracted in Test 3.
home_val=$(bash -c "$DV_SRC"$'\n'"resolve_user_home")
rc=0; out=$(run_refresh luna --vault "$home_val" 2>&1) || rc=$?
assert_rc "HOME vault -> rc 2" 2 "$rc"
assert_contains "HOME refuse message" "HOME" "$out"

# ============================================================================
# Test 12b: configured-identity containment (codex-adv-1 r3) — sentinels prove
# "an Obsidian vault", not "THE luna vault"; a different vault refuses until
# ratified via LUNA_VAULT_PATH (the machine-config channel).
# ============================================================================
echo "TEST: sentinel-bearing NON-luna vault refused unless ratified (rc=2)"
OTHER_VAULT="$TMP_ROOT/other-obsidian-vault"
mkdir -p "$OTHER_VAULT/60-Maps" "$OTHER_VAULT/.obsidian"
reset_runner_log
rc=0; out=$(run_refresh luna --vault "$OTHER_VAULT" 2>&1) || rc=$?   # configured root = $VAULT
assert_rc "non-luna sentinel vault -> rc 2" 2 "$rc"
assert_contains "containment refuse names the configured root" "configured luna root" "$out"
assert_eq "containment refusal fired no runner leg" "" "$(cat "$RUNNER_LOG")"
reset_runner_log
rc=0; out=$(TEST_LUNA_ROOT="$OTHER_VAULT" run_refresh luna --vault "$OTHER_VAULT" 2>&1) || rc=$?
assert_rc "ratified via LUNA_VAULT_PATH -> rc 0" 0 "$rc"

# ============================================================================
# Test 12c: drive-relative vault path refused (HIMMEL-845 mirror, codex-adv-2
# r3) — string-shape check, fires before the -d existence check.
# ============================================================================
echo "TEST: drive-relative vault path refused (rc=2)"
reset_runner_log
rc=0; out=$(run_refresh luna --vault "C:relative-vault" 2>&1) || rc=$?
assert_rc "drive-relative vault -> rc 2" 2 "$rc"
assert_contains "drive-relative refuse names the hazard" "drive-relative" "$out"
assert_eq "drive-relative refusal fired no runner leg" "" "$(cat "$RUNNER_LOG")"

# ============================================================================
# Test 13: vault preflight — refuse a non-vault dir (luna leg needs sentinels)
# ============================================================================
echo "TEST: missing-sentinel vault refused on the luna leg (rc=2)"
NO_SENTINEL="$TMP_ROOT/no-sentinel"
mkdir -p "$NO_SENTINEL"   # plain dir: no 60-Maps, no .obsidian
reset_runner_log
rc=0; out=$(run_refresh luna --vault "$NO_SENTINEL" 2>&1) || rc=$?
assert_rc "missing-sentinel luna -> rc 2" 2 "$rc"
assert_contains "sentinel message names 60-Maps" "60-Maps" "$out"
assert_contains "sentinel message names .obsidian" ".obsidian" "$out"
assert_eq "missing-sentinel fired no runner leg" "" "$(cat "$RUNNER_LOG")"
# The sentinel is LUNA-leg-only: a himmel-only run extracts the repo (not the
# vault), so a non-vault maps-dir is accepted -- the root/PHI checks still ran
# and passed (NO_SENTINEL is a plain temp dir); only the sentinel is skipped.
reset_runner_log
rc=0; out=$(run_refresh himmel --vault "$NO_SENTINEL" 2>&1) || rc=$?
assert_rc "himmel-only on non-vault dir -> rc 0 (no sentinel requirement)" 0 "$rc"

# ============================================================================
# Test 14: vault preflight — a symlinked vault into a salus tree is refused via
# the RESOLVED path (HIMMEL-1644 codex-1 r2). The symlink's OWN ancestors carry
# no .salus marker (so a LEXICAL preflight would PASS -- the bug); only the
# resolved target's ancestry has the marker. A refusal here proves preflight
# classifies the canonical target the extraction reads, not the link.
# ============================================================================
echo "TEST: symlinked vault into a salus tree refused via the resolved path (rc=2)"
SALUS_REAL="$TMP_ROOT/salus-real"
mkdir -p "$SALUS_REAL/phizone/vault/60-Maps" "$SALUS_REAL/phizone/vault/.obsidian"
touch "$SALUS_REAL/phizone/.salus"   # PHI marker on an ancestor of the REAL vault
SALUS_LINK="$TMP_ROOT/salus-link"
# ln -s on Git-Bash without symlink privilege makes a COPY (not a link), which
# would make the resolved path == the link path and defeat this test -- guard
# with [ -L ] (true only for a real symlink) and skip loudly when the platform
# cannot create one (matching this suite's loud-skip convention).
if ln -s "$SALUS_REAL/phizone/vault" "$SALUS_LINK" 2>/dev/null && [ -L "$SALUS_LINK" ]; then
    reset_runner_log
    rc=0; out=$(run_refresh luna --vault "$SALUS_LINK" 2>&1) || rc=$?
    assert_rc "symlinked-salus vault -> rc 2" 2 "$rc"
    assert_contains "symlink salus refuse names salus/PHI" "salus" "$out"
    assert_eq "symlink salus refusal fired no runner leg" "" "$(cat "$RUNNER_LOG")"
else
    skip "symlink creation unavailable on this platform (ln -s made a copy or failed) -- symlink-into-salus preflight not exercised"
fi

# ============================================================================
# Test 15: vault preflight — a symlinked vault pointing at a LEGIT stub vault
# (60-Maps/.obsidian sentinels at the TARGET) is ACCEPTED via the resolved path
# (HIMMEL-1644 codex-1 r2). Proves resolution does not over-refuse: a safe
# symlinked target passes and the luna leg still fires.
# ============================================================================
echo "TEST: symlinked vault at a legit stub vault accepted via the resolved path (rc=0)"
GOOD_REAL="$TMP_ROOT/good-real"
mkdir -p "$GOOD_REAL/60-Maps" "$GOOD_REAL/.obsidian"
GOOD_LINK="$TMP_ROOT/good-link"
if ln -s "$GOOD_REAL" "$GOOD_LINK" 2>/dev/null && [ -L "$GOOD_LINK" ]; then
    reset_runner_log
    rc=0; out=$(run_refresh luna --vault "$GOOD_LINK" 2>&1) || rc=$?
    assert_rc "symlinked legit vault -> rc 0" 0 "$rc"
    assert_contains "symlinked legit vault ran the luna leg" "--name luna" "$(sed -n '1p' "$RUNNER_LOG")"
    assert_eq "symlinked legit vault fired exactly one leg" "1" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')"
else
    skip "symlink creation unavailable on this platform (ln -s made a copy or failed) -- symlink-accept preflight not exercised"
fi

summary
