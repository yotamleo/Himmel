#!/usr/bin/env bash
# Smoke test for scripts/luna/graphmap-cadence.sh (HIMMEL-829, Option B).
#
# Two daily cadence tasks are armed: HIMMEL-GraphMap-Luna (daily 13:00 ->
# refresh-graph-map.sh --name luna ...) and HIMMEL-GraphMap-Himmel (daily
# 13:20 -> refresh-graph-map.sh --name himmel ...). Unlike pipeline-cadence
# these runners fire a DETERMINISTIC script (bash refresh-graph-map.sh ...),
# NOT a claude session — so there is no --settings fragment, no NUL stdin, no
# auto-approve hook to assert.
#
# Strategy (hermetic — mirrors test-pipeline-cadence.sh): replace the
# scheduler with a fake — schtasks via the GRAPHMAP_SCHTASKS seam (records
# /create XML + simulates /query and /delete from a state dir), crontab via
# the GRAPHMAP_CRONTAB seam (a state-file crontab supporting -l and - install);
# point GRAPHMAP_BAT_DIR at a temp dir so the runners (.bat/.sh) are
# inspectable; put a fake `bash` first on PATH so arm resolves the stub, never
# the real interpreter. HOME/USERPROFILE point at the temp dir so nothing
# touches the real user profile. The cron suite runs on EVERY platform (the
# POSIX path is forced with an OSTYPE override); the schtasks suite stays
# Windows-only (cmd_arm needs cygpath).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/graphmap-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Shared fixtures ------------------------------------------------------------

# The interpreter that runs the script under test. Resolved BEFORE the fake
# bash below shadows PATH: `env PATH=... bash` would exec the FAKE via the NEW
# PATH, and on Linux the fake's own `#!/usr/bin/env bash` shebang re-resolves
# to itself -> infinite exec loop -> the whole suite hangs to the CI timeout
# (broke public CI on ubuntu; Git Bash dodges it only because the mixed-form
# C:/ PATH entry loses the lookup there).
REAL_BASH="$(command -v bash)"

# Fake bash on PATH (arm resolves it via `command -v bash`). A no-op stub is
# enough — the tests assert runner TEXT, they never fire the runner. Shebang
# is /bin/sh (absolute) so the stub can never shebang-recurse into itself.
mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/bash"
chmod +x "$TMP_ROOT/bin/bash"

# Fake `claude` on PATH (HIMMEL-1070): arm now resolves it via `command -v claude`
# and FAILS FAST when it is absent, because the fixed claude-cli BACKEND shells it
# at fire time under the scheduler's minimal PATH. A stub keeps the suite
# deterministic on machines with and without a real CLI installed; like the bash
# stub it is never fired, only resolved + its dirname read.
#
# It lives in its OWN dir, entered on PATH in POSIX form, for two reasons the
# `bin` dir above cannot serve: (1) TMP_ROOT is cygpath -m'd (C:/... mixed form)
# and Git-Bash cannot resolve a PATH entry in that form — a stub in `bin` is
# INVISIBLE on Windows, so the arm would silently resolve the operator's REAL
# installed claude and the runner assertion below would pin a machine-specific
# path; (2) adding a POSIX entry for `bin` itself would newly expose the fake
# `bash` on Windows, changing what the existing suite bakes into its runners.
CLAUDE_BIN_DIR="$TMP_ROOT/claude-bin"
mkdir -p "$CLAUDE_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN_DIR/claude"
chmod +x "$CLAUDE_BIN_DIR/claude"
CLAUDE_BIN_DIR_PATH="$CLAUDE_BIN_DIR"
if command -v cygpath >/dev/null 2>&1; then
    CLAUDE_BIN_DIR_PATH=$(cygpath -u "$CLAUDE_BIN_DIR")
fi
# EVERY invocation that reaches `arm` must carry $CLAUDE_BIN_DIR_PATH on PATH —
# arm fail-fasts when `claude` is absent (HIMMEL-1070). Omitting it does NOT fail
# on a dev box that happens to have the real CLI installed: the inherited $PATH
# tail satisfies the probe by ACCIDENT, so the suite goes green locally and dies
# on a clean CI runner with rc=2 (set -euo pipefail aborts the whole script on the
# unguarded `arm` assignment, before any assertion prints). That is exactly how
# this shipped to public CI once. The stub keeps the suite hermetic — a test's
# result must never depend on what the operator has installed.

