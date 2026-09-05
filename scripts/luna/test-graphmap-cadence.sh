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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

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

# HIMMEL-1960: validate_arm_inputs refuses to arm when the semantic backend's
# credential (kimi -> MOONSHOT_API_KEY) is not readable from the .env that
# survives to fire time. GRAPHMAP_DOTENV_ROOT pins WHICH .env is consulted, so
# the suite asserts both outcomes without depending on the operator's real .env
# — before this seam the negative test only passed on a machine that happened
# not to have the key, i.e. it would have broken the moment someone followed
# the arm instructions. Populated in setup_dotenv_root below (TMP_ROOT is not
# created until later in this file).
DOTENV_ROOT=""
DOTENV_ROOT_EMPTY=""
setup_dotenv_root() {
    DOTENV_ROOT="$TMP_ROOT/dotenv-root"
    DOTENV_ROOT_EMPTY="$TMP_ROOT/dotenv-root-empty"
    mkdir -p "$DOTENV_ROOT" "$DOTENV_ROOT_EMPTY"
    printf 'MOONSHOT_API_KEY=test-moonshot-key-not-a-real-credential
' > "$DOTENV_ROOT/.env"
    export GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT"
    # Announces the hermetic suite; the credential seam refuses to redirect
    # without it, so no production arm can reach the redirect (CR r12).
    export GRAPHMAP_TEST_MODE=1
}

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
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
assert_registry() {
    local name="$1" expression="$2"
    if jq -e "$expression" "$HIMMEL_OBSERVABILITY_CONFIG" >/dev/null 2>&1; then pass "$name"; else fail "$name" "registry assertion failed: $expression"; fi
}
# assert_before <name> <first> <second> <haystack> — <first> must occur at a
# LOWER byte offset than <second> in <haystack> (both must be present). Used
# to prove element ORDER in emitted XML, not just presence (HIMMEL-1948 CR
# fix: Repetition is a base-type element and must precede the ScheduleByX
# choice in a CalendarTrigger, or schtasks /create /xml can reject it).
assert_before() {
    # Piping grep -bo into head risks the same SIGPIPE/pipefail trap grepq's
    # header comment documents (HIMMEL-1430): head -1 can close the pipe while
    # grep is still writing, so under `set -o pipefail` the pipeline's status
    # is grep's SIGPIPE death, not head's success. `|| true` absorbs that (the
    # captured output — the first line head read before closing — is correct
    # either way); a genuine no-match also exits nonzero and is likewise caught.
    local name="$1" first="$2" second="$3" haystack="$4" off_first off_second
    off_first=$(grep -bo -F -- "$first" <<< "$haystack" | head -1) || true
    off_second=$(grep -bo -F -- "$second" <<< "$haystack" | head -1) || true
    off_first="${off_first%%:*}"
    off_second="${off_second%%:*}"
    if [ -z "$off_first" ] || [ -z "$off_second" ]; then
        fail "$name" "missing element(s): '$first' (off=$off_first) '$second' (off=$off_second)"
    elif [ "$off_first" -lt "$off_second" ]; then
        pass "$name"
    else
        fail "$name" "expected offset('$first')=$off_first < offset('$second')=$off_second"
    fi
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
setup_dotenv_root

# Shared fixtures ------------------------------------------------------------

# The interpreter that runs the script under test. Resolved BEFORE the fake
# bash below shadows PATH: `env PATH=... bash` would exec the FAKE via the NEW
# PATH, and on Linux the fake's own `#!/usr/bin/env bash` shebang re-resolves
# to itself -> infinite exec loop -> the whole suite hangs to the CI timeout
# (broke public CI on ubuntu; Git Bash dodges it only because the mixed-form
# C:/ PATH entry loses the lookup there).
REAL_BASH="$(command -v bash)"

# The real mv, resolved for the same reason as REAL_BASH: the Test 9b recording
# fake mv below shadows PATH and must delegate every call to the real binary.
REAL_MV="$(command -v mv)"

# Fake bash on PATH (arm resolves it via `command -v bash`). A no-op stub is
# enough — the tests assert runner TEXT, they never fire the runner. Shebang
# is /bin/sh (absolute) so the stub can never shebang-recurse into itself.
# HIMMEL-1701/1686: the stub is PLATFORM-NAMED. An EXTENSIONLESS file called
# `bash` makes Windows ShellExecute return SE_ERR_NOASSOC, which pops the
# "Select an app to open 'bash'" picker — a modal that hangs an unattended
# cadence run with nobody there to dismiss it. HERMETIC_EXE_SUFFIX is CONSUMED
# from scripts/lib/hermetic-path.sh (where the reader,
# path_dir_has_scrubbed_tool, lives too) rather than re-derived here, so the
# writer and reader sides cannot drift.
# shellcheck source=../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/hermetic-path.sh"
mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/bash$HERMETIC_EXE_SUFFIX"
chmod +x "$TMP_ROOT/bin/bash$HERMETIC_EXE_SUFFIX"

# The HIMMEL-1686 assertion, ported from scripts/test-adopt.sh: the
# platform-named stub must EXIST, and on Windows no extensionless `bash` may
# be created. The expected suffix comes from an INDEPENDENT platform probe,
# never from HERMETIC_EXE_SUFFIX — reusing the writer's own value makes the
# check tautological (a regression to an empty suffix would move both sides
# together and still match). `find` with a literal -name match is REQUIRED for
# the rejection branch: on MSYS/Git-Bash `test -e` resolves bash -> bash.exe,
# so a plain file test would fire on every healthy Windows run.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) WANT_EXE_SUFFIX='.exe' ;;
  *)                                WANT_EXE_SUFFIX='' ;;
esac
if [ -f "$TMP_ROOT/bin/bash$WANT_EXE_SUFFIX" ]; then
    pass "hermetic bash stub is platform-named (bash$WANT_EXE_SUFFIX)"
else
    fail "hermetic bash stub is platform-named (bash$WANT_EXE_SUFFIX)" "missing: $TMP_ROOT/bin/bash$WANT_EXE_SUFFIX"
fi
if [ -n "$WANT_EXE_SUFFIX" ] && [ -n "$(find "$TMP_ROOT/bin" -maxdepth 1 -name bash -print -quit)" ]; then
    fail "no extensionless bash stub on Windows" "SE_ERR_NOASSOC hazard: $TMP_ROOT/bin/bash"
else
    pass "no extensionless bash stub on Windows"
fi

# Hermetic shared WSH preflight: no policy override, and the windowless host's
# zero-exit smoke script succeeds without consulting the live machine.
FAKE_WSCRIPT="$TMP_ROOT/wscript-fake.exe"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_WSCRIPT"
chmod +x "$FAKE_WSCRIPT"
FAKE_WSH_POWERSHELL="$TMP_ROOT/powershell-wsh-fake.sh"
printf '#!/bin/sh\necho ABSENT\n' > "$FAKE_WSH_POWERSHELL"
chmod +x "$FAKE_WSH_POWERSHELL"
export CADENCE_WSCRIPT_BIN="$FAKE_WSCRIPT"
export CADENCE_WSH_POWERSHELL="$FAKE_WSH_POWERSHELL"

# Fake `graphify` on PATH (HIMMEL-1070, updated HIMMEL-1948): arm now resolves
# it via `command -v graphify` and FAILS FAST when it is absent, because EVERY
# armed task (semantic via refresh-graph-map.sh, structural directly) shells it
# at fire time under the scheduler's minimal PATH. Neither pair shells `claude`
# any more (BACKEND is kimi, not claude-cli). A stub keeps the suite
# deterministic on machines with and without a real CLI installed; like the bash
# stub it is never fired, only resolved + its dirname read.
#
# It lives in its OWN dir, entered on PATH in POSIX form, for two reasons the
# `bin` dir above cannot serve: (1) TMP_ROOT is cygpath -m'd (C:/... mixed form)
# and Git-Bash cannot resolve a PATH entry in that form — a stub in `bin` is
# INVISIBLE on Windows, so the arm would silently resolve the operator's REAL
# installed graphify and the runner assertion below would pin a machine-specific
# path; (2) adding a POSIX entry for `bin` itself would newly expose the fake
# `bash` on Windows, changing what the existing suite bakes into its runners.
GRAPHIFY_BIN_DIR="$TMP_ROOT/graphify-bin"
mkdir -p "$GRAPHIFY_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$GRAPHIFY_BIN_DIR/graphify"
chmod +x "$GRAPHIFY_BIN_DIR/graphify"
GRAPHIFY_BIN_DIR_PATH="$GRAPHIFY_BIN_DIR"
if command -v cygpath >/dev/null 2>&1; then
    GRAPHIFY_BIN_DIR_PATH=$(cygpath -u "$GRAPHIFY_BIN_DIR")
fi
# EVERY invocation that reaches `arm` must carry $GRAPHIFY_BIN_DIR_PATH on PATH
# — arm fail-fasts when `graphify` is absent (HIMMEL-1070). Omitting it does NOT
# fail on a dev box that happens to have the real CLI installed: the inherited
# $PATH tail satisfies the probe by ACCIDENT, so the suite goes green locally
# and dies on a clean CI runner with rc=2 (set -euo pipefail aborts the whole
# script on the unguarded `arm` assignment, before any assertion prints). That
# is exactly how this shipped to public CI once. The stub keeps the suite
# hermetic — a test's result must never depend on what the operator has
# installed.

