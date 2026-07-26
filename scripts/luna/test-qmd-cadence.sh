#!/usr/bin/env bash
# Smoke test for scripts/luna/qmd-cadence.sh (HIMMEL-568).
#
# ONE daily cadence task is armed: HIMMEL-Qmd-Reindex (daily 05:00 ->
# qmd-reindex.sh --qmd-bin <qmd>). Like the graphmap sibling — and unlike
# pipeline-cadence — the runner fires a DETERMINISTIC script, NOT a claude
# session, so there is no --settings fragment, no NUL stdin and no auto-approve
# hook to assert; the suite asserts their ABSENCE instead.
#
# Strategy (hermetic — mirrors test-graphmap-cadence.sh): replace the scheduler
# with a fake — schtasks via the QMD_CADENCE_SCHTASKS seam (records /create XML
# and simulates /query and /delete from a state dir), crontab via the
# QMD_CADENCE_CRONTAB seam (a state-file crontab supporting -l and - install);
# point QMD_CADENCE_BAT_DIR at a temp dir so the runner (.bat/.sh) is
# inspectable; put a fake `bash` first on PATH so arm resolves the stub, never
# the real interpreter. HOME/USERPROFILE point at the temp dir so nothing
# touches the real user profile. The cron suite runs on EVERY platform (the
# POSIX path is forced with an OSTYPE override); the schtasks suite stays
# Windows-only (cmd_arm needs cygpath).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/qmd-cadence.sh"

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
# Match with a HERE-STRING, not `printf … | grep -q` (HIMMEL-1115). Under the
# `set -o pipefail` in force here, grep -q exits early on a match, printf takes
# SIGPIPE (141), and pipefail surfaces 141 as the pipeline status — so a
# SUCCESSFUL match reads as a FAILURE as soon as the haystack outgrows the pipe
# buffer. This suite asserts against whole runner-file bodies, so it is the one
# most likely to grow into that trap.
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
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

# The interpreter that runs the script under test. Resolved BEFORE the fake bash
# below shadows PATH: `env PATH=... bash` would exec the FAKE via the NEW PATH,
# and on Linux the fake's own `#!/usr/bin/env bash` shebang re-resolves to itself
# -> infinite exec loop -> the suite hangs to the CI timeout.
REAL_BASH="$(command -v bash)"

# Fake bash on PATH (arm resolves it via `command -v bash`). A no-op stub is
# enough — the tests assert runner TEXT, they never fire the runner. Shebang is
# /bin/sh (absolute) so the stub can never shebang-recurse into itself.
mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/bash"
chmod +x "$TMP_ROOT/bin/bash"

# Fake `qmd` on PATH: arm resolves it via `command -v qmd` and FAILS FAST when
# absent, because the scheduler fires with a minimal PATH that does not carry
# qmd's bin dir (bun installs to ~/.bun/bin). A stub keeps the suite
# deterministic on machines with and without a real qmd installed; like the bash
# stub it is never fired, only resolved.
#
# It lives in its OWN dir, entered on PATH in POSIX form, for the same two
# reasons the graphmap sibling's claude stub does: (1) TMP_ROOT is cygpath -m'd
# (C:/... mixed form) and Git-Bash cannot resolve a PATH entry in that form — a
# stub in `bin` is INVISIBLE on Windows, so the arm would silently resolve the
# operator's REAL installed qmd and the runner assertions below would pin a
# machine-specific path; (2) adding a POSIX entry for `bin` itself would newly
# expose the fake `bash` on Windows, changing what the suite bakes into its
# runners.
QMD_BIN_DIR="$TMP_ROOT/qmd-bin"
mkdir -p "$QMD_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$QMD_BIN_DIR/qmd"
chmod +x "$QMD_BIN_DIR/qmd"
QMD_BIN_DIR_PATH="$QMD_BIN_DIR"
if command -v cygpath >/dev/null 2>&1; then
    QMD_BIN_DIR_PATH=$(cygpath -u "$QMD_BIN_DIR")
fi
# EVERY invocation that reaches `arm` must carry $QMD_BIN_DIR_PATH on PATH — arm
# fail-fasts when `qmd` is absent. Omitting it would NOT fail on a dev box that
# happens to have qmd installed: the inherited $PATH tail satisfies the probe by
# ACCIDENT, so the suite goes green locally and dies on a clean CI runner with
# rc=2. The stub keeps the suite hermetic — a test's result must never depend on
# what the operator has installed.

# A PATH with the real system dirs (arm needs dirname/sed/mktemp) but with EVERY
# dir carrying a real `qmd` filtered out — the fail-fast probe below must not be
# satisfied by an installed qmd. Filtering the real PATH beats replacing it: a
# bare stub dir strips coreutils and the script dies rc=127 on `dirname` before
# it ever reaches the check under test.
PATH_NOQMD=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/qmd" ] || [ -x "$_d/qmd.exe" ] || [ -x "$_d/qmd.cmd" ]; then continue; fi
    PATH_NOQMD="${PATH_NOQMD:+$PATH_NOQMD:}$_d"