# A PATH with the real system dirs (arm needs dirname/sed/mktemp at load time)
# but with EVERY dir that carries a real `claude` filtered out — the fail-fast
# probe below must not be satisfied by an installed CLI. Filtering the real PATH
# beats replacing it: a bare stub dir strips coreutils and the script dies rc=127
# on `dirname` before it ever reaches the check under test.
PATH_NOCLAUDE=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/claude" ] || [ -x "$_d/claude.exe" ] || [ -x "$_d/claude.cmd" ]; then continue; fi
    PATH_NOCLAUDE="${PATH_NOCLAUDE:+$PATH_NOCLAUDE:}$_d"
done
IFS=$_oldifs

# Hermeticity: point HOME/USERPROFILE at the temp dir so a stray BAT_DIR default
# (should the seam ever be dropped) can't land under the real user profile.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT"

# The himmel root the runners cd into is this script's ../.. (same resolution
# graphmap-cadence.sh uses for HIMMEL_ROOT).
HIMMEL_ROOT_EXP="$(cd "$SCRIPT_DIR/../.." && pwd)"
# A claude-session runner (the sibling pipeline-cadence) would carry these
# markers; a deterministic refresh-graph-map runner must carry NONE of them.
# (Can't grep the bare word "claude" — the worktree path contains ".claude".)

# ============================================================================
# xml_escape unit — the one non-trivial string transform. Pure + platform-
# agnostic, so it runs on EVERY platform: extract the function and call it.
# ============================================================================
echo "TEST: xml_escape escapes & < > with & ordered first"
xesc=$( { sed -n '/^xml_escape()/,/^}/p' "$SCRIPT"; echo "xml_escape 'a & b < c > d'"; } | bash )
assert_contains "xml_escape produces well-formed entities (& first)" "a &amp; b &lt; c &gt; d" "$xesc"
assert_not_contains "xml_escape leaves no bare ampersand" "a & b" "$xesc"

# ============================================================================
# default_vault / resolve_user_home units — cross-platform default resolution.
# Pure (env + cygpath only), so they run on EVERY platform.
# ============================================================================
echo "TEST: default_vault resolves the cross-platform default vault"
DV_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$SCRIPT"; sed -n '/^default_vault()/,/^}/p' "$SCRIPT")"
run_dv() { env "$@" bash -c "$DV_SRC"$'\n'"default_vault"; }

dv_a=$(run_dv LUNA_VAULT_PATH="/some/explicit/vault" USERPROFILE='C:\Users\x')
assert_contains "default_vault honors LUNA_VAULT_PATH" "/some/explicit/vault" "$dv_a"
assert_not_contains "LUNA_VAULT_PATH used verbatim (no Documents/luna append)" "Documents/luna" "$dv_a"

dv_b=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE HOME="/posix/home")
assert_contains "default_vault POSIX shape is \$HOME/Documents/luna" "/posix/home/Documents/luna" "$dv_b"

# ============================================================================
# POSIX (cron) suite. Runs on EVERY platform: the cron code path is forced via
# an OSTYPE override + the GRAPHMAP_CRONTAB seam.
# ============================================================================

CSTATE="$TMP_ROOT/cron-state"
mkdir -p "$CSTATE"

# Fake crontab: persists the installed tab at $CSTATE/crontab. Mimics real
# crontab signatures: -l with no tab prints "no crontab for <user>" + rc=1;
# `crontab -` installs from stdin. Failure seam: $CSTATE/fail-write.
# Shebang MUST be /bin/sh (absolute, POSIX body): `#!/usr/bin/env bash` would
# resolve the no-op fake `bash` stub via the prepended PATH on Linux, turning
# every crontab call into a silent no-op (rc=0, nothing read or written) — 35
# green-on-Windows assertions failed exactly this way on ubuntu CI.
FAKE_CRONTAB="$TMP_ROOT/crontab-fake.sh"
cat >"$FAKE_CRONTAB" <<FAKE
#!/bin/sh
CSTATE="$CSTATE"
FAKE
cat >>"$FAKE_CRONTAB" <<'FAKE'
case "${1:-}" in
    -l)
        if [ -e "$CSTATE/fail-list" ]; then
            echo "crontab: must be privileged to use -l" >&2
            exit 1
        fi
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -)
        if [ -e "$CSTATE/fail-write" ]; then
            echo "crontab: error writing new crontab" >&2
            exit 1
        fi
        cat > "$CSTATE/crontab"
        ;;
    *)
        echo "crontab-fake: unsupported argv: $*" >&2
        exit 64
        ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB"

CRON_DIR="$TMP_ROOT/cron-runners"

run_cron() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
        GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$TMP_ROOT/bin:$CLAUDE_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron luna not armed"   "not armed  HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel not armed" "not armed  HIMMEL-GraphMap-Himmel" "$out"