# A PATH with the real system dirs (arm needs dirname/sed/mktemp at load time)
# but with EVERY dir that carries a real `graphify` filtered out — the fail-fast
# probe below must not be satisfied by an installed CLI. Filtering the real PATH
# beats replacing it: a bare stub dir strips coreutils and the script dies rc=127
# on `dirname` before it ever reaches the check under test.
PATH_NOGRAPHIFY=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/graphify" ] || [ -x "$_d/graphify.exe" ] || [ -x "$_d/graphify.cmd" ]; then continue; fi
    PATH_NOGRAPHIFY="${PATH_NOGRAPHIFY:+$PATH_NOGRAPHIFY:}$_d"
done
IFS=$_oldifs

# Hermeticity: point HOME/USERPROFILE at the temp dir so a stray BAT_DIR default
# (should the seam ever be dropped) can't land under the real user profile.
export HOME="$TMP_ROOT/home"
export HIMMEL_OBSERVABILITY_CONFIG="$TMP_ROOT/observability.json"
mkdir -p "$HOME"

VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT"

# The himmel root the runners cd into is this script's ../.. (same resolution
# graphmap-cadence.sh uses for HIMMEL_ROOT).
HIMMEL_ROOT_EXP="$(cd "$SCRIPT_DIR/../.." && pwd)"
# The promote-lock wrapper the AST pair now fires by absolute path (HIMMEL-1948
# CR r1b), same resolution graphmap-cadence.sh uses for AST_UPDATE_SCRIPT.
AST_UPDATE_SCRIPT_EXP="$HIMMEL_ROOT_EXP/scripts/graphify/ast-update.sh"
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
        GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron luna not armed"   "not armed  HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel not armed" "not armed  HIMMEL-GraphMap-Himmel" "$out"
assert_contains "cron ast-luna not armed"   "not armed  HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "cron ast-himmel not armed" "not armed  HIMMEL-GraphMapAst-Himmel" "$out"

# Test C1b (HIMMEL-1948 CR r2 finding 2): cron_status must not report an
# unrelated task's cron entry as an owned task being armed. cron_existing/
# list_existing were scoped to exact/end-anchored matches against the four
# owned names in a prior commit; cron_status's own `grep -F "# $name"` was
# missed and still substring-matched -- a `# HIMMEL-GraphMapAst-LunaExtra`
# entry would be reported as HIMMEL-GraphMapAst-Luna being armed.
echo "TEST: cron status ignores an unrelated LunaExtra-suffixed entry"
printf '5 5 * * * /usr/bin/true # HIMMEL-GraphMapAst-LunaExtra\n' > "$CSTATE/crontab"
out=$(run_cron status)
assert_contains "cron ast-luna correctly not armed despite the LunaExtra entry" "not armed  HIMMEL-GraphMapAst-Luna" "$out"
assert_not_contains "cron status never reports LunaExtra's entry as the real task being armed" "ARMED      HIMMEL-GraphMapAst-Luna" "$out"
rm -f "$CSTATE/crontab"

# Test C12: shared validation wired into the cron path -----------------------

echo "TEST: cron arm rejects invalid input (shared validation)"
rc=0; out=$(run_cron arm --vault "$VAULT" --luna-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --luna-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --himmel-time 25:00 2>&1) || rc=$?
assert_rc "cron bad --himmel-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "cron missing vault dir -> rc 1" 1 "$rc"

# Test C13: arm fails fast when `graphify` is absent (HIMMEL-1070, updated
# HIMMEL-1948) --------------------------------------------------------------
#
# Every armed task shells graphify at fire time under the scheduler's minimal
# PATH (semantic pair via refresh-graph-map.sh, structural pair directly).
# Arming on a machine without it would "succeed" and then die on every
# unattended fire, in a log nobody reads. PATH is REPLACED (not prepended) so
# a really-installed graphify cannot satisfy the probe here.

echo "TEST: cron arm fails fast when graphify is not on PATH"
rc=0; out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$PATH_NOGRAPHIFY" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron arm without graphify -> rc 2" 2 "$rc"
assert_contains "missing-graphify error names the CLI" "'graphify' not on PATH at arm time" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "failed arm installed nothing"
else
    fail "failed arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C13b: arm fails fast when the semantic backend's credential is missing
# (HIMMEL-1960) --------------------------------------------------------------
#
# HIMMEL-1948 moved the semantic pair onto the `kimi` backend but nothing
# checked MOONSHOT_API_KEY, so arm could succeed while every weekly run then
# died unattended -- a cadence that reports ARMED and produces nothing. This is
# not hypothetical: the credential was absent from this repo's .env when the
# check was written, so an arm at that moment WOULD have been inert.
#
# Deterministic on ANY machine: GRAPHMAP_DOTENV_ROOT points at an EMPTY
# directory, so no .env can satisfy the check no matter how the operator's real
# one is configured, and the env var is unset in the subshell.