done
IFS=$_oldifs

# Hermeticity: point HOME **and USERPROFILE** at the temp dir so a stray BAT_DIR
# default (should the seam ever be dropped) can't land under the real user
# profile. USERPROFILE is the load-bearing one on Windows: resolve_user_home
# prefers it (via cygpath) BEFORE $HOME, so redirecting HOME alone would leave
# the probe pointing at the operator's actual profile on exactly the platform
# this cadence primarily runs on.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export USERPROFILE="$HOME"
# BUN_INSTALL too (HIMMEL-1283 CR): arm resolves qmd through
# qmd_pinned_invocation, whose FIRST branch looks for the bun-served install at
# $BUN_INSTALL/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js — before
# it consults PATH at all. BUN_INSTALL defaults to $HOME/.bun, so redirecting
# HOME happens to cover it today; that makes hermeticity INCIDENTAL, and an
# operator with BUN_INSTALL exported would silently arm against their REAL qmd
# instead of the fixture. Pin it explicitly at a path that does not exist. Tests
# that WANT the bun branch set BUN_INSTALL to their own fixture per-invocation.
export BUN_INSTALL="$TMP_ROOT/bun-none"

# The himmel root the runner cds into is this script's ../.. (same resolution
# qmd-cadence.sh uses for HIMMEL_ROOT).
HIMMEL_ROOT_EXP="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# xml_escape unit — the one non-trivial string transform. Pure + platform-
# agnostic, so it runs on EVERY platform: extract the function and call it.
# ============================================================================
echo "TEST: xml_escape escapes & < > with & ordered first"
xesc=$( { sed -n '/^xml_escape()/,/^}/p' "$SCRIPT"; echo "xml_escape 'a & b < c > d'"; } | bash )
assert_contains "xml_escape produces well-formed entities (& first)" "a &amp; b &lt; c &gt; d" "$xesc"
assert_not_contains "xml_escape leaves no bare ampersand" "a & b" "$xesc"

# ============================================================================
# POSIX (cron) suite. Runs on EVERY platform: the cron code path is forced via
# an OSTYPE override + the QMD_CADENCE_CRONTAB seam.
# ============================================================================

CSTATE="$TMP_ROOT/cron-state"
mkdir -p "$CSTATE"

# Fake crontab: persists the installed tab at $CSTATE/crontab. Mimics real
# crontab signatures: -l with no tab prints "no crontab for <user>" + rc=1;
# `crontab -` installs from stdin. Failure seams: $CSTATE/fail-list,
# $CSTATE/fail-write. Shebang MUST be /bin/sh (absolute, POSIX body):
# `#!/usr/bin/env bash` would resolve the no-op fake `bash` stub via the
# prepended PATH on Linux, turning every crontab call into a silent no-op.
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
    env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
        QMD_CADENCE_BAT_DIR="$CRON_DIR" PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

# Test C0: usage errors -------------------------------------------------------