# Test C12: shared validation wired into the cron path -----------------------

echo "TEST: cron arm rejects invalid input (shared validation)"
rc=0; out=$(run_cron arm --vault "$VAULT" --luna-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --luna-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --himmel-time 25:00 2>&1) || rc=$?
assert_rc "cron bad --himmel-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "cron missing vault dir -> rc 1" 1 "$rc"

# Test C13: arm fails fast when `claude` is absent (HIMMEL-1070) --------------
#
# The cadence's fixed claude-cli backend shells `claude` at fire time under the
# scheduler's minimal PATH. Arming on a machine without it would "succeed" and
# then die on every unattended fire, in a log nobody reads. PATH is REPLACED
# (not prepended) so a really-installed claude cannot satisfy the probe here.

echo "TEST: cron arm fails fast when claude is not on PATH"
rc=0; out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$PATH_NOCLAUDE" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron arm without claude -> rc 2" 2 "$rc"
assert_contains "missing-claude error names the CLI" "'claude' not on PATH at arm time" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "failed arm installed nothing"
else
    fail "failed arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C2: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --vault "$VAULT" --dry-run)
assert_contains "dry-run daily luna entry"   "00 13 * * *" "$out"
assert_contains "dry-run daily himmel entry" "20 13 * * *" "$out"
assert_contains "dry-run luna marker"   "# HIMMEL-GraphMap-Luna"   "$out"
assert_contains "dry-run himmel marker" "# HIMMEL-GraphMap-Himmel" "$out"
assert_contains "dry-run fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "dry-run luna payload names the corpus" "--name luna" "$out"
assert_contains "dry-run himmel payload names the corpus" "--name himmel" "$out"
if [ ! -f "$CSTATE/crontab" ]; then
    pass "dry-run installed no crontab"
else
    fail "dry-run installed a crontab" "$(cat "$CSTATE/crontab")"
fi
if [ ! -d "$CRON_DIR" ]; then
    pass "dry-run wrote no runner .sh"
else
    fail "dry-run wrote runners" "$(ls "$CRON_DIR")"
fi

# Test C3: arm installs marker-tagged entries, preserves unrelated lines ------