echo "TEST: cron arm fails fast when the backend credential is missing"
rc=0; out=$(unset MOONSHOT_API_KEY; GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron arm without the kimi credential -> rc 2" 2 "$rc"
assert_contains "missing-credential error names the variable" "MOONSHOT_API_KEY" "$out"
assert_contains "missing-credential error explains the armed-and-inert risk" \
    "report ARMED while every weekly semantic run fails" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "credential-failed arm installed nothing"
else
    fail "credential-failed arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C13c: a credential present ONLY in the arming shell's environment
# (CR r2/r5 codex-2) ----------------------------------------------------------
#
# Not accepted as proof on EITHER scheduler. Both start with their own
# environment and the generated runners carry no secrets, so a shell export
# cannot be shown to reach the weekly run — and "is this export persistent?" is
# precisely what bash cannot answer here. .env is the source refresh-graph-map.sh
# reads at fire time, so that is what the gate requires.

echo "TEST: cron arm refuses a credential that only exists in the environment"
rc=0; out=$(MOONSHOT_API_KEY=env-only-key GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron env-only credential -> rc 2" 2 "$rc"
assert_contains "cron env-only refusal explains why a shell export is not proof" \
    "exported in THIS shell is deliberately not accepted" "$out"
assert_not_contains "cron env-only refusal does not print the key" "env-only-key" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "cron env-only refusal installed nothing"
else
    fail "cron env-only refusal left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C2: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --vault "$VAULT" --dry-run)
assert_contains "dry-run weekly luna entry"   "00 13 * * 0" "$out"
assert_contains "dry-run weekly himmel entry" "20 13 * * 0" "$out"
assert_contains "dry-run luna marker"   "# HIMMEL-GraphMap-Luna"   "$out"
assert_contains "dry-run himmel marker" "# HIMMEL-GraphMap-Himmel" "$out"
assert_contains "dry-run fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "dry-run luna payload names the corpus" "--name luna" "$out"
assert_contains "dry-run himmel payload names the corpus" "--name himmel" "$out"
# Structural (AST) pair, asymmetric since HIMMEL-1960 (operator decision (a)):
# himmel hourly (minute, every hour), luna DAILY at its full HH:MM.
assert_contains "dry-run daily ast-luna entry"    "05 00 * * *"  "$out"
assert_contains "dry-run hourly ast-himmel entry" "15 * * * *" "$out"
assert_contains "dry-run ast-luna marker"   "# HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "dry-run ast-himmel marker" "# HIMMEL-GraphMapAst-Himmel" "$out"
# HIMMEL-1948 CR r1b: the AST payload now fires the promote-lock wrapper
# (ast-update.sh), not a bare graphify update -- --force lives inside it.
assert_contains "dry-run ast payload fires the promote-lock wrapper" "ast-update.sh" "$out"
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
assert_contains "weekly luna entry (Sunday) 13:00"   "00 13 * * 0" "$tab"
assert_contains "weekly himmel entry (Sunday) 13:20" "20 13 * * 0" "$tab"
assert_contains "luna entry marker-tagged"   "# HIMMEL-GraphMap-Luna"   "$tab"
assert_contains "himmel entry marker-tagged" "# HIMMEL-GraphMap-Himmel" "$tab"
assert_contains "luna entry fires the runner"   "graphmap-luna.sh"   "$tab"
assert_contains "himmel entry fires the runner" "graphmap-himmel.sh" "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
assert_registry "cron arm registers both weekly graphmap flows" '[.flows[] | select((.name == "graphmap-luna" or .name == "graphmap-himmel") and .cadence_seconds == 604800)] | length == 2'
assert_registry "cron arm registers both expected task names" '[.expected_tasks[] | select(. == "HIMMEL-GraphMap-Luna" or . == "HIMMEL-GraphMap-Himmel")] | length == 2'
assert_registry "cron arm registers both ast graphmap flows" '[.flows[] | select(.name == "graphmap-ast-luna" or .name == "graphmap-ast-himmel")] | length == 2'
assert_registry "cron arm registers both ast expected task names" '[.expected_tasks[] | select(. == "HIMMEL-GraphMapAst-Luna" or . == "HIMMEL-GraphMapAst-Himmel")] | length == 2'
# Structural (AST) pair: marker-tagged, own runner files. luna is DAILY and
# himmel HOURLY since HIMMEL-1960. The luna assertion is made against THAT
# ENTRY'S OWN LINE, not the whole crontab: himmel's hourly `15 * * * *`
# contains the substring `5 * * * *`, so a whole-file assert_not_contains for
# the hourly form can never distinguish the two legs (it fails even when luna
# is correctly daily).
ast_luna_line=$(grep -F '# HIMMEL-GraphMapAst-Luna' "$CSTATE/crontab" 2>/dev/null || true)
assert_contains "daily ast-luna entry (hour field pinned)" "05 00 * * *" "$ast_luna_line"
assert_not_contains "ast-luna entry is not hourly"         "05 * * * *"  "$ast_luna_line"
assert_contains "hourly ast-himmel entry" "15 * * * *" "$tab"
assert_contains "ast-luna entry marker-tagged"   "# HIMMEL-GraphMapAst-Luna"   "$tab"
assert_contains "ast-himmel entry marker-tagged" "# HIMMEL-GraphMapAst-Himmel" "$tab"
assert_contains "ast-luna entry fires its runner"   "graphmap-ast-luna.sh"   "$tab"
assert_contains "ast-himmel entry fires its runner" "graphmap-ast-himmel.sh" "$tab"
if [ -x "$CRON_DIR/graphmap-luna.sh" ] && [ -x "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -x "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -x "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "all four runner .sh files written + executable"
else
    fail "runner .sh files missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "exactly four cadence entries installed"
else
    fail "expected four cadence entries" "$(cat "$CSTATE/crontab")"
fi

# Test C4: runner .sh fires refresh-graph-map.sh with the right payload -------

echo "TEST: runner .sh fires bash refresh-graph-map.sh (deterministic, no claude)"
luna_sh=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
# The sh runner embeds paths/title via printf %q (backslash-escapes spaces);
# strip the escapes before multi-word asserts.
luna_sh_plain=${luna_sh//\\/}
himmel_sh_plain=${himmel_sh//\\/}
# The expected version is SOURCED, never retyped (HIMMEL-2044): a hardcoded
# literal here bounces this suite on every format bump for no coverage gain --
# the assertion that matters is "the runner stamps the CURRENT format".
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/cadence-format.sh"
FMT="$CADENCE_RUNNER_FORMAT_VERSION"
assert_contains "luna runner stamps the format version (HIMMEL-588)"   "# himmel-cadence-runner-format: $FMT" "$luna_sh"
assert_contains "himmel runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: $FMT" "$himmel_sh"
assert_contains "luna runner fires refresh-graph-map.sh"   "refresh-graph-map.sh" "$luna_sh_plain"
assert_contains "luna runner names the luna corpus"        "--name luna"          "$luna_sh"
assert_contains "luna runner sets the luna slug"           "--slug graphify-luna-map" "$luna_sh"
assert_contains "luna runner sets the luna corpus-tag"     "--corpus-tag luna"    "$luna_sh"
assert_contains "luna runner uses the kimi backend"        "--backend kimi --corpus-tag" "$luna_sh"
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
assert_contains "himmel runner uses the kimi backend"      "--backend kimi --corpus-tag" "$himmel_sh"
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
    # HIMMEL-1070/1948: cron's minimal PATH carries neither node nor graphify,
    # so the runner must pin graphify's dir the same way it already pins
    # node's — without it every fire dies "graphify: command not found". The
    # expected dir is where the stub graphify lives.
    # shellcheck disable=SC2016  # literal $PATH — the runner expands it at fire time
    assert_contains "$what runner prepends the graphify dir to PATH" \
        "export PATH=$GRAPHIFY_BIN_DIR_PATH:\$PATH" "${body//\\/}"
done

# Test C4b: structural (AST) runner .sh fires the promote-lock wrapper
# (HIMMEL-1948 Task 3/4, brief items 5-6; wrapper routing = CR r1b) --
# free, no bank-preflight, no claude. --force now lives INSIDE ast-update.sh,
# not on this cadence command line (see scripts/graphify/test-ast-update.sh
# for the wrapper's own lock/skip/--force coverage).
echo "TEST: AST runner .sh fires ast-update.sh by absolute path (free, no bank, no claude)"
ast_luna_sh=$(cat "$CRON_DIR/graphmap-ast-luna.sh" 2>/dev/null || echo MISSING)
ast_himmel_sh=$(cat "$CRON_DIR/graphmap-ast-himmel.sh" 2>/dev/null || echo MISSING)
ast_luna_sh_plain=${ast_luna_sh//\\/}
ast_himmel_sh_plain=${ast_himmel_sh//\\/}
assert_contains "ast-luna runner stamps the format version"   "# himmel-cadence-runner-format: $FMT" "$ast_luna_sh"
assert_contains "ast-himmel runner stamps the format version" "# himmel-cadence-runner-format: $FMT" "$ast_himmel_sh"
assert_contains "ast-luna runner fires ast-update.sh by absolute path"   "$AST_UPDATE_SCRIPT_EXP" "$ast_luna_sh_plain"
assert_contains "ast-himmel runner fires ast-update.sh by absolute path" "$AST_UPDATE_SCRIPT_EXP" "$ast_himmel_sh_plain"
assert_not_contains "ast-luna runner has no bare --force on the cadence line (it's inside the wrapper)"   "--force" "$ast_luna_sh_plain"
assert_not_contains "ast-himmel runner has no bare --force on the cadence line (it's inside the wrapper)" "--force" "$ast_himmel_sh_plain"
# Absolute corpus paths: luna = vault, himmel = repo (same asymmetry as the
# semantic pair) -- both $VAULT/$HIMMEL_ROOT_EXP are already absolute here.
assert_contains "ast-luna runner corpus is the absolute vault path"     "$AST_UPDATE_SCRIPT_EXP $VAULT" "$ast_luna_sh_plain"
assert_contains "ast-himmel runner corpus is the absolute himmel path"  "$AST_UPDATE_SCRIPT_EXP $HIMMEL_ROOT_EXP" "$ast_himmel_sh_plain"
# Luna leg declares the fence's required backend (ollama -> local-ollama,
# luna-personal x local-ollama = allow); himmel leg does not need it
# (himmel-code default = ollama already, no declaration required).
assert_contains "ast-luna runner declares GRAPHIFY_DECLARED_BACKEND=ollama" "export GRAPHIFY_DECLARED_BACKEND=ollama" "$ast_luna_sh"
assert_not_contains "ast-himmel runner does not declare a backend" "GRAPHIFY_DECLARED_BACKEND" "$ast_himmel_sh"
for what in ast_luna ast_himmel; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    # The property that keeps the hourly leg free -- assert the ABSENCE
    # explicitly (brief item 6). HIMMEL_ROOT_EXP is stripped before the
    # "claude" check because the fixture's own worktree path legitimately
    # contains the substring (.claude/worktrees/...) via the `cd` target --
    # that is test-environment noise, not a claude invocation.
    # Both substring checks strip HIMMEL_ROOT_EXP first, for the same reason:
    # the fixture's own checkout path is embedded in every runner, and a
    # worktree named after the thing being asserted absent (a
    # `fix/...-bank-preflight` branch, or any path under `.claude/`) would
    # fail an assertion the runner itself never violates.
    assert_not_contains "$what runner has no bank-preflight" "bank-preflight" "${body//$HIMMEL_ROOT_EXP/}"
    assert_not_contains "$what runner never shells claude"   "claude" "${body//$HIMMEL_ROOT_EXP/}"
    assert_not_contains "$what runner has no --backend flag (LLM-free update)" "--backend" "$body"
    assert_not_contains "$what runner has no --settings (not a claude session)" "--settings" "$body"
done

# Test C5: status after arm ----------------------------------------------------

echo "TEST: cron status reflects armed entries"
out=$(run_cron status)
assert_contains "cron luna armed"   "ARMED      HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel armed" "ARMED      HIMMEL-GraphMap-Himmel" "$out"
assert_contains "cron ast-luna armed"   "ARMED      HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "cron ast-himmel armed" "ARMED      HIMMEL-GraphMapAst-Himmel" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"

# Test C5b: status summarises a run log (HIMMEL-1901 ask 3) --------------------
#
# The 2026-08-17 fire is the fixture: luna died on the reboot 6h44m in, on
# chunk 149/314, with no `tokens:` line ever emitted and the log dominated by
# hollow-response bisect retries. Lines are written CRLF because the real logs
# come from a Windows .bat, and a stray CR would corrupt the parsed fields.

echo "TEST: cron status summarises run logs"
{
    printf '[graphify extract] chunk 148/314 done\r\n'
    for _i in $(seq 1 20); do
        printf '[graphify] claude-cli returned a hollow response; treating as truncation so adaptive retry can bisect the chunk.\r\n'
    done
    printf '[graphify extract] chunk 149/314 done\r\n'
} > "$CRON_DIR/graphmap-luna.log"
# shellcheck disable=SC2016  # the $ is graphify's literal cost prefix, not a variable
printf '[graphify extract] chunk 12/12 done\r\n[graphify extract] tokens: 144,540 in / 10,669 out, est. cost (~kimi): $0.1234\r\n' \
    > "$CRON_DIR/graphmap-himmel.log"
printf 'refresh-graph-map: nothing to do\r\n' > "$CRON_DIR/graphmap-ast-luna.log"

out=$(run_cron status)
assert_contains "storm log reports no token summary" \
    "run summary: NO tokens summary (run did not finish)" "$out"
assert_contains "storm log reports last chunk reached" "last chunk 149/314" "$out"
assert_contains "storm log counts hollow responses"     "20 hollow responses" "$out"
assert_contains "storm log flags the storm"           "HOLLOW-BISECT STORM (HIMMEL-1901)" "$out"
assert_contains "healthy log reports token totals" \
    "run summary: 144,540 in / 10,669 out, est. cost (~kimi): \$0.1234 | last chunk 12/12 | 0 hollow responses" "$out"
# One line per marker-bearing log, and no storm marker on the healthy one:
# exactly two summaries across the four logs (luna + himmel), never three.
summary_lines=$(grep -c -F 'run summary:' <<< "$out" || true)
if [ "$summary_lines" = "2" ]; then
    pass "unmarked log gets no run summary"
else
    fail "unmarked log gets no run summary" "expected 2 'run summary:' lines, got $summary_lines"
fi
storm_lines=$(grep -c -F 'HOLLOW-BISECT STORM' <<< "$out" || true)
if [ "$storm_lines" = "1" ]; then
    pass "storm marker only on the storm log"
else
    fail "storm marker only on the storm log" "expected 1 storm line, got $storm_lines"
fi
rm -f "$CRON_DIR/graphmap-luna.log" "$CRON_DIR/graphmap-himmel.log" "$CRON_DIR/graphmap-ast-luna.log"

# Test C6: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names existing entries" "HIMMEL-GraphMap-Himmel" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "no duplicate entries after blocked re-arm"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C7: re-arm --force with overrides ----------------------------------------

echo "TEST: cron re-arm --force applies flag overrides"
out=$(run_cron arm --vault "$VAULT" --force --luna-time 01:15 --himmel-time 02:30 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "cron weekly luna override"   "15 01 * * 0" "$tab"
assert_contains "cron weekly himmel override" "30 02 * * 0" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "still exactly four entries after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C14: dry-run disarm with armed entries prints DRY tail, touches nothing --

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "dry-run disarm kept all four runner .sh files"
else
    fail "dry-run disarm deleted runner .sh files"
fi
assert_registry "dry-run disarm keeps graphmap registered" '[.flows[] | select(.name == "graphmap-luna" or .name == "graphmap-himmel")] | length == 2'

# Test C8: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes entries + runners, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entries removed" "HIMMEL-GraphMap" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ ! -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "all four runner .sh files removed"
else
    fail "runner .sh files left after disarm"
fi
assert_registry "deliberate disarm unregisters both graphmap flows" 'all(.flows[]; .name != "graphmap-luna" and .name != "graphmap-himmel")'
assert_registry "deliberate disarm removes both expected tasks" 'all(.expected_tasks[]; . != "HIMMEL-GraphMap-Luna" and . != "HIMMEL-GraphMap-Himmel")'
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C8b: --ast-only (HIMMEL-2071) -----------------------------------------
#
# arm --ast-only registers ONLY the two free structural tasks, needs no
# semantic-backend credential, and — critically — an --ast-only --force
# re-arm must leave a PRE-EXISTING semantic pair's crontab entries and runner
# files byte-identical, never rewriting or deleting them.
#
# Literal task names (this test SCRIPT's own scope has no $TASK_* vars — those
# live only inside graphmap-cadence.sh, sourced via a separate interpreter by
# run_cron; referencing them here would be an unbound-variable error under
# this file's own `set -euo pipefail`).
T_LUNA="HIMMEL-GraphMap-Luna"
T_HIMMEL="HIMMEL-GraphMap-Himmel"
T_AST_LUNA="HIMMEL-GraphMapAst-Luna"
T_AST_HIMMEL="HIMMEL-GraphMapAst-Himmel"

echo "TEST: cron arm --ast-only --dry-run skips the semantic pair entirely"
out=$(run_cron arm --vault "$VAULT" --ast-only --dry-run)
assert_contains "ast-only dry-run says semantic pair skipped" "semantic pair" "$out"
assert_not_contains "ast-only dry-run has no weekly luna entry"   "00 13 * * 0" "$out"
assert_not_contains "ast-only dry-run has no weekly himmel entry" "20 13 * * 0" "$out"
assert_not_contains "ast-only dry-run never fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "ast-only dry-run still has the daily ast-luna entry" "05 00 * * *" "$out"
assert_contains "ast-only dry-run still has the hourly ast-himmel entry" "15 * * * *" "$out"

echo "TEST: cron arm --ast-only needs no semantic-backend credential"
rc=0; out=$(unset MOONSHOT_API_KEY; GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    run_cron arm --vault "$VAULT" --ast-only 2>&1) || rc=$?
assert_rc "ast-only arm succeeds with no MOONSHOT_API_KEY anywhere" 0 "$rc"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab" 2>/dev/null)" -eq 2 ]; then
    pass "ast-only arm installed exactly two cadence entries"
else
    fail "ast-only arm installed the wrong entry count" "$tab"
fi
assert_contains "ast-only arm's ast-luna entry present"   "# $T_AST_LUNA"   "$tab"
assert_contains "ast-only arm's ast-himmel entry present" "# $T_AST_HIMMEL" "$tab"
assert_contains "ast-only arm from a clean slate correctly banners the semantic pair as NOT armed" "NOT armed (--ast-only)" "$out"
assert_not_contains "ast-only arm installed no semantic luna entry"   "# $T_LUNA"   "$tab"
assert_not_contains "ast-only arm installed no semantic himmel entry" "# $T_HIMMEL" "$tab"
if [ -x "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -x "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "ast-only arm wrote both AST runner .sh files"
else
    fail "ast-only arm did not write both AST runners" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if [ ! -e "$CRON_DIR/graphmap-luna.sh" ] && [ ! -e "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "ast-only arm wrote NO semantic runner .sh files"
else
    fail "ast-only arm wrote a semantic runner it should not have" "$(ls "$CRON_DIR")"
fi

echo "TEST: cron re-arm without --ast-only dedup-blocks on the already-armed AST tasks"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "full re-arm over an ast-only arm dedup-blocks" 3 "$rc"
assert_contains "dedup message names the already-armed AST task" "$T_AST_LUNA" "$out"

echo "TEST: --ast-only --force re-arm ADDS the AST pair without touching a pre-existing semantic pair"
out=$(run_cron arm --vault "$VAULT" --force 2>&1)   # full re-arm: now all four are armed
luna_sh_before=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh_before=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
tab_before_luna=$(grep -F "# $T_LUNA" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_before_himmel=$(grep -F "# $T_HIMMEL" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
out=$(run_cron arm --vault "$VAULT" --ast-only --force 2>&1)
assert_contains "ast-only --force re-arm banner" "GRAPHMAP CADENCE ARMED" "$out"
# codex-1, HIMMEL-2071 CR round 1: the banner must report the pre-existing
# semantic pair's REAL state, not a blanket "NOT armed" false negative.
assert_contains "ast-only --force re-arm banner shows the pre-existing luna task as armed"   "$T_LUNA       already armed" "$out"
assert_contains "ast-only --force re-arm banner shows the pre-existing himmel task as armed" "$T_HIMMEL     already armed" "$out"
assert_not_contains "ast-only --force re-arm banner does not claim the pre-existing semantic pair is unarmed" "NOT armed (--ast-only)" "$out"
luna_sh_after=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh_after=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_after_luna=$(grep -F "# $T_LUNA" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_after_himmel=$(grep -F "# $T_HIMMEL" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
if [ "$luna_sh_before" = "$luna_sh_after" ]; then
    pass "ast-only --force re-arm left the pre-existing luna runner byte-identical"
else
    fail "ast-only --force re-arm rewrote the pre-existing luna runner" "before=<$luna_sh_before> after=<$luna_sh_after>"
fi
if [ "$himmel_sh_before" = "$himmel_sh_after" ]; then
    pass "ast-only --force re-arm left the pre-existing himmel runner byte-identical"
else
    fail "ast-only --force re-arm rewrote the pre-existing himmel runner"
fi
if [ "$tab_before_luna" = "$tab_after_luna" ] && [ "$tab_before_himmel" = "$tab_after_himmel" ]; then
    pass "ast-only --force re-arm left the pre-existing semantic crontab entries byte-identical"
else
    fail "ast-only --force re-arm changed the pre-existing semantic crontab entries" "before: $tab_before_luna / $tab_before_himmel; after: $tab_after_luna / $tab_after_himmel"
fi
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "ast-only --force re-arm still leaves exactly four entries total"
else
    fail "unexpected entry count after ast-only --force re-arm over a full arm" "$tab"
fi
run_cron disarm >/dev/null

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
if ! grep -q 'HIMMEL-GraphMap' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entries installed on write failure"
else
    fail "cadence entries installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ ! -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
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
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
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
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "entries still in crontab after failed disarm install"
else
    fail "entries lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
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
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$EVIL_VAULT")
luna_sh=$(cat "$EVIL_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
assert_contains "ampersand %q-escaped in runner" 'va\&ult' "$luna_sh"
# shellcheck disable=SC2016  # literal \$X needle — asserting the %q escape itself
assert_contains "dollar %q-escaped in runner" '\$X' "$luna_sh"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" disarm >/dev/null

# Test C13: unknown platform exits 2 ----------------------------------------------

echo "TEST: unknown platform (OSTYPE=beos) exits 2"
rc=0; out=$(env OSTYPE=beos bash "$SCRIPT" status 2>&1) || rc=$?
assert_rc "unknown platform rc 2" 2 "$rc"
assert_contains "unknown platform message" "unsupported platform" "$out"

# Test C15 (HIMMEL-1948 CR r2): exact-name scoping — a crontab entry whose
# comment merely STARTS WITH the dash-less "HIMMEL-GraphMap" prefix (not one
# of the four owned names) must be treated as neither ours-for-removal nor
# ours-for-dedup. Isolated fixture/state (CSTATE2/FAKE_CRONTAB2) so this never
# disturbs the sequential arm/disarm chain above.
echo "TEST: cron scoping — unrelated HIMMEL-GraphMap*-prefixed entry survives removal, never blocks arm"
CSTATE2="$TMP_ROOT/cron-state2"
mkdir -p "$CSTATE2"
FAKE_CRONTAB2="$TMP_ROOT/crontab-fake2.sh"
cat >"$FAKE_CRONTAB2" <<FAKE
#!/bin/sh
CSTATE="$CSTATE2"
FAKE
cat >>"$FAKE_CRONTAB2" <<'FAKE'
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
chmod +x "$FAKE_CRONTAB2"
CRON_DIR2="$TMP_ROOT/cron-runners2"
run_cron2() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB2" \
        GRAPHMAP_BAT_DIR="$CRON_DIR2" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}
# "HIMMEL-GraphMapExtra" starts with the old dash-less prefix match
# ("HIMMEL-GraphMap") but is none of the four owned names — an operator's own
# unrelated entry, by construction.
printf '0 0 * * * /usr/bin/true # HIMMEL-GraphMapExtra\n' > "$CSTATE2/crontab"
rc=0; out=$(run_cron2 arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "arm succeeds with only an unrelated prefixed entry present (no false dedup-block)" 0 "$rc"
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated prefixed entry survives arm's own-entry rewrite" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 5 ]; then
    pass "unrelated entry plus all four real cadence entries present (5 total)"
else
    fail "unexpected entry count after arm" "$(cat "$CSTATE2/crontab")"
fi
rc=0; out=$(run_cron2 arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "re-arm without --force now dedup-blocks on the REAL entries" 3 "$rc"
assert_contains "dedup message names a real owned entry" "HIMMEL-GraphMap-Luna" "$out"
assert_not_contains "dedup message does not name the unrelated entry" "HIMMEL-GraphMapExtra" "$out"
out=$(run_cron2 arm --vault "$VAULT" --force 2>&1)
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated entry still survives a --force re-arm" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 5 ]; then
    pass "still exactly five entries (4 real + 1 unrelated) after --force re-arm"
else
    fail "unexpected entry count after --force re-arm" "$(cat "$CSTATE2/crontab")"
fi
out=$(run_cron2 disarm)
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated prefixed entry survives disarm" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 1 ]; then
    pass "disarm removed exactly the four owned entries, left the unrelated one"
else
    fail "disarm removed or left the wrong entries" "$(cat "$CSTATE2/crontab")"
fi

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
        PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" "$REAL_BASH" "$SCRIPT" "$@"
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
assert_contains "ast-luna not armed"   "not armed  HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "ast-himmel not armed" "not armed  HIMMEL-GraphMapAst-Himmel" "$out"

# Test 4: arm --dry-run touches nothing -------------------------------------

# Test 3b: the same rule on the schtasks path (CR r5 codex-2) -----------------
#
# The mirror of C13c, and the reason the rule is uniform: an earlier revision
# accepted an env-only key here with a warning, on the grounds that Task
# Scheduler inherits PERSISTENT user/system variables. It does — but bash cannot
# tell a persistent variable from a transient export, so that path let exactly
# the armed-and-inert cadence this gate exists to prevent through on a guess.

echo "TEST: schtasks arm refuses a credential that only exists in the environment"
rc=0; out=$(MOONSHOT_API_KEY=env-only-key GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    run_gc arm --vault "$VAULT" --dry-run 2>&1) || rc=$?
assert_rc "schtasks env-only credential -> rc 2" 2 "$rc"
assert_contains "schtasks env-only refusal points at .env" \
    "Put MOONSHOT_API_KEY in .env" "$out"
assert_not_contains "schtasks env-only refusal does not print the key" "env-only-key" "$out"
if [ ! -d "$STATE/tasks" ] || [ "$(find "$STATE/tasks" -mindepth 1 2>/dev/null | wc -l)" -eq 0 ]; then
    pass "schtasks env-only refusal registered nothing"
else
    fail "schtasks env-only refusal registered tasks" "$(ls "$STATE/tasks" 2>/dev/null)"
fi

echo "TEST: arm --dry-run prints plan, registers nothing"
out=$(run_gc arm --vault "$VAULT" --dry-run)
assert_contains "dry-run luna create"   "/tn HIMMEL-GraphMap-Luna /xml" "$out"
assert_contains "dry-run himmel create" "/tn HIMMEL-GraphMap-Himmel /xml" "$out"
assert_contains "dry-run XML has StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$out"
assert_contains "dry-run XML weekly schedule" "<ScheduleByWeek>" "$out"
assert_contains "dry-run XML weekly day" "<Sunday/>" "$out"
assert_contains "dry-run luna time" "T13:00:00" "$out"
assert_contains "dry-run himmel time" "T13:20:00" "$out"
assert_contains "dry-run fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "dry-run ast-luna create"   "/tn HIMMEL-GraphMapAst-Luna /xml" "$out"
assert_contains "dry-run ast-himmel create" "/tn HIMMEL-GraphMapAst-Himmel /xml" "$out"
assert_contains "dry-run XML hourly repetition (himmel leg)" "<Interval>PT1H</Interval>" "$out"
# HIMMEL-1948 CR r1b: the AST payload now fires the promote-lock wrapper
# (ast-update.sh), not a bare graphify update -- --force lives inside it.
assert_contains "dry-run ast payload fires the promote-lock wrapper" "ast-update.sh" "$out"
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

echo "TEST: arm registers weekly luna Sunday 13:00 + weekly himmel Sunday 13:20 + hourly AST pair"
out=$(run_gc arm --vault "$VAULT")
assert_contains "arm banner" "GRAPHMAP CADENCE ARMED" "$out"
luna_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Luna" 2>/dev/null || echo MISSING)
himmel_args=$(cat "$STATE/tasks/HIMMEL-GraphMap-Himmel" 2>/dev/null || echo MISSING)
ast_luna_args=$(cat "$STATE/tasks/HIMMEL-GraphMapAst-Luna" 2>/dev/null || echo MISSING)
ast_himmel_args=$(cat "$STATE/tasks/HIMMEL-GraphMapAst-Himmel" 2>/dev/null || echo MISSING)
assert_contains "luna weekly schedule (XML)"   "<ScheduleByWeek>" "$luna_args"
assert_contains "luna weekly day (XML)"        "<Sunday/>"        "$luna_args"
assert_contains "luna time (XML)"             "T13:00:00"       "$luna_args"
assert_contains "himmel weekly schedule (XML)" "<ScheduleByWeek>" "$himmel_args"
assert_contains "himmel weekly day (XML)"      "<Sunday/>"        "$himmel_args"
assert_contains "himmel time (XML)"           "T13:20:00"       "$himmel_args"
assert_contains "luna XML StartWhenAvailable"   "<StartWhenAvailable>true</StartWhenAvailable>" "$luna_args"
assert_contains "himmel XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$himmel_args"
# Structural (AST) pair: free, and asymmetric since HIMMEL-1960 (operator
# decision (a)). Hourliness lives ENTIRELY in the <Repetition> element -- both
# legs share the same daily ScheduleByDay -- so luna's lower cadence IS the
# absence of that element, and that absence is the assertion that matters.
assert_not_contains "ast-luna carries NO hourly repetition (daily)" "<Repetition>" "$ast_luna_args"
assert_contains "ast-luna still has its daily schedule (XML)" "<ScheduleByDay>" "$ast_luna_args"
assert_contains "ast-himmel hourly repetition (XML)" "<Interval>PT1H</Interval>" "$ast_himmel_args"
assert_contains "ast-luna time (XML)"   "T00:05:00" "$ast_luna_args"
assert_contains "ast-himmel time (XML)" "T00:15:00" "$ast_himmel_args"
assert_contains "ast-luna XML StartWhenAvailable"   "<StartWhenAvailable>true</StartWhenAvailable>" "$ast_luna_args"
assert_contains "ast-himmel XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$ast_himmel_args"
# HIMMEL-1948 CR fix: calendarTriggerType extends triggerBaseType, whose
# sequence puts Repetition BEFORE the ScheduleByX choice — so Repetition must
# precede ScheduleByDay in the emitted trigger or schtasks /create /xml can
# reject it. Asserted against the real captured XML (schtasks-fake.sh's
# $STATE/tasks/<name>), not a re-derived string. Weekly (semantic) tasks carry
# no Repetition at all.
assert_before "ast-himmel Repetition precedes ScheduleByDay (schema order)" "<Repetition>" "<ScheduleByDay>" "$ast_himmel_args"
assert_not_contains "luna weekly XML carries no Repetition"   "<Repetition>" "$luna_args"
assert_not_contains "himmel weekly XML carries no Repetition" "<Repetition>" "$himmel_args"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 4 ]; then
    pass "arm registered exactly four tasks"
else
    fail "expected four tasks registered" "$(ls "$STATE/tasks")"
fi
assert_contains "luna Exec points at runner shim"   "graphmap-luna.vbs"   "$luna_args"
assert_contains "himmel Exec points at runner shim" "graphmap-himmel.vbs" "$himmel_args"
# HIMMEL-1753: Exec is a `wscript //B <shim>.vbs` wrapper around the .bat.
# The hidden-powershell shape still allocated consoles; wscript allocates zero.
# Element-scoped (not whole-XML) checks so a wrapper regression that happened
# to still mention the .bat somewhere else in the document wouldn't hide a
# broken Command or Arguments shape.
luna_command_elem=$(printf '%s' "$luna_args" | grep -o '<Command>[^<]*</Command>' | head -1)
luna_arguments_elem=$(printf '%s' "$luna_args" | grep -o '<Arguments>[^<]*</Arguments>' | head -1)
assert_contains "luna XML Exec Command is wscript.exe, not the bare .bat" "<Command>wscript.exe</Command>" "$luna_command_elem"
assert_not_contains "luna XML Exec Command does not carry the shim path" "graphmap-luna.vbs" "$luna_command_elem"
assert_contains "luna XML Exec Arguments carries //B batch mode" "//B" "$luna_arguments_elem"
assert_contains "luna XML Exec Arguments references the runner shim" "graphmap-luna.vbs" "$luna_arguments_elem"
assert_not_contains "luna XML Exec no longer uses hidden powershell" "-WindowStyle Hidden" "$luna_args"
himmel_command_elem=$(printf '%s' "$himmel_args" | grep -o '<Command>[^<]*</Command>' | head -1)
himmel_arguments_elem=$(printf '%s' "$himmel_args" | grep -o '<Arguments>[^<]*</Arguments>' | head -1)
assert_contains "himmel XML Exec Command is wscript.exe, not the bare .bat" "<Command>wscript.exe</Command>" "$himmel_command_elem"
assert_not_contains "himmel XML Exec Command does not carry the shim path" "graphmap-himmel.vbs" "$himmel_command_elem"
assert_contains "himmel XML Exec Arguments carries //B batch mode" "//B" "$himmel_arguments_elem"
assert_contains "himmel XML Exec Arguments references the runner shim" "graphmap-himmel.vbs" "$himmel_arguments_elem"
assert_not_contains "himmel XML Exec no longer uses hidden powershell" "-WindowStyle Hidden" "$himmel_args"

# Test 6: .bat runners fire refresh-graph-map.sh (deterministic, no claude) ---

echo "TEST: .bat runners fire bash refresh-graph-map.sh with the right payload"
luna_bat=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
himmel_bat=$(cat "$BAT_DIR/graphmap-himmel.bat" 2>/dev/null || echo MISSING)
assert_contains "luna bat stamps the format version (HIMMEL-588)"   "rem himmel-cadence-runner-format: $FMT" "$luna_bat"
assert_contains "himmel bat stamps the format version (HIMMEL-588)" "rem himmel-cadence-runner-format: $FMT" "$himmel_bat"
assert_contains "luna bat cds into himmel root" 'cd /d "' "$luna_bat"
assert_contains "luna bat fires refresh-graph-map.sh" "refresh-graph-map.sh" "$luna_bat"
assert_contains "luna bat names the luna corpus"      "--name luna"          "$luna_bat"
assert_contains "luna bat sets the luna slug"         "--slug graphify-luna-map" "$luna_bat"
assert_contains "luna bat sets the luna corpus-tag"   "--corpus-tag luna"    "$luna_bat"
assert_contains "luna bat uses the kimi backend"      "--backend kimi --corpus-tag" "$luna_bat"
assert_contains "luna bat sets the luna title"        "Graphify Luna Map"    "$luna_bat"
assert_contains "luna bat publishes into 60-Maps"     "60-Maps"              "$luna_bat"
assert_contains "luna bat appends run log" 'graphmap-luna.log" 2>&1' "$luna_bat"
assert_contains "luna bat rotates the log before firing" 'move /y' "$luna_bat"
assert_contains "luna bat stamps every fire" 'echo [fired %DATE% %TIME%]' "$luna_bat"
# HIMMEL-1389 (the #1454 fix, carried to the sibling emitters): a payload that
# resolves to a .cmd/.bat shim is TRANSFERRED to, not called, so the .bat's own
# exit path — and anything a later change appends after the payload line —
# would silently never run.
for _leg in luna himmel; do
    _leg_var="${_leg}_bat"
    if printf '%s' "${!_leg_var}" | grep -E 'call "[^"]*" "[^"]*refresh-graph-map\.sh"' >/dev/null; then
        pass "$_leg bat call-prefixes the payload invocation (HIMMEL-1389)"
    else
        fail "$_leg bat call-prefixes the payload invocation (HIMMEL-1389)" "${!_leg_var}"
    fi
done
assert_contains "himmel bat names the himmel corpus"    "--name himmel"        "$himmel_bat"
assert_contains "himmel bat sets the himmel slug"       "--slug graphify-himmel-map" "$himmel_bat"
assert_contains "himmel bat sets the himmel corpus-tag" "--corpus-tag himmel"  "$himmel_bat"
assert_contains "himmel bat uses the kimi backend"      "--backend kimi --corpus-tag" "$himmel_bat"
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

# Test 6b: structural (AST) .bat runners fire the promote-lock wrapper
# (HIMMEL-1948 Task 3/4, brief items 5-6; wrapper routing = CR r1b) --
# free, no bank-preflight, no claude. --force now lives INSIDE ast-update.sh,
# not on this cadence command line (see scripts/graphify/test-ast-update.sh
# for the wrapper's own lock/skip/--force coverage).
echo "TEST: AST .bat runners fire ast-update.sh by absolute path (free, no bank, no claude)"
ast_luna_bat=$(cat "$BAT_DIR/graphmap-ast-luna.bat" 2>/dev/null || echo MISSING)
ast_himmel_bat=$(cat "$BAT_DIR/graphmap-ast-himmel.bat" 2>/dev/null || echo MISSING)
assert_contains "ast-luna bat stamps the format version"   "rem himmel-cadence-runner-format: $FMT" "$ast_luna_bat"
assert_contains "ast-himmel bat stamps the format version" "rem himmel-cadence-runner-format: $FMT" "$ast_himmel_bat"
# The .bat's paths carry the CYGPATH -M (mixed C:/...) form -- bat_payload/
# ast_bat_payload always convert via cygpath -m before interpolating (same as
# the existing himmel_bat asserts above use $VAULT, cygpath -m'd at the top of
# this suite).
HIMMEL_ROOT_MIXED=$(cygpath -m "$HIMMEL_ROOT_EXP" 2>/dev/null || printf '%s' "$HIMMEL_ROOT_EXP")
AST_UPDATE_SCRIPT_MIXED=$(cygpath -m "$AST_UPDATE_SCRIPT_EXP" 2>/dev/null || printf '%s' "$AST_UPDATE_SCRIPT_EXP")
assert_contains "ast-luna bat fires ast-update.sh by absolute path"   "\"$AST_UPDATE_SCRIPT_MIXED\"" "$ast_luna_bat"
assert_contains "ast-himmel bat fires ast-update.sh by absolute path" "\"$AST_UPDATE_SCRIPT_MIXED\"" "$ast_himmel_bat"
assert_not_contains "ast-luna bat has no bare --force on the cadence line (it's inside the wrapper)"   "--force" "$ast_luna_bat"
assert_not_contains "ast-himmel bat has no bare --force on the cadence line (it's inside the wrapper)" "--force" "$ast_himmel_bat"
assert_contains "ast-luna bat corpus is the absolute vault path"    "\"$AST_UPDATE_SCRIPT_MIXED\" \"$VAULT\"" "$ast_luna_bat"
assert_contains "ast-himmel bat corpus is the absolute himmel path" "\"$AST_UPDATE_SCRIPT_MIXED\" \"$HIMMEL_ROOT_MIXED\"" "$ast_himmel_bat"
assert_contains "ast-luna bat declares GRAPHIFY_DECLARED_BACKEND=ollama" 'set "GRAPHIFY_DECLARED_BACKEND=ollama"' "$ast_luna_bat"
assert_not_contains "ast-himmel bat does not declare a backend" "GRAPHIFY_DECLARED_BACKEND" "$ast_himmel_bat"
for what in ast_luna ast_himmel; do
    body=$(eval "printf '%s' \"\$${what}_bat\"")
    # The property that keeps the hourly leg free -- assert the ABSENCE
    # explicitly (brief item 6). The `cd /d` line and the payload line (now
    # bash-prefixed, so it starts with a bare `"` -- same shape as the
    # semantic pair's payload line) are excluded before the "claude" check
    # because the fixture's own worktree path legitimately contains the
    # substring (.claude\worktrees\... / .claude/worktrees/...) via both the
    # cd target AND ast-update.sh's own path under the himmel root -- test-
    # environment noise, not a claude invocation. Line-exclusion (not
    # ${body//$HIMMEL_ROOT_WIN/}) because bash parameter-substitution patterns
    # treat backslashes as escape characters, not literal path separators, so
    # a Windows path pattern silently fails to match its own backslashes.
    # `^call "` joins the exclusion list with HIMMEL-1389: the payload line used
    # to START with the quoted interpreter path, and now starts with `call`, so
    # the old `^"` pattern no longer drops it and the worktree path inside it
    # re-triggers this very check on test-environment noise.
    body_noroot=$(printf '%s\n' "$body" | grep -v '^cd /d ' | grep -v '^"' | grep -v '^call "')
    # Both substring checks read the path-stripped body, for the same reason:
    # the fixture's own checkout path is on every payload line, so a worktree
    # named after the thing being asserted absent (a `fix/...-bank-preflight`
    # branch) would fail an assertion the runner never violates.
    assert_not_contains "$what bat has no bank-preflight" "bank-preflight" "$body_noroot"
    assert_not_contains "$what bat never shells claude"   "claude" "$body_noroot"
    assert_not_contains "$what bat has no --backend flag (LLM-free update)" "--backend" "$body"
    assert_not_contains "$what bat has no --settings (not a claude session)" "--settings" "$body"
done

# Test 7: status after arm ---------------------------------------------------

echo "TEST: status reflects armed tasks"
out=$(run_gc status)
assert_contains "luna armed"   "ARMED      HIMMEL-GraphMap-Luna"   "$out"
assert_contains "himmel armed" "ARMED      HIMMEL-GraphMap-Himmel" "$out"
assert_contains "ast-luna armed"   "ARMED      HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "ast-himmel armed" "ARMED      HIMMEL-GraphMapAst-Himmel" "$out"
assert_contains "status surfaces run log state" "run log" "$out"

# Test 8: re-arm without --force -> dedup block ------------------------------

echo "TEST: re-arm without --force blocked (rc 3)"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "dedup block rc 3" 3 "$rc"
assert_contains "dedup message names existing tasks" "HIMMEL-GraphMap-Himmel" "$out"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 4 ]; then
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
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 4 ]; then
    pass "still exactly four tasks after --force re-arm"
else
    fail "duplicate tasks after --force re-arm" "$(ls "$STATE/tasks")"
fi

# Test 9b: runner + shim publication is staged-then-renamed (HIMMEL-1753 r2) ---
#
# glm-3: the .bat/.vbs publishes used to redirect straight onto the FINAL
# paths, so a task firing concurrently with a re-arm could read a half-written
# shim. The fix stages each file to a temp BESIDE its final path and promotes
# with `mv` (an atomic same-filesystem rename). Post-hoc directory state can't
# distinguish rename-published from redirect-published, so the property is
# observed at the mechanism: a PATH-first RECORDING mv (delegates to the real
# mv, logs every call) must show each final path populated by a rename whose
# source is a staged sibling (dot-prefixed, same dir), and no staged temp may
# survive the arm. POSIX-form PATH entry (a mixed C:/ entry is invisible to
# Git-Bash); shebang is the pre-resolved REAL_BASH so it can never recurse
# into the fake bash stub.

echo "TEST: --force re-arm publishes runners + shims via staged atomic renames"
MVREC_BIN="$TMP_ROOT/mvrec-bin"
mkdir -p "$MVREC_BIN"
MVREC_BIN_PATH="$MVREC_BIN"
if command -v cygpath >/dev/null 2>&1; then MVREC_BIN_PATH=$(cygpath -u "$MVREC_BIN"); fi
FAKE_MV="$MVREC_BIN/mv"
cat >"$FAKE_MV" <<FAKE
#!$REAL_BASH
STATE="$STATE"
REAL_MV="$REAL_MV"
FAKE
cat >>"$FAKE_MV" <<'FAKE'
src=""; dst=""
for a in "$@"; do
  case "$a" in
    -*) : ;;
    *) if [ -z "$src" ]; then src="$a"; else dst="$a"; fi ;;
  esac
done
if [ -n "$dst" ]; then
  printf '%s -> %s\n' "$src" "$dst" >> "$STATE/mv-calls.log"
fi
exec "$REAL_MV" "$@"
FAKE
chmod +x "$FAKE_MV"
rm -f "$STATE/mv-calls.log"
out=$(PIPELINE_UNUSED="" GRAPHMAP_SCHTASKS="$FAKE_SCHTASKS" GRAPHMAP_BAT_DIR="$BAT_DIR" \
    PATH="$MVREC_BIN_PATH:$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" --force 2>&1)
assert_contains "re-arm under the recording mv still succeeds" "GRAPHMAP CADENCE ARMED" "$out"
mvlog=$(cat "$STATE/mv-calls.log" 2>/dev/null || echo MISSING)
for final in "$BAT_DIR/graphmap-luna.vbs" "$BAT_DIR/graphmap-himmel.vbs" \
             "$BAT_DIR/graphmap-ast-luna.vbs" "$BAT_DIR/graphmap-ast-himmel.vbs" \
             "$BAT_DIR/graphmap-luna.bat" "$BAT_DIR/graphmap-himmel.bat" \
             "$BAT_DIR/graphmap-ast-luna.bat" "$BAT_DIR/graphmap-ast-himmel.bat"; do
    name="$(basename "$final")"
    promotion=$(printf '%s\n' "$mvlog" | grep -F " -> $final" | tail -1)
    if [ -n "$promotion" ]; then
        pass "$name was published by a rename (not a direct redirect)"
    else
        fail "$name was never promoted via mv" "$mvlog"
    fi
    staged_src="${promotion% ->*}"
    case "$staged_src" in
        */.graphmap-*) pass "$name was renamed from a staged sibling temp" ;;
        *) fail "$name rename source is not a staged sibling" "$promotion" ;;
    esac
done
promotion_count=$(printf '%s\n' "$mvlog" | grep -cF " -> $BAT_DIR/graphmap-")
if [ "$promotion_count" -eq 8 ]; then
    pass "exactly eight runner promotions (4 shims + 4 bats, nothing else)"
else
    fail "expected 8 promotions, saw $promotion_count" "$mvlog"
fi
if ! compgen -G "$BAT_DIR/.graphmap-*" >/dev/null; then
    pass "no staged temp litter left in the runner dir"
else
    fail "staged temp litter left" "$(ls -A "$BAT_DIR")"
fi
# The shim at its final path is COMPLETE (the whole point of the rename): the
# Run line carrying the .bat path is present in full.
luna_vbs=$(cat "$BAT_DIR/graphmap-luna.vbs" 2>/dev/null || echo MISSING)
assert_contains "published luna shim is complete (hidden Run of the .bat)" 'graphmap-luna.bat""", 0, True)' "$luna_vbs"

# Test 10: disarm + idempotent second disarm ---------------------------------

echo "TEST: disarm removes tasks + runners; second disarm is a no-op"
out=$(run_gc disarm)
assert_contains "disarm reports" "cadence disarmed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "all tasks removed"
else
    fail "tasks left after disarm" "$(ls "$STATE/tasks")"
fi
if [ ! -f "$BAT_DIR/graphmap-luna.bat" ] && [ ! -f "$BAT_DIR/graphmap-himmel.bat" ] \
   && [ ! -f "$BAT_DIR/graphmap-ast-luna.bat" ] && [ ! -f "$BAT_DIR/graphmap-ast-himmel.bat" ]; then
    pass "all four .bat runners removed"
else
    fail ".bat runners left after disarm"
fi
rc=0; out=$(run_gc disarm) || rc=$?
assert_rc "second disarm rc 0" 0 "$rc"
assert_contains "second disarm is a no-op" "no-op" "$out"

# Test 10b: --ast-only (HIMMEL-2071), schtasks path -----------------------
#
# Mirrors the cron C8b block above (codex-2, CR round 1: --ast-only had no
# Windows/schtasks coverage) — same three properties: needs no semantic
# credential, registers only the two AST tasks, and an --ast-only --force
# re-arm over an existing full arm leaves the semantic pair's TASKS and
# runner files completely untouched.

echo "TEST: schtasks arm --ast-only --dry-run skips the semantic pair entirely"
out=$(run_gc arm --vault "$VAULT" --ast-only --dry-run)
assert_contains "schtasks ast-only dry-run says semantic pair skipped" "semantic pair" "$out"
assert_not_contains "schtasks ast-only dry-run has no luna /create"   "/tn $T_LUNA"   "$out"
assert_not_contains "schtasks ast-only dry-run has no himmel /create" "/tn $T_HIMMEL" "$out"
assert_contains "schtasks ast-only dry-run still creates ast-luna"   "/tn $T_AST_LUNA"   "$out"
assert_contains "schtasks ast-only dry-run still creates ast-himmel" "/tn $T_AST_HIMMEL" "$out"

echo "TEST: schtasks arm --ast-only needs no semantic-backend credential"
rc=0; out=$(unset MOONSHOT_API_KEY; GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    run_gc arm --vault "$VAULT" --ast-only 2>&1) || rc=$?
assert_rc "schtasks ast-only arm succeeds with no MOONSHOT_API_KEY anywhere" 0 "$rc"
if [ "$(find "$STATE/tasks" -mindepth 1 2>/dev/null | wc -l)" -eq 2 ]; then
    pass "schtasks ast-only arm registered exactly two tasks"
else
    fail "schtasks ast-only arm registered the wrong task count" "$(ls "$STATE/tasks" 2>/dev/null)"
fi
if [ -f "$STATE/tasks/$T_AST_LUNA" ] && [ -f "$STATE/tasks/$T_AST_HIMMEL" ]; then
    pass "schtasks ast-only arm's two AST tasks are registered"
else
    fail "schtasks ast-only arm did not register both AST tasks" "$(ls "$STATE/tasks" 2>/dev/null)"
fi
if [ ! -e "$STATE/tasks/$T_LUNA" ] && [ ! -e "$STATE/tasks/$T_HIMMEL" ]; then
    pass "schtasks ast-only arm registered NO semantic tasks"
else
    fail "schtasks ast-only arm registered a semantic task it should not have" "$(ls "$STATE/tasks")"
fi
if [ -f "$BAT_DIR/graphmap-ast-luna.bat" ] && [ -f "$BAT_DIR/graphmap-ast-himmel.bat" ] \
   && [ ! -e "$BAT_DIR/graphmap-luna.bat" ] && [ ! -e "$BAT_DIR/graphmap-himmel.bat" ]; then
    pass "schtasks ast-only arm wrote only the two AST .bat runners"
else
    fail "schtasks ast-only arm wrote the wrong runner set" "$(ls "$BAT_DIR")"
fi

echo "TEST: schtasks --ast-only --force re-arm never touches a pre-existing semantic pair"
out=$(run_gc arm --vault "$VAULT" --force 2>&1)   # full re-arm: now all four are registered
luna_bat_before=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
himmel_bat_before=$(cat "$BAT_DIR/graphmap-himmel.bat" 2>/dev/null || echo MISSING)
luna_task_before=$(cat "$STATE/tasks/$T_LUNA" 2>/dev/null || echo MISSING)
himmel_task_before=$(cat "$STATE/tasks/$T_HIMMEL" 2>/dev/null || echo MISSING)
out=$(run_gc arm --vault "$VAULT" --ast-only --force 2>&1)
assert_contains "schtasks ast-only --force re-arm banner" "GRAPHMAP CADENCE ARMED" "$out"
assert_contains "schtasks ast-only --force re-arm banner shows the pre-existing luna task as armed"   "$T_LUNA       already armed" "$out"
assert_contains "schtasks ast-only --force re-arm banner shows the pre-existing himmel task as armed" "$T_HIMMEL     already armed" "$out"
assert_not_contains "schtasks ast-only --force re-arm banner does not claim the pre-existing semantic pair is unarmed" "NOT armed (--ast-only)" "$out"
luna_bat_after=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
himmel_bat_after=$(cat "$BAT_DIR/graphmap-himmel.bat" 2>/dev/null || echo MISSING)
luna_task_after=$(cat "$STATE/tasks/$T_LUNA" 2>/dev/null || echo MISSING)
himmel_task_after=$(cat "$STATE/tasks/$T_HIMMEL" 2>/dev/null || echo MISSING)
if [ "$luna_bat_before" = "$luna_bat_after" ]; then
    pass "schtasks ast-only --force re-arm left the pre-existing luna .bat byte-identical"
else
    fail "schtasks ast-only --force re-arm rewrote the pre-existing luna .bat"
fi
if [ "$himmel_bat_before" = "$himmel_bat_after" ]; then
    pass "schtasks ast-only --force re-arm left the pre-existing himmel .bat byte-identical"
else
    fail "schtasks ast-only --force re-arm rewrote the pre-existing himmel .bat"
fi
if [ "$luna_task_before" = "$luna_task_after" ] && [ "$himmel_task_before" = "$himmel_task_after" ]; then
    pass "schtasks ast-only --force re-arm left the pre-existing semantic tasks byte-identical"
else
    fail "schtasks ast-only --force re-arm changed the pre-existing semantic tasks"
fi
if [ "$(find "$STATE/tasks" -mindepth 1 2>/dev/null | wc -l)" -eq 4 ]; then
    pass "schtasks ast-only --force re-arm still leaves exactly four tasks total"
else
    fail "unexpected task count after schtasks ast-only --force re-arm" "$(ls "$STATE/tasks")"
fi
run_gc disarm >/dev/null

# Test 11: cmd_escape — hostile-but-legal vault dirname can't inject ----------

echo "TEST: vault path with CMD metachars lands on the REAL dir in the .bat"
EVIL_VAULT="$TMP_ROOT/va&ult %X%^Y"
mkdir -p "$EVIL_VAULT"
out=$(run_gc arm --vault "$EVIL_VAULT")
# HIMMEL-1281: --corpus-root is interpolated INSIDE double quotes, where & is
# literal data and ^ is a literal character. Only % -> %% applies; the old
# caret escaping pointed graphify at a directory that does not exist.
# Assert the WHOLE `--corpus-root "<path>"` fragment as ONE contiguous string —
# see the note in test-pipeline-cadence.sh: separate opening/closing checks
# could match in two different places, and the quoting is exactly what makes
# the escape correct. Built the way the emitter builds it (cygpath -m for the
# bash-consumed corpus root, then % -> %%).
EVIL_VAULT_MIXED=$(cygpath -m "$EVIL_VAULT")
EVIL_CORPUS_EXPECTED="--corpus-root \"${EVIL_VAULT_MIXED//%/%%}\""
luna_bat=$(cat "$BAT_DIR/graphmap-luna.bat" 2>/dev/null || echo MISSING)
assert_contains "corpus-root is the real dir, fully quoted (% doubled, & ^ verbatim)" "$EVIL_CORPUS_EXPECTED" "$luna_bat"
assert_not_contains "no caret-escaped ampersand" '^&' "$luna_bat"
assert_not_contains "no doubled caret" '^^' "$luna_bat"
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

# Test 12b: full rollback when the FOURTH (last) /create fails -- regression
# guard for the create-loop generalization (HIMMEL-1948 Task 3): proves all
# THREE already-registered tasks are rolled back, not just a hardcoded one.
echo "TEST: ast-himmel /create failure rolls back all three prior tasks (rc 4)"
touch "$STATE/fail-create-HIMMEL-GraphMapAst-Himmel"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "full rollback fails rc 4" 4 "$rc"
assert_contains "failure names the ast-himmel create" "HIMMEL-GraphMapAst-Himmel failed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task state left after full rollback"
else
    fail "task state left after full rollback" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-GraphMapAst-Himmel"

# Test 12c: rollback when the FIRST /create fails -- regression guard for the
# empty-array TOCTOU/set-u bug (HIMMEL-1948 CR): when the first create fails,
# `created` is still empty, so the rollback loop's "${created[@]}" expansion
# is over an EMPTY array under this file's `set -euo pipefail`. On bash
# < 4.4 that is an unbound-variable error that would abort the rollback
# path before `rm -f "$err_file"` and before the deliberate `exit 4`,
# surfacing the wrong exit code and leaking the temp file. Assert rc 4 and
# no task state left behind either way.
echo "TEST: luna /create failure (the FIRST create) rolls back cleanly (rc 4)"
touch "$STATE/fail-create-HIMMEL-GraphMap-Luna"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "first-create failure fails rc 4" 4 "$rc"
assert_contains "failure names the luna create" "HIMMEL-GraphMap-Luna failed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task state left after first-create rollback"
else
    fail "task state left after first-create rollback" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-GraphMap-Luna"

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
if [ -f "$BAT_DIR/graphmap-luna.bat" ] && [ -f "$BAT_DIR/graphmap-himmel.bat" ] \
   && [ -f "$BAT_DIR/graphmap-ast-luna.bat" ] && [ -f "$BAT_DIR/graphmap-ast-himmel.bat" ]; then
    pass "all four .bat runners NOT deleted on query failure"
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

# Test 16 (HIMMEL-1948 CR r2): exact-name scoping — a scheduled task whose
# name merely STARTS WITH "HIMMEL-GraphMap" (not one of the four owned names)
# must be treated as neither ours-for-deletion (--force) nor ours-for-dedup.
# Reuses the (now-empty, post-disarm) $STATE/tasks from Test 15.
echo "TEST: schtasks scoping — unrelated HIMMEL-GraphMap*-prefixed task survives removal, never blocks arm"
touch "$STATE/tasks/HIMMEL-GraphMapExtra"
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "arm succeeds with only an unrelated prefixed task present (no false dedup-block)" 0 "$rc"
if [ -f "$STATE/tasks/HIMMEL-GraphMapExtra" ]; then
    pass "unrelated prefixed task survives arm"
else
    fail "unrelated prefixed task was deleted by arm"
fi
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 5 ]; then
    pass "unrelated task plus all four real cadence tasks present (5 total)"
else
    fail "unexpected task count after arm" "$(ls "$STATE/tasks")"
fi
rc=0; out=$(run_gc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "re-arm without --force now dedup-blocks on the REAL tasks" 3 "$rc"
assert_contains "dedup message names a real owned task" "HIMMEL-GraphMap-Luna" "$out"
assert_not_contains "dedup message does not name the unrelated task" "HIMMEL-GraphMapExtra" "$out"
out=$(run_gc arm --vault "$VAULT" --force 2>&1)
if [ -f "$STATE/tasks/HIMMEL-GraphMapExtra" ]; then
    pass "unrelated prefixed task still survives a --force re-arm"
else
    fail "unrelated prefixed task was deleted by --force re-arm"
fi
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 5 ]; then
    pass "still exactly five tasks (4 real + 1 unrelated) after --force re-arm"
else
    fail "unexpected task count after --force re-arm" "$(ls "$STATE/tasks")"
fi
out=$(run_gc disarm)
if [ -f "$STATE/tasks/HIMMEL-GraphMapExtra" ]; then
    pass "unrelated prefixed task survives disarm"
else
    fail "unrelated prefixed task was deleted by disarm"
fi
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 1 ]; then
    pass "disarm removed exactly the four owned tasks, left the unrelated one"
else
    fail "disarm removed or left the wrong tasks" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/tasks/HIMMEL-GraphMapExtra"

summary