echo "TEST: missing / unknown subcommand rejected"
rc=0; out=$(run_cron 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(run_cron frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --nope 2>&1) || rc=$?
assert_rc "unknown flag -> rc 1" 1 "$rc"

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron reindex not armed" "not armed  HIMMEL-Qmd-Reindex" "$out"
assert_contains "status names the scope" "all collections" "$out"

# Test C2: shared validation wired into the cron path ------------------------

echo "TEST: cron arm rejects invalid --time (shared validation)"
rc=0; out=$(run_cron arm --time 24:61 2>&1) || rc=$?
assert_rc "cron bad --time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --time 5:00 2>&1) || rc=$?
assert_rc "cron --time without leading zero -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --time 25:00 2>&1) || rc=$?
assert_rc "cron out-of-range --time -> rc 1" 1 "$rc"
# A trailing `--time` must produce a MESSAGE + rc 1, not a silent set -e death
# on the failing `shift 2`.
rc=0; out=$(run_cron arm --time 2>&1) || rc=$?
assert_rc "cron trailing --time -> rc 1" 1 "$rc"
assert_contains "trailing --time explains itself" "--time requires a value" "$out"

# Test C3: arm fails fast when `qmd` is absent -------------------------------
#
# The cadence runs qmd at fire time under the scheduler's minimal PATH. Arming
# on a machine without it would "succeed" and then die on every unattended fire,
# in a log nobody reads. PATH is REPLACED (not prepended) so a really-installed
# qmd cannot satisfy the probe here.

echo "TEST: cron arm fails fast when qmd is not on PATH"
rc=0; out=$(env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$CRON_DIR" PATH="$PATH_NOQMD" \
    "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "cron arm without qmd -> rc 2" 2 "$rc"
assert_contains "missing-qmd error names the CLI" "no usable qmd found at arm time" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "failed arm installed nothing"
else
    fail "failed arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C4: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --dry-run)
assert_contains "dry-run daily entry at 05:00" "00 05 * * *" "$out"
assert_contains "dry-run marker" "# HIMMEL-Qmd-Reindex" "$out"
assert_contains "dry-run fires qmd-reindex.sh" "qmd-reindex.sh" "$out"
assert_contains "dry-run pins the qmd binary" "--qmd-bin" "$out"
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

# Test C5: arm installs a marker-tagged entry, preserves unrelated lines ------

echo "TEST: cron arm installs the entry with defaults, preserves unrelated lines"
printf '5 5 * * * /usr/bin/true # keep-me\n' > "$CSTATE/crontab"
out=$(run_cron arm)
assert_contains "cron arm banner" "QMD REINDEX CADENCE ARMED" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "daily entry 05:00" "00 05 * * *" "$tab"
assert_contains "entry marker-tagged" "# HIMMEL-Qmd-Reindex" "$tab"
assert_contains "entry fires the runner" "qmd-reindex.sh" "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
if [ -x "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "runner .sh written + executable"
else
    fail "runner .sh missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi

# Test C6: the runner .sh fires qmd-reindex.sh with the right arguments -------

echo "TEST: runner .sh fires bash qmd-reindex.sh (deterministic, no claude)"
runner=$(cat "$CRON_DIR/qmd-reindex.sh" 2>/dev/null || echo MISSING)
# The sh runner embeds paths via printf %q (backslash-escapes); strip the
# escapes before multi-word / path asserts.
runner_plain=${runner//\\/}
assert_contains "runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: 5" "$runner"
assert_contains "runner fires qmd-reindex.sh" "qmd-reindex.sh" "$runner_plain"
assert_contains "runner points at the SHIPPED reindex script" \
    "$HIMMEL_ROOT_EXP/scripts/luna/qmd-reindex.sh" "$runner_plain"
# The qmd path must be PINNED into the runner: cron fires with a minimal PATH
# that lacks qmd's bin dir, so a runner relying on PATH lookup dies on every
# fire. Assert the stub's absolute path specifically — not just the flag — so a
# regression to bare `qmd` fails here.
# Assert the POSIX-form path: `command -v qmd` resolves through the POSIX PATH
# entry, so on Windows the runner carries /c/... not the mixed C:/... form.
assert_contains "runner pins the resolved qmd absolute path" \
    "--qmd-bin $QMD_BIN_DIR_PATH/qmd" "$runner_plain"
assert_contains "runner cds into himmel root" "cd $HIMMEL_ROOT_EXP" "$runner_plain"
# shellcheck disable=SC2016  # literal $log needles — the runner expands them at fire time
assert_contains "runner rotates the log" 'mv -f "$log" "$log.prev"' "$runner"
assert_contains "runner stamps every fire" '[fired' "$runner"
# shellcheck disable=SC2016
assert_contains "runner captures output to log" '>> "$log" 2>&1' "$runner"
# shellcheck disable=SC2016
assert_contains "runner records the exit rc" 'echo "[exit rc=$_rc]"' "$runner"
# Deterministic-script shape: NONE of the bounded-claude-session markers.
assert_not_contains "runner has no --settings (not a claude session)" "--settings" "$runner"
assert_not_contains "runner has no bounded-claude stdin marker" "< /dev/null" "$runner"
assert_not_contains "runner never narrows collections with -c" "-c " "$runner"

# Test C6b: the runner PROPAGATES the payload's exit code ------------------------
#
# Behavioural, not textual: rewrite the generated runner's payload to a known
# failing/succeeding command and FIRE it, asserting the script's own exit status.
# Without the trailing `exit "$_rc"` the runner's status is that of the final
# `echo` inside the redirect block — always 0 — so cron reports success after a
# failed reindex, which is the silent-failure shape this whole ticket is about.

echo "TEST: generated cron runner propagates the payload exit code"
runner_src=$(cat "$CRON_DIR/qmd-reindex.sh")
probe_dir="$TMP_ROOT/rc-probe"
mkdir -p "$probe_dir"
# Swap the payload line for a parameterised exit, keeping every other line
# (log rotation, fire stamp, cd, the exit propagation) byte-identical.
for want_rc in 0 5; do
    # `@` delimiter, NOT `|`: the replacements contain `||`, which sed would
    # read as the closing delimiter followed by garbage.
    printf '%s\n' "$runner_src" \
        | sed "s@^    _rc=0; .*@    _rc=0; (exit $want_rc) || _rc=\$?@" \
        | sed "s@^    cd .*@    cd . || exit 1@" \
        > "$probe_dir/runner-$want_rc.sh"
    chmod +x "$probe_dir/runner-$want_rc.sh"
    # If the runner's payload line ever changes shape, the sed matches NOTHING
    # and the probe silently fires the REAL reindex payload instead — which
    # would quietly pass the rc=0 case and make this test meaningless. Assert
    # the substitution actually landed rather than trusting it.
    if ! grep -qF "(exit $want_rc) ||" "$probe_dir/runner-$want_rc.sh"; then
        fail "rc-probe payload substitution matched nothing" \
            "runner payload line shape changed; update the sed expression"
        continue
    fi
    got_rc=0
    "$REAL_BASH" "$probe_dir/runner-$want_rc.sh" >/dev/null 2>&1 || got_rc=$?
    assert_rc "runner exits $want_rc when the payload exits $want_rc" "$want_rc" "$got_rc"
done

# Test C7: status after arm ----------------------------------------------------

echo "TEST: cron status reflects the armed entry"
out=$(run_cron status)
assert_contains "cron reindex armed" "ARMED      HIMMEL-Qmd-Reindex" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"

# Test C8: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names the existing entry" "HIMMEL-Qmd-Reindex" "$out"
if [ "$(grep -c 'HIMMEL-Qmd-' "$CSTATE/crontab")" -eq 1 ]; then
    pass "no duplicate entry after blocked re-arm (idempotent)"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C9: re-arm --force with an override --------------------------------------

echo "TEST: cron re-arm --force applies the --time override"
out=$(run_cron arm --force --time 01:15 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "cron daily override" "15 01 * * *" "$tab"
assert_not_contains "old 05:00 entry replaced" "00 05 * * *" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-Qmd-' "$CSTATE/crontab")" -eq 1 ]; then
    pass "still exactly one entry after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C10: dry-run disarm prints the DRY tail, touches nothing -----------------

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-Qmd-' "$CSTATE/crontab")" -eq 1 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "dry-run disarm kept the runner .sh"
else
    fail "dry-run disarm deleted the runner .sh"
fi

# Test C11: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes the entry + runner, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entry removed" "HIMMEL-Qmd-" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "runner .sh removed"
else
    fail "runner .sh left after disarm"
fi
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C12: failing crontab -l is fail-CLOSED -------------------------------------

echo "TEST: cron arm/status/disarm with failing crontab -l exit 2"
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron arm 2>&1) || rc=$?
assert_rc "cron fail-closed arm rc 2" 2 "$rc"
assert_contains "cron arm failure surfaces stderr" "must be privileged" "$out"
rc=0; out=$(run_cron status 2>&1) || rc=$?
assert_rc "cron fail-closed status rc 2" 2 "$rc"
rm -f "$CSTATE/fail-list"
out=$(run_cron arm)
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on failing crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "runner .sh NOT deleted on crontab -l failure"
else
    fail "runner .sh deleted despite crontab -l failure"
fi
rm -f "$CSTATE/fail-list"
run_cron disarm >/dev/null

# Test C13: crontab install failure -> rc 4 ---------------------------------------

echo "TEST: cron arm with failing crontab install exits 4"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm 2>&1) || rc=$?
assert_rc "cron install failure rc 4" 4 "$rc"
assert_contains "cron install failure surfaces stderr" "error writing new crontab" "$out"
if ! grep -q 'HIMMEL-Qmd-' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entry installed on write failure"
else
    fail "cadence entry installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "no runner promoted to its final path on write failure"
else
    fail "runner left despite write failure" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter on write failure"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C14: --force re-arm with failing install leaves NO half-state --------------

echo "TEST: cron --force re-arm with failing install keeps the old runner + entry"
out=$(run_cron arm --time 05:00)
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --force --time 06:30 2>&1) || rc=$?
assert_rc "cron force re-arm install failure rc 4" 4 "$rc"
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter after failed --force re-arm"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "old 05:00 entry still armed after failed --force re-arm" "00 05 * * *" "$tab"
assert_not_contains "new 06:30 entry NOT installed" "30 06 * * *" "$tab"
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C15: disarm with failing install keeps entry + runner ----------------------

echo "TEST: cron disarm with failing crontab install exits 4, keeps entry + runner"
out=$(run_cron arm)
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron disarm install failure rc 4" 4 "$rc"
assert_contains "disarm install failure surfaces stderr" "error writing new crontab" "$out"
if [ "$(grep -c 'HIMMEL-Qmd-' "$CSTATE/crontab")" -eq 1 ]; then
    pass "entry still in crontab after failed disarm install"
else
    fail "entry lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/qmd-reindex.sh" ]; then
    pass "runner .sh NOT deleted on failed disarm install"
else
    fail "runner .sh deleted despite failed disarm install"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C16: hostile-but-legal runner dir can't inject -----------------------------

echo "TEST: cron entry + runner escape a hostile runner dir"
EVIL_DIR="$TMP_ROOT/cr%on rnr"
out=$(env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" arm)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" disarm >/dev/null

# Test C18: LIVENESS — a qmd that EXISTS but errors must refuse to arm --------
#
# HIMMEL-1283, the core of the ticket. Every pre-existing guard here proves
# "a file exists, is absolute, and is executable" — which the broken
# Claude-plugin stub satisfies perfectly. It resolves, arms cleanly, and then
# dies on every unattended fire with `Module not found ... dist/cli/qmd.js`.
# So arm must RUN the resolved invocation and refuse on a nonzero rc.
# The fixture is that stub: a qmd earlier on PATH that execs fine and exits 1.

echo "TEST: cron arm REFUSES a qmd that resolves but errors (liveness, C18)"
STUB_DIR="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_DIR"
printf '#!/bin/sh\necho "error: Module not found \\"/plugins/cache/qmd/dist/cli/qmd.js\\"" >&2\nexit 1\n' \
    > "$STUB_DIR/qmd"
chmod +x "$STUB_DIR/qmd"
# PATH entries must be POSIX form: TMP_ROOT is cygpath -m'd (C:/... mixed) and
# Git-Bash cannot resolve a mixed-form PATH entry, so a stub added raw is
# INVISIBLE on Windows and the test silently exercises "no qmd at all" instead
# of "a qmd that errors" — the same trap the qmd/claude stub dirs above document.
STUB_DIR_PATH="$STUB_DIR"
if command -v cygpath >/dev/null 2>&1; then STUB_DIR_PATH=$(cygpath -u "$STUB_DIR"); fi
rc=0; out=$(env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$CRON_DIR" PATH="$STUB_DIR_PATH:$PATH_NOQMD" \
    "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "arm with a broken-but-present qmd -> rc 2" 2 "$rc"
assert_contains "liveness failure says NOT USABLE" "NOT USABLE" "$out"
assert_contains "liveness failure surfaces the probe output" "Module not found" "$out"
# Assert what THIS arm did, not that the dir is pristine: earlier tests in this
# suite legitimately leave a qmd-reindex.log behind, and a stale log is not
# state a refusing arm installed. The two things that must be absent are the
# runner it would have written and a crontab entry it would have registered.
if [ ! -f "$CRON_DIR/qmd-reindex.sh" ] \
   && ! grep -q 'HIMMEL-Qmd' "$CSTATE/crontab" 2>/dev/null; then
    pass "broken-qmd arm installed no runner and no cron entry"
else
    fail "broken-qmd arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C19: a bun-served qmd is pinned as TWO tokens (--qmd-bin + --qmd-js) ----
#
# The resolver prefers the bun-served install, whose canonical invocation is
# `bun <.../dist/cli/qmd.js>` — neither token is a `qmd` executable, so the
# single-path pin could not express it. Assert the runner carries both flags
# and that the js path is the bun-global one, not whatever was on PATH.

echo "TEST: bun-served qmd pins --qmd-bin <bun> --qmd-js <qmd.js> (C19)"
BUN_ROOT="$TMP_ROOT/bunroot"
BUN_JS_DIR="$BUN_ROOT/install/global/node_modules/@tobilu/qmd/dist/cli"
mkdir -p "$BUN_JS_DIR" "$TMP_ROOT/bun-bin"
printf 'console.log("stub");\n' > "$BUN_JS_DIR/qmd.js"
# Fake `bun`: the liveness probe runs `<bun> <qmd.js> collection list`, so it
# must exit 0. Prints a plausible collection listing.
printf '#!/bin/sh\necho "himmel (qmd://himmel/)"\nexit 0\n' > "$TMP_ROOT/bun-bin/bun"
chmod +x "$TMP_ROOT/bun-bin/bun"
BUN_BIN_PATH="$TMP_ROOT/bun-bin"
if command -v cygpath >/dev/null 2>&1; then BUN_BIN_PATH=$(cygpath -u "$TMP_ROOT/bun-bin"); fi
# The resolver reports whatever `command -v bun` yields, which under a POSIX
# PATH entry is the POSIX path — assert against that same form.
BUN_EXPECTED="$BUN_BIN_PATH/bun"
# Capture the arm rc and assert it BEFORE reading the runner: without this a
# failed arm shows up only as a confusing "MISSING" in the pin assertions, with
# arm's own diagnosis discarded.
rc=0; out=$(env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$CRON_DIR" BUN_INSTALL="$BUN_ROOT" \
    PATH="$BUN_BIN_PATH:$STUB_DIR_PATH:$PATH_NOQMD" \
    "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "bun-served arm succeeds" 0 "$rc"
[ "$rc" -eq 0 ] || printf '    arm output:\n%s\n' "$out" | sed 's/^/    /'
runner=$(cat "$CRON_DIR/qmd-reindex.sh" 2>/dev/null || echo MISSING)
assert_contains "runner pins --qmd-bin at the bun executable" "--qmd-bin $BUN_EXPECTED" "$runner"
assert_contains "runner pins --qmd-js at the bun-global qmd.js" "--qmd-js $BUN_JS_DIR/qmd.js" "$runner"
assert_not_contains "the broken PATH stub is NOT what got pinned" "$STUB_DIR/qmd" "$runner"
env OSTYPE=linux-gnu QMD_CADENCE_CRONTAB="$FAKE_CRONTAB" \
    QMD_CADENCE_BAT_DIR="$CRON_DIR" BUN_INSTALL="$BUN_ROOT" \
    PATH="$BUN_BIN_PATH:$STUB_DIR_PATH:$PATH_NOQMD" \
    "$REAL_BASH" "$SCRIPT" disarm >/dev/null 2>&1 || true

# Test C17: unknown platform exits 2 ----------------------------------------------

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

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/tasks"

# Fake schtasks: persists tasks as files under $STATE/tasks/<name> (content =
# the created XML, for assertions). Shebang is the pre-resolved REAL bash (the
# body needs bash arrays) — an env-bash shebang would resolve the no-op fake
# `bash` stub via the prepended PATH.
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
                printf 'TaskName:      \\%s\nNext Run Time: 7/26/2026 5:00:00 AM\n' "$tn"
                exit 0
            fi
            echo "ERROR: The system cannot find the file specified." >&2
            exit 1
        fi
        found=0
        for f in "$STATE/tasks"/*; do
            [ -e "$f" ] || continue
            found=1
            printf '"\\%s","7/26/2026 5:00:00 AM","Ready"\n' "$(basename "$f")"
        done
        [ "$found" -eq 1 ] || exit 1
        ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS"

BAT_DIR="$TMP_ROOT/bats"

run_qc() {
    QMD_CADENCE_SCHTASKS="$FAKE_SCHTASKS" QMD_CADENCE_BAT_DIR="$BAT_DIR" \
        PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" "$REAL_BASH" "$SCRIPT" "$@"
}

# Test W1: status on an empty scheduler --------------------------------------

echo "TEST: schtasks status with nothing armed"
out=$(run_qc status)
assert_contains "reindex not armed" "not armed  HIMMEL-Qmd-Reindex" "$out"

# Test W2: arm --dry-run registers nothing -----------------------------------

echo "TEST: schtasks arm --dry-run prints plan, registers nothing"
out=$(run_qc arm --dry-run)
assert_contains "dry-run create line" "/tn HIMMEL-Qmd-Reindex /xml" "$out"
assert_contains "dry-run XML has StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$out"
assert_contains "dry-run XML daily schedule" "<ScheduleByDay>" "$out"
assert_contains "dry-run default time" "T05:00:00" "$out"
assert_contains "dry-run fires qmd-reindex.sh" "qmd-reindex.sh" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "dry-run registered no tasks"
else
    fail "dry-run registered tasks" "$(ls "$STATE/tasks")"
fi
if [ ! -d "$BAT_DIR" ]; then
    pass "dry-run wrote no .bat"
else
    fail "dry-run wrote a .bat" "$(ls "$BAT_DIR")"
fi

# Test W3: arm registers the daily task --------------------------------------

echo "TEST: schtasks arm registers HIMMEL-Qmd-Reindex daily 05:00"
out=$(run_qc arm)
assert_contains "arm banner" "QMD REINDEX CADENCE ARMED" "$out"
task_xml=$(cat "$STATE/tasks/HIMMEL-Qmd-Reindex" 2>/dev/null || echo MISSING)
assert_contains "daily schedule (XML)" "<ScheduleByDay>" "$task_xml"
assert_contains "default time (XML)" "T05:00:00" "$task_xml"
assert_contains "XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$task_xml"
# IgnoreNew is what keeps the cadence from overlapping itself — qmd-reindex.sh
# deliberately takes no lock of its own, so this is the only serialization.
assert_contains "XML IgnoreNew (no self-overlap)" "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" "$task_xml"
assert_contains "XML names the ticket" "HIMMEL-568" "$task_xml"
assert_contains "Exec points at the runner bat" "qmd-reindex.bat" "$task_xml"

# Test W4: the .bat fires qmd-reindex.sh with the right arguments -------------

echo "TEST: .bat runner fires bash qmd-reindex.sh (deterministic, no claude)"
bat=$(cat "$BAT_DIR/qmd-reindex.bat" 2>/dev/null || echo MISSING)
assert_contains "bat stamps the format version (HIMMEL-588)" "rem himmel-cadence-runner-format: 5" "$bat"
assert_contains "bat cds into himmel root" 'cd /d "' "$bat"
assert_contains "bat fires qmd-reindex.sh" "qmd-reindex.sh" "$bat"
assert_contains "bat pins the resolved qmd absolute path" "--qmd-bin \"$QMD_BIN_DIR/qmd\"" "$bat"
assert_contains "bat appends run log" 'qmd-reindex.log" 2>&1' "$bat"
assert_contains "bat rotates the log before firing" 'move /y' "$bat"
assert_contains "bat stamps every fire" 'echo [fired %DATE% %TIME%]' "$bat"
assert_not_contains "bat has no --settings (not a claude session)" "--settings" "$bat"
assert_not_contains "bat has no bounded-claude stdin marker" "< NUL" "$bat"
assert_not_contains "bat never narrows collections with -c" " -c " "$bat"

# Test W5: status after arm ---------------------------------------------------

echo "TEST: schtasks status reflects the armed task"
out=$(run_qc status)
assert_contains "reindex armed" "ARMED      HIMMEL-Qmd-Reindex" "$out"
assert_contains "status shows next run time" "next run:" "$out"
assert_contains "status surfaces run log state" "run log" "$out"

# Test W6: re-arm without --force -> dedup block ------------------------------

echo "TEST: schtasks re-arm without --force blocked (rc 3)"
rc=0; out=$(run_qc arm 2>&1) || rc=$?
assert_rc "dedup block rc 3" 3 "$rc"
assert_contains "dedup message names the existing task" "HIMMEL-Qmd-Reindex" "$out"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 1 ]; then
    pass "no duplicate task after blocked re-arm (idempotent)"
else
    fail "task count changed on blocked re-arm" "$(ls "$STATE/tasks")"
fi

# Test W7: re-arm --force applies the override --------------------------------

echo "TEST: schtasks re-arm --force applies the --time override"
out=$(run_qc arm --force --time 01:15 2>&1)
task_xml=$(cat "$STATE/tasks/HIMMEL-Qmd-Reindex" 2>/dev/null || echo MISSING)
assert_contains "override time (XML)" "T01:15:00" "$task_xml"
assert_not_contains "old default time replaced" "T05:00:00" "$task_xml"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 1 ]; then
    pass "still exactly one task after --force re-arm"
else
    fail "duplicate tasks after --force re-arm" "$(ls "$STATE/tasks")"
fi

# Test W8: schtasks /create failure -> rc 4 -----------------------------------

echo "TEST: schtasks create failure exits 4"
run_qc disarm >/dev/null
touch "$STATE/fail-create-HIMMEL-Qmd-Reindex"
rc=0; out=$(run_qc arm 2>&1) || rc=$?
assert_rc "create failure rc 4" 4 "$rc"
assert_contains "create failure surfaces stderr" "Access is denied" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task registered on create failure"
else
    fail "task registered despite create failure" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-Qmd-Reindex"

# Test W8b: failed --force re-arm leaves the OLD .bat untouched -----------------
#
# Mirrors the POSIX C14 case. Writing the .bat in place before schtasks /create
# would leave the runner carrying the NEW config while the scheduler has no new
# task — and under --force the OLD task is already gone by then.

echo "TEST: schtasks --force re-arm with failing create keeps the old .bat"
out=$(run_qc arm --time 05:00)
old_bat=$(cat "$BAT_DIR/qmd-reindex.bat")
touch "$STATE/fail-create-HIMMEL-Qmd-Reindex"
rc=0; out=$(run_qc arm --force --time 06:30 2>&1) || rc=$?
assert_rc "force re-arm create failure rc 4" 4 "$rc"
new_bat=$(cat "$BAT_DIR/qmd-reindex.bat" 2>/dev/null || echo MISSING)
if [ "$new_bat" = "$old_bat" ]; then
    pass "old .bat byte-identical after failed --force re-arm"
else
    fail "old .bat was overwritten despite failed create"
fi
if ! compgen -G "$BAT_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp .bat litter after failed create"
else
    fail "staged .tmp .bat litter left" "$(ls "$BAT_DIR")"
fi
# --force already deleted the old task before the create failed, so the machine
# is now UNARMED. The message must say that outright — "runner .bat left
# untouched" alone reads as "nothing changed", the opposite of the truth.
assert_contains "failed --force create warns the machine is now unarmed" \
    "NO qmd cadence is armed right now" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "and the scheduler really is empty (warning is accurate)"
else
    fail "warning claims unarmed but a task remains" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-Qmd-Reindex"
run_qc disarm >/dev/null

# Test W8c: disarm removes EVERY HIMMEL-Qmd-* task, not just the canonical name --
#
# `arm`'s dedup guard blocks on the PREFIX, so a disarm that only knew the exact
# name would wedge the operator: arm refuses "already armed", disarm answers
# "nothing armed". The POSIX path already disarms by prefix.

echo "TEST: schtasks disarm removes every HIMMEL-Qmd-* task (prefix, not exact name)"
out=$(run_qc arm)
printf 'stray task\n' > "$STATE/tasks/HIMMEL-Qmd-Stray"
rc=0; out=$(run_qc arm 2>&1) || rc=$?
assert_rc "arm dedup-blocks on the stray prefix task" 3 "$rc"
out=$(run_qc disarm)
if [ ! -f "$STATE/tasks/HIMMEL-Qmd-Stray" ] && [ ! -f "$STATE/tasks/HIMMEL-Qmd-Reindex" ]; then
    pass "disarm removed BOTH the canonical and the stray prefix task"
else
    fail "disarm left a prefix task behind" "$(ls "$STATE/tasks" 2>/dev/null)"
fi
rc=0; out=$(run_qc arm 2>&1) || rc=$?
assert_rc "arm works again after a full disarm (no wedge)" 0 "$rc"
run_qc disarm >/dev/null

# Test W9: failing /query is fail-CLOSED --------------------------------------

echo "TEST: schtasks failing /query is fail-closed (rc 2)"
out=$(run_qc arm)
touch "$STATE/fail-query"
rc=0; out=$(run_qc status 2>&1) || rc=$?
assert_rc "fail-closed status rc 2" 2 "$rc"
# Match the STATUS LINE shape, not the bare phrase: the fail-closed error itself
# legitimately reads "refusing to treat as 'not armed'", so a bare needle would
# match the very message that proves the guard worked.
assert_not_contains "no false 'not armed' status line on query failure" \
    "not armed  HIMMEL-Qmd-Reindex" "$out"
assert_contains "query failure is reported as such" "QUERY ERR" "$out"
rc=0; out=$(run_qc disarm 2>&1) || rc=$?
assert_rc "fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on query failure" "no-op" "$out"
rm -f "$STATE/fail-query"

# Test W10: disarm + idempotent second disarm ---------------------------------

echo "TEST: schtasks disarm removes the task + .bat, second disarm is a no-op"
out=$(run_qc disarm)
assert_contains "disarm reports" "cadence disarmed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "task removed"
else
    fail "task left after disarm" "$(ls "$STATE/tasks")"
fi
if [ ! -f "$BAT_DIR/qmd-reindex.bat" ]; then
    pass ".bat runner removed"
else
    fail ".bat runner left after disarm"
fi
rc=0; out=$(run_qc disarm) || rc=$?
assert_rc "second disarm rc 0" 0 "$rc"
assert_contains "second disarm is a no-op" "no-op" "$out"

# Test W11: dry-run disarm touches nothing ------------------------------------

echo "TEST: schtasks dry-run disarm prints DRY tail, touches nothing"
out=$(run_qc arm)
out=$(run_qc disarm --dry-run)
assert_contains "dry disarm lists the deletion" "would delete HIMMEL-Qmd-Reindex" "$out"
assert_contains "dry disarm closing summary" "no changes made" "$out"
if [ -f "$STATE/tasks/HIMMEL-Qmd-Reindex" ] && [ -f "$BAT_DIR/qmd-reindex.bat" ]; then
    pass "dry-run disarm left task + .bat in place"
else
    fail "dry-run disarm mutated state"
fi
run_qc disarm >/dev/null

# Test W12: hostile-but-legal BAT_DIR lands on the REAL dir in the .bat -------
#
# HIMMEL-1281: every value the emitter interpolates sits inside double quotes,
# where cmd.exe treats & < > | as literal data and ^ as a literal character.
# So the only transform cadence_cmd_escape applies is % -> %% (percent
# expansion DOES happen inside quotes in a .bat). The caret escaping this
# replaced turned `rnr&x^y` into `rnr^&x^^y` — a path that does not exist, so
# the runner's `>>` redirect pointed at a directory cmd could not open.

echo "TEST: hostile %&^ in BAT_DIR lands on the REAL dir in the .bat (W12)"
EVIL_BAT_DIR="$TMP_ROOT/cr%on rnr&x^y"
mkdir -p "$EVIL_BAT_DIR"
out=$(QMD_CADENCE_SCHTASKS="$FAKE_SCHTASKS" QMD_CADENCE_BAT_DIR="$EVIL_BAT_DIR" \
    PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" "$REAL_BASH" "$SCRIPT" arm)
evil_bat=$(cat "$EVIL_BAT_DIR/qmd-reindex.bat" 2>/dev/null || echo MISSING)
# Assert the WHOLE `>> "<path>"` redirect as ONE contiguous string — separate
# opening/closing checks could match in two different places, and the quoting
# is exactly what makes the escape correct. Built the way the emitter builds
# it (cygpath -w the bat dir, append the log name, then % -> %%).
EVIL_BAT_DIR_WIN=$(cygpath -w "$EVIL_BAT_DIR")
EVIL_LOG_EXPECTED=">> \"${EVIL_BAT_DIR_WIN//%/%%}\\qmd-reindex.log\""
assert_contains "log redirect targets the real dir, fully quoted (% doubled, & ^ verbatim)" \
    "$EVIL_LOG_EXPECTED" "$evil_bat"
assert_not_contains "no caret-escaped ampersand" '^&' "$evil_bat"
assert_not_contains "no doubled caret" '^^' "$evil_bat"
QMD_CADENCE_SCHTASKS="$FAKE_SCHTASKS" QMD_CADENCE_BAT_DIR="$EVIL_BAT_DIR" \
    PATH="$TMP_ROOT/bin:$QMD_BIN_DIR_PATH:$PATH" "$REAL_BASH" "$SCRIPT" disarm >/dev/null 2>&1 || true

summary