echo "TEST: cron arm installs entries with defaults, preserves unrelated lines"
printf '5 5 * * * /usr/bin/true # keep-me\n' > "$CSTATE/crontab"
out=$(run_cron arm --vault "$VAULT")
assert_contains "cron arm banner" "GRAPHMAP CADENCE ARMED" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "daily luna entry 13:00"   "00 13 * * *" "$tab"
assert_contains "daily himmel entry 13:20" "20 13 * * *" "$tab"
assert_contains "luna entry marker-tagged"   "# HIMMEL-GraphMap-Luna"   "$tab"
assert_contains "himmel entry marker-tagged" "# HIMMEL-GraphMap-Himmel" "$tab"
assert_contains "luna entry fires the runner"   "graphmap-luna.sh"   "$tab"
assert_contains "himmel entry fires the runner" "graphmap-himmel.sh" "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
if [ -x "$CRON_DIR/graphmap-luna.sh" ] && [ -x "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "runner .sh files written + executable"
else
    fail "runner .sh files missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi

# Test C4: runner .sh fires refresh-graph-map.sh with the right payload -------

echo "TEST: runner .sh fires bash refresh-graph-map.sh (deterministic, no claude)"
luna_sh=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
# The sh runner embeds paths/title via printf %q (backslash-escapes spaces);
# strip the escapes before multi-word asserts.
luna_sh_plain=${luna_sh//\\/}
himmel_sh_plain=${himmel_sh//\\/}
assert_contains "luna runner stamps the format version (HIMMEL-588)"   "# himmel-cadence-runner-format: 4" "$luna_sh"
assert_contains "himmel runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: 4" "$himmel_sh"
assert_contains "luna runner fires refresh-graph-map.sh"   "refresh-graph-map.sh" "$luna_sh_plain"
assert_contains "luna runner names the luna corpus"        "--name luna"          "$luna_sh"
assert_contains "luna runner sets the luna slug"           "--slug graphify-luna-map" "$luna_sh"
assert_contains "luna runner sets the luna corpus-tag"     "--corpus-tag luna"    "$luna_sh"
assert_contains "luna runner uses the claude-cli backend"      "--backend claude-cli --corpus-tag" "$luna_sh"
assert_contains "luna runner sets the luna title"          "Graphify Luna Map"    "$luna_sh_plain"
assert_contains "luna runner publishes into 60-Maps"       "60-Maps"              "$luna_sh_plain"
# Strong corpus-root asserts (HIMMEL-829 CR, pr-test-analyzer): the luna map
# extracts the VAULT, the himmel map extracts the HIMMEL REPO — deliberately
# different roots. Match the --corpus-root TOKEN (not a bare $VAULT, which also
# appears in --maps-dir) so a payload arg-swap that makes the himmel map extract
# the vault (or vice-versa) fails here instead of shipping a wrong/empty graph.
assert_contains "luna runner corpus-root is the vault"     "--corpus-root $VAULT"           "$luna_sh_plain"
assert_contains "himmel runner names the himmel corpus"    "--name himmel"        "$himmel_sh"
assert_contains "himmel runner sets the himmel slug"       "--slug graphify-himmel-map" "$himmel_sh"
assert_contains "himmel runner sets the himmel corpus-tag" "--corpus-tag himmel"  "$himmel_sh"
assert_contains "himmel runner uses the claude-cli backend"    "--backend claude-cli --corpus-tag" "$himmel_sh"
assert_contains "himmel runner corpus-root is the himmel repo" "--corpus-root $HIMMEL_ROOT_EXP" "$himmel_sh_plain"
assert_contains "himmel runner sets the himmel title"      "Graphify Himmel Map"  "$himmel_sh_plain"
assert_contains "luna runner cds into himmel root" "cd $HIMMEL_ROOT_EXP" "$luna_sh_plain"
# shellcheck disable=SC2016  # literal $log needles — the runner expands them at fire time
assert_contains "luna runner rotates the log" 'mv -f "$log" "$log.prev"' "$luna_sh"
assert_contains "luna runner stamps every fire" '[fired' "$luna_sh"
# shellcheck disable=SC2016
assert_contains "luna runner captures output to log" '>> "$log" 2>&1' "$luna_sh"
for what in luna himmel; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    assert_not_contains "$what runner has no --settings (not a claude session)" "--settings" "$body"
    assert_not_contains "$what runner has no bounded-claude stdin marker" "< /dev/null" "$body"
    # HIMMEL-1070: cron's minimal PATH carries neither node nor claude, so the
    # runner must pin the claude CLI's dir the same way it already pins node's —
    # without it every fire dies with "backend 'claude-cli' requires the `claude`
    # CLI on $PATH". The expected dir is where the stub claude lives.
    # shellcheck disable=SC2016  # literal $PATH — the runner expands it at fire time
    assert_contains "$what runner prepends the claude dir to PATH" \
        "export PATH=$CLAUDE_BIN_DIR_PATH:\$PATH" "${body//\\/}"
done

# Test C5: status after arm ----------------------------------------------------

echo "TEST: cron status reflects armed entries"
out=$(run_cron status)
assert_contains "cron luna armed"   "ARMED      HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel armed" "ARMED      HIMMEL-GraphMap-Himmel" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"

# Test C6: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names existing entries" "HIMMEL-GraphMap-Himmel" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap-' "$CSTATE/crontab")" -eq 2 ]; then
    pass "no duplicate entries after blocked re-arm"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C7: re-arm --force with overrides ----------------------------------------

echo "TEST: cron re-arm --force applies flag overrides"
out=$(run_cron arm --vault "$VAULT" --force --luna-time 01:15 --himmel-time 02:30 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "cron daily luna override"   "15 01 * * *" "$tab"
assert_contains "cron daily himmel override" "30 02 * * *" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap-' "$CSTATE/crontab")" -eq 2 ]; then
    pass "still exactly two entries after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C14: dry-run disarm with armed entries prints DRY tail, touches nothing --

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap-' "$CSTATE/crontab")" -eq 2 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "dry-run disarm kept the runner .sh files"
else
    fail "dry-run disarm deleted runner .sh files"
fi

# Test C8: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes entries + runners, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entries removed" "HIMMEL-GraphMap-" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "runner .sh files removed"
else
    fail "runner .sh files left after disarm"
fi
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C9: failing crontab -l is fail-CLOSED -------------------------------------

echo "TEST: cron arm/status/disarm with failing crontab -l exit 2"
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron fail-closed arm rc 2" 2 "$rc"
assert_contains "cron arm failure surfaces stderr" "must be privileged" "$out"
rc=0; out=$(run_cron status 2>&1) || rc=$?
assert_rc "cron fail-closed status rc 2" 2 "$rc"
rm -f "$CSTATE/fail-list"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on failing crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "runner .sh files NOT deleted on crontab -l failure"
else
    fail "runner .sh files deleted despite crontab -l failure"
fi
rm -f "$CSTATE/fail-list"
run_cron disarm >/dev/null

# Test C10: crontab install failure -> rc 4 ---------------------------------------

echo "TEST: cron arm with failing crontab install exits 4"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron install failure rc 4" 4 "$rc"
assert_contains "cron install failure surfaces stderr" "error writing new crontab" "$out"
if ! grep -q 'HIMMEL-GraphMap-' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entries installed on write failure"
else
    fail "cadence entries installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "no runner promoted to its final path on write failure"
else
    fail "runner files left despite write failure" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter on write failure"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10b: --force re-arm with failing install leaves NO half-state ------------

echo "TEST: cron --force re-arm with failing install keeps old runners + entries"
out=$(run_cron arm --vault "$VAULT")
VAULT2="$TMP_ROOT/vault2"
mkdir -p "$VAULT2"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT2" --force 2>&1) || rc=$?
assert_rc "cron force re-arm install failure rc 4" 4 "$rc"
luna_sh=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
assert_contains "old runner still points at the old vault" "$VAULT" "${luna_sh//\\/}"
assert_not_contains "no new-config runner promoted" "vault2" "$luna_sh"
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter after failed --force re-arm"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
if [ "$(grep -c 'HIMMEL-GraphMap-' "$CSTATE/crontab")" -eq 2 ]; then
    pass "old entries still armed after failed --force re-arm"
else
    fail "entry count changed on failed --force re-arm" "$(cat "$CSTATE/crontab")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10c: disarm with failing install keeps entries + runners -----------------

echo "TEST: cron disarm with failing crontab install exits 4, keeps entries + runners"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron disarm install failure rc 4" 4 "$rc"
assert_contains "disarm install failure surfaces stderr" "error writing new crontab" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap-' "$CSTATE/crontab")" -eq 2 ]; then
    pass "entries still in crontab after failed disarm install"
else
    fail "entries lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "runner .sh files NOT deleted on failed disarm install"
else
    fail "runner .sh files deleted despite failed disarm install"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C11: hostile-but-legal vault dirname + runner dir can't inject -------------

echo "TEST: cron entries + runner escape hostile vault/runner paths"
EVIL_VAULT="$TMP_ROOT/va&ult \$X y"
EVIL_DIR="$TMP_ROOT/cr%on rnr"
mkdir -p "$EVIL_VAULT"
out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$CLAUDE_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$EVIL_VAULT")
luna_sh=$(cat "$EVIL_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
assert_contains "ampersand %q-escaped in runner" 'va\&ult' "$luna_sh"
# shellcheck disable=SC2016  # literal \$X needle — asserting the %q escape itself
assert_contains "dollar %q-escaped in runner" '\$X' "$luna_sh"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$CLAUDE_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" disarm >/dev/null

# Test C13: unknown platform exits 2 ----------------------------------------------

echo "TEST: unknown platform (OSTYPE=beos) exits 2"
rc=0; out=$(env OSTYPE=beos bash "$SCRIPT" status 2>&1) || rc=$?
assert_rc "unknown platform rc 2" 2 "$rc"
assert_contains "unknown platform message" "unsupported platform" "$out"

# ============================================================================
# schtasks suite — Windows-only (cmd_arm needs cygpath; the cron suite above
# already exercised the POSIX path on this platform).
# ============================================================================

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) : ;;
    *)
        echo "SKIP: schtasks suite (Windows-only — needs cygpath/schtasks shapes)"
        summary
        ;;
esac

# schtasks fixtures ----------------------------------------------------------

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/tasks"

# Fake schtasks: persists tasks as files under $STATE/tasks/<name> (content =
# the created XML, for assertions). Mirrors test-pipeline-cadence's fake.
# Shebang is the pre-resolved REAL bash (the body needs bash arrays) — an
# env-bash shebang would resolve the no-op fake `bash` stub via the prepended
# PATH (see the crontab fake above for the failure mode this caused).
FAKE_SCHTASKS="$TMP_ROOT/schtasks-fake.sh"
cat >"$FAKE_SCHTASKS" <<FAKE
#!$REAL_BASH
STATE="$STATE"
FAKE
cat >>"$FAKE_SCHTASKS" <<'FAKE'
tn=""; mode=""; xmlpath=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        /create|/delete|/query) mode="${args[$i]}" ;;
        /tn) i=$((i+1)); tn="${args[$i]}" ;;
        /xml) i=$((i+1)); xmlpath="${args[$i]}" ;;
    esac
    i=$((i+1))
done
case "$mode" in
    /create)
        if [ -e "$STATE/fail-create-$tn" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        if [ -n "$xmlpath" ]; then
            xml_posix=$(cygpath -u "$xmlpath" 2>/dev/null || echo "$xmlpath")
            cat "$xml_posix" > "$STATE/tasks/$tn"
        else
            printf '%s\n' "$*" > "$STATE/tasks/$tn"
        fi
        echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."
        ;;
    /delete)
        if [ -f "$STATE/tasks/$tn" ]; then rm -f "$STATE/tasks/$tn"; exit 0; else exit 1; fi
        ;;
    /query)
        if [ -e "$STATE/fail-query" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        if [ -n "$tn" ]; then
            if [ -f "$STATE/tasks/$tn" ]; then
                printf 'TaskName:      \\%s\nNext Run Time: 7/10/2026 1:00:00 PM\n' "$tn"
                exit 0
            fi
            echo "ERROR: The system cannot find the file specified." >&2
            exit 1
        fi
        found=0
        for f in "$STATE/tasks"/*; do
            [ -e "$f" ] || continue
            found=1
            printf '"\\%s","7/10/2026 1:00:00 PM","Ready"\n' "$(basename "$f")"
        done
        [ "$found" -eq 1 ] || exit 1
        ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS"

BAT_DIR="$TMP_ROOT/bats"

run_gc() {
    PIPELINE_UNUSED="" GRAPHMAP_SCHTASKS="$FAKE_SCHTASKS" GRAPHMAP_BAT_DIR="$BAT_DIR" \
        PATH="$TMP_ROOT/bin:$CLAUDE_BIN_DIR_PATH:$PATH" "$REAL_BASH" "$SCRIPT" "$@"
}

# Test 1: usage errors ------------------------------------------------------

echo "TEST: missing / unknown subcommand rejected"
rc=0; out=$(run_gc 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(run_gc frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

# Test 2: input validation --------------------------------------------------

echo "TEST: invalid inputs rejected"
rc=0; out=$(run_gc arm --vault "$VAULT" --luna-time 9:00 2>&1) || rc=$?
assert_rc "bad --luna-time (no leading zero) -> rc 1" 1 "$rc"
rc=0; out=$(run_gc arm --vault "$VAULT" --himmel-time 25:00 2>&1) || rc=$?
assert_rc "bad --himmel-time -> rc 1" 1 "$rc"
rc=0; out=$(run_gc arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "missing vault dir -> rc 1" 1 "$rc"

# Test 3: status on empty scheduler ----------------------------------------

echo "TEST: status with nothing armed"
out=$(run_gc status)
assert_contains "luna not armed"   "not armed  HIMMEL-GraphMap-Luna"   "$out"
assert_contains "himmel not armed" "not armed  HIMMEL-GraphMap-Himmel" "$out"

# Test 4: arm --dry-run touches nothing -------------------------------------

echo "TEST: arm --dry-run prints plan, registers nothing"
out=$(run_gc arm --vault "$VAULT" --dry-run)
assert_contains "dry-run luna create"   "/tn HIMMEL-GraphMap-Luna /xml" "$out"
assert_contains "dry-run himmel create" "/tn HIMMEL-GraphMap-Himmel /xml" "$out"
assert_contains "dry-run XML has StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$out"
assert_contains "dry-run XML daily schedule" "<ScheduleByDay>" "$out"
assert_contains "dry-run luna time" "T13:00:00" "$out"
assert_contains "dry-run himmel time" "T13:20:00" "$out"
assert_contains "dry-run fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "dry-run registered no tasks"
else
    fail "dry-run registered tasks" "$(ls "$STATE/tasks")"
fi
if [ ! -d "$BAT_DIR" ]; then
    pass "dry-run wrote no .bat files"
else
    fail "dry-run wrote .bat files" "$(ls "$BAT_DIR")"
fi

# Test 5: arm registers both tasks with operator-decision defaults ----------

echo "TEST: arm registers daily luna 13:00 + daily himmel 13:20"
out=$(run_gc arm --vault "$VAULT")
assert_contains "arm banner" "GRAPHMAP CADENCE ARMED" "$out"
luna_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Luna" 2>/dev/null || echo MISSING)
himmel_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Himmel" 2>/dev/null || echo MISSING)
assert_contains "luna daily schedule (XML)"   "<ScheduleByDay>" "$luna_args"
assert_contains "luna time (XML)"             "T13:00:00"       "$luna_args"
assert_contains "himmel daily schedule (XML)" "<ScheduleByDay>" "$himmel_args"
assert_contains "himmel time (XML)"           "T13:20:00"       "$himmel_args"
assert_contains "luna XML StartWhenAvailable"   "<StartWhenAvailable>true</StartWhenAvailable>" "$luna_args"
assert_contains "himmel XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$himmel_args"
assert_contains "luna Exec points at runner bat"   "graphmap-luna.bat"   "$luna_args"
assert_contains "himmel Exec points at runner bat" "graphmap-himmel.bat" "$himmel_args"

# Test 6: .bat runners fire refresh-graph-map.sh (deterministic, no claude) ---

echo "TEST: .bat runners fire bash refresh-graph-map.sh with the right payload"
luna_bat=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
himmel_bat=$(cat "$BAT_DIR/graphmap-himmel.bat" 2>/dev/null || echo MISSING)
assert_contains "luna bat stamps the format version (HIMMEL-588)"   "rem himmel-cadence-runner-format: 4" "$luna_bat"
assert_contains "himmel bat stamps the format version (HIMMEL-588)" "rem himmel-cadence-runner-format: 4" "$himmel_bat"
assert_contains "luna bat cds into himmel root" 'cd /d "' "$luna_bat"
assert_contains "luna bat fires refresh-graph-map.sh" "refresh-graph-map.sh" "$luna_bat"
assert_contains "luna bat names the luna corpus"      "--name luna"          "$luna_bat"
assert_contains "luna bat sets the luna slug"         "--slug graphify-luna-map" "$luna_bat"
assert_contains "luna bat sets the luna corpus-tag"   "--corpus-tag luna"    "$luna_bat"
assert_contains "luna bat uses the claude-cli backend"    "--backend claude-cli --corpus-tag" "$luna_bat"
assert_contains "luna bat sets the luna title"        "Graphify Luna Map"    "$luna_bat"
assert_contains "luna bat publishes into 60-Maps"     "60-Maps"              "$luna_bat"
assert_contains "luna bat appends run log" 'graphmap-luna.log" 2>&1' "$luna_bat"
assert_contains "luna bat rotates the log before firing" 'move /y' "$luna_bat"
assert_contains "luna bat stamps every fire" 'echo [fired %DATE% %TIME%]' "$luna_bat"
assert_contains "himmel bat names the himmel corpus"    "--name himmel"        "$himmel_bat"
assert_contains "himmel bat sets the himmel slug"       "--slug graphify-himmel-map" "$himmel_bat"
assert_contains "himmel bat sets the himmel corpus-tag" "--corpus-tag himmel"  "$himmel_bat"
assert_contains "himmel bat uses the claude-cli backend"    "--backend claude-cli --corpus-tag" "$himmel_bat"
# Strong per-corpus-root asserts on the Windows path too (bat_payload is a
# SEPARATE builder from the cron cron_payload, so the cron suite's exact asserts
# don't guard a Windows-only swap). VAULT is already mixed-form here, so it
# matches the cygpath -m'd corpus-root the .bat carries. The luna bat's
# corpus-root IS the vault; the himmel bat's corpus-root is NOT (it's the himmel
# repo) — so a swap that makes the himmel map extract the vault fails here.
assert_contains     "luna bat corpus-root is the vault"       "--corpus-root \"$VAULT\"" "$luna_bat"
assert_not_contains "himmel bat corpus-root is not the vault" "--corpus-root \"$VAULT\"" "$himmel_bat"
assert_contains     "himmel bat carries a corpus-root"        "--corpus-root"            "$himmel_bat"
assert_contains "himmel bat sets the himmel title"      "Graphify Himmel Map"  "$himmel_bat"
assert_contains "himmel bat appends run log" 'graphmap-himmel.log" 2>&1' "$himmel_bat"
for what in luna himmel; do
    body=$(eval "printf '%s' \"\$${what}_bat\"")
    assert_not_contains "$what bat has no --settings (not a claude session)" "--settings" "$body"
    assert_not_contains "$what bat has no bounded-claude stdin marker" "< NUL" "$body"
done

# Test 7: status after arm ---------------------------------------------------

echo "TEST: status reflects armed tasks"
out=$(run_gc status)
assert_contains "luna armed"   "ARMED      HIMMEL-GraphMap-Luna"   "$out"
assert_contains "himmel armed" "ARMED      HIMMEL-GraphMap-Himmel" "$out"
assert_contains "status surfaces run log state" "run log" "$out"

# Test 8: re-arm without --force -> dedup block ------------------------------

echo "TEST: re-arm without --force blocked (rc 3)"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "dedup block rc 3" 3 "$rc"
assert_contains "dedup message names existing tasks" "HIMMEL-GraphMap-Himmel" "$out"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 2 ]; then
    pass "no duplicate tasks after blocked re-arm"
else
    fail "task count changed on blocked re-arm" "$(ls "$STATE/tasks")"
fi

# Test 9: re-arm --force with overrides --------------------------------------

echo "TEST: re-arm --force applies flag overrides"
out=$(run_gc arm --vault "$VAULT" --force --luna-time 01:15 --himmel-time 05:00 2>&1)
luna_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Luna" 2>/dev/null || echo MISSING)
himmel_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Himmel" 2>/dev/null || echo MISSING)
assert_contains "luna override (XML time)"   "T01:15:00" "$luna_args"
assert_contains "himmel override (XML time)" "T05:00:00" "$himmel_args"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 2 ]; then
    pass "still exactly two tasks after --force re-arm"
else
    fail "duplicate tasks after --force re-arm" "$(ls "$STATE/tasks")"
fi

# Test 10: disarm + idempotent second disarm ---------------------------------

echo "TEST: disarm removes tasks + runners; second disarm is a no-op"
out=$(run_gc disarm)
assert_contains "disarm reports" "cadence disarmed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "all tasks removed"
else
    fail "tasks left after disarm" "$(ls "$STATE/tasks")"
fi
if [ ! -f "$BAT_DIR/graphmap-luna.bat" ] && [ ! -f "$BAT_DIR/graphmap-himmel.bat" ]; then
    pass ".bat runners removed"
else
    fail ".bat runners left after disarm"
fi
rc=0; out=$(run_gc disarm) || rc=$?
assert_rc "second disarm rc 0" 0 "$rc"
assert_contains "second disarm is a no-op" "no-op" "$out"

# Test 11: cmd_escape — hostile-but-legal vault dirname can't inject ----------

echo "TEST: vault path with CMD metachars is escaped in the .bat"
EVIL_VAULT="$TMP_ROOT/va&ult %X%^Y"
mkdir -p "$EVIL_VAULT"
out=$(run_gc arm --vault "$EVIL_VAULT")
luna_bat=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
assert_contains "percent doubled (%% in bat)" '%%X%%' "$luna_bat"
assert_contains "ampersand careted (^& in bat)" '^&' "$luna_bat"
assert_contains "caret doubled (^^ in bat)" '^^' "$luna_bat"
run_gc disarm >/dev/null

# Test 12: half-arm rollback when the SECOND /create fails --------------------

echo "TEST: himmel /create failure rolls back the luna task (rc 4)"
touch "$STATE/fail-create-HIMMEL-GraphMap-Himmel"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "half-arm fails rc 4" 4 "$rc"
assert_contains "failure names the himmel create" "HIMMEL-GraphMap-Himmel failed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task state left after rollback"
else
    fail "task state left after rollback" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-GraphMap-Himmel"

# Test 13: dedup listing failure is fail-CLOSED ------------------------------

echo "TEST: arm with failing /query listing exits 2 (fail-closed dedup)"
touch "$STATE/fail-query"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "fail-closed dedup rc 2" 2 "$rc"
assert_contains "dedup failure surfaces stderr" "Access is denied" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "nothing registered when dedup listing failed"
else
    fail "tasks registered despite failed dedup listing" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-query"

# Test 14: disarm under query failure must not no-op or delete runners --------

echo "TEST: disarm with failing /query exits nonzero, keeps the .bats"
out=$(run_gc arm --vault "$VAULT")
touch "$STATE/fail-query"
rc=0; out=$(run_gc disarm 2>&1) || rc=$?
assert_rc "disarm query failure rc 2" 2 "$rc"
assert_not_contains "no false no-op on query failure" "no-op" "$out"
assert_contains "query failure prints manual delete escape hatch" "schtasks /delete /tn" "$out"
if [ -f "$BAT_DIR/graphmap-luna.bat" ] && [ -f "$BAT_DIR/graphmap-himmel.bat" ]; then
    pass ".bat runners NOT deleted on query failure"
else
    fail ".bat runners deleted despite query failure"
fi
rm -f "$STATE/fail-query"
run_gc disarm >/dev/null

# Test 15: status propagates query errors as rc=2 ----------------------------

echo "TEST: status with failing /query exits 2"
out=$(run_gc arm --vault "$VAULT")
touch "$STATE/fail-query"
rc=0; out=$(run_gc status 2>&1) || rc=$?
assert_rc "status query failure rc 2" 2 "$rc"
assert_contains "status prints QUERY ERR" "QUERY ERR" "$out"
rm -f "$STATE/fail-query"
run_gc disarm >/dev/null

summary
