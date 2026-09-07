#!/usr/bin/env bash
# Execution tests for run-codex-adversarial.sh process cleanup and leases (HIMMEL-1474 r6).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-codex-adversarial.sh"
# HIMMEL-2226: the step-3 kickoff and step-3.1 harvest fences left
# .claude/commands/pr-check.md for real scripts (a worktree-isolated Bash tool
# refuses shell function definitions and `IFS= read` on a command line, which
# made the fences unrunnable from a worktree -- the normal place himmel feature
# work happens). Every assertion below that used to awk-extract a fence out of
# the runbook and eval it now runs the real script instead, which also retires
# the HIMMEL-2160 coupling that left this suite red on a green pr-check.md.
KICKOFF="$HERE/codex-adv-kickoff.sh"
HARVEST="$HERE/codex-adv-harvest.sh"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/../lib/proc-tree.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-run-codex-adversarial.XXXXXX")"
fails=0
unrelated_pid=''

cleanup() {
    if [ -n "$unrelated_pid" ]; then
        kill -9 "$unrelated_pid" 2>/dev/null || true
        wait "$unrelated_pid" 2>/dev/null || true
    fi
    if [ -s "$tmp/child.pid" ]; then
        child_pid=$(cat "$tmp/child.pid")
        kill -9 "$child_pid" 2>/dev/null || true
        if command -v taskkill >/dev/null 2>&1; then
            MSYS_NO_PATHCONV=1 taskkill /PID "$child_pid" /T /F >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# --- HIMMEL-2226 fence fixture -------------------------------------------
# codex-adv-kickoff.sh and codex-adv-harvest.sh derive their himmel root from
# $0/../.. and source scripts/lib/proc-tree.sh from it, so the fixture is a
# himmel-SHAPED tree: copying the two scripts (plus the libs they source and
# the completion check they shell out to) next to a stub proc-tree.sh makes
# every identity/liveness/terminate outcome deterministic on every platform --
# the same technique the launcher fixture below uses. Because a function
# definition shadows the `kill` builtin and the `sleep` binary for the whole
# sourcing script, no signal from a recovery test can ever reach a real
# process and no test spends wall-clock in a retry loop.
# HOME is pinned to an empty fixture dir on EVERY invocation: the companion is
# resolved through a $HOME-rooted glob (so no codex render is ever spawned and
# nothing touches the network) and the render-lease registry is $HOME-rooted
# too (RENDER_LEASE_DIR is pinned as well, belt and braces).
fx="$tmp/fence-fixture"
mkdir -p "$fx/scripts/cr" "$fx/scripts/lib" "$fx/scripts/guardrails" \
         "$fx/home" "$fx/leases" "$fx/repo"
# run-codex-adversarial.sh is deliberately NOT copied in: with an empty
# fixture HOME the companion glob never resolves, so no case can reach a
# launch -- and if one ever did, the missing launcher fails loudly instead of
# starting a real render.
cp "$KICKOFF" "$HARVEST" "$HERE/codex-adv-completion-check.sh" "$fx/scripts/cr/"
cp "$HERE/../lib/load-dotenv.sh" "$HERE/../lib/render-lease.sh" "$fx/scripts/lib/"
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/"
cat > "$fx/scripts/lib/proc-tree.sh" <<'SH'
# Deterministic proc-tree stub (HIMMEL-2226 test fixture). Behaviour knobs are
# plain env vars; the *_RULES maps are space-separated "<pid>:<value>" pairs
# that override the per-call default for a named pid.
_h2226_rule() {
    local map="$1" key="$2" def="$3" entry
    for entry in $map; do
        case "$entry" in
            "$key":*) printf '%s\n' "${entry#*:}"; return 0 ;;
        esac
    done
    printf '%s\n' "$def"
}
# A "killable" pid is a recorded survivor: it verifies and is alive until the
# recovery path TERMs it, and is confirmed gone afterwards.
_h2226_killable() {
    local entry
    for entry in ${H2226_KILLABLE:-}; do
        [ "$entry" = "$1" ] && return 0
    done
    return 1
}
proc_tree_is_windows() { return 1; }
proc_tree_winpid() { printf '%s\n' "$1"; }
proc_tree_group_members() { return 1; }
proc_tree_group_terminate() { return "${H2226_TERMINATE_RC:-0}"; }
proc_tree_process_identity() {
    local value
    value=$(_h2226_rule "${H2226_IDENTITY_VALUES:-}" "$1" "")
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}
proc_tree_process_identity_matches() {
    [ -z "${H2226_PROBE_LOG:-}" ] || printf '%s\n' "$1" >> "$H2226_PROBE_LOG"
    if _h2226_killable "$1"; then
        [ -e "${H2226_KILLED_MARKER:-/nonexistent}" ] && return 1
        return 0
    fi
    return "$(_h2226_rule "${H2226_IDENTITY_RULES:-}" "$1" "${H2226_IDENTITY_RC:-0}")"
}
proc_tree_process_alive() {
    if _h2226_killable "$1"; then
        [ -e "${H2226_KILLED_MARKER:-/nonexistent}" ] && return 1
        return 0
    fi
    return "$(_h2226_rule "${H2226_ALIVE_RULES:-}" "$1" "${H2226_ALIVE_RC:-1}")"
}
proc_tree_terminate() {
    [ -z "${H2226_TERMINATE_LOG:-}" ] || printf '%s %s %s\n' "$1" "$2" "$3" >> "$H2226_TERMINATE_LOG"
    return "$(_h2226_rule "${H2226_TERMINATE_RULES:-}" "$1" "${H2226_TERMINATE_RC:-0}")"
}
kill() {
    [ -z "${H2226_SIGNAL_LOG:-}" ] || printf '%s:%s\n' "$1" "$2" >> "$H2226_SIGNAL_LOG"
    [ "$1" != "-TERM" ] || [ -z "${H2226_KILLED_MARKER:-}" ] || : > "$H2226_KILLED_MARKER"
    return 0
}
sleep() {
    [ -z "${H2226_SLEEP_LOG:-}" ] || printf 's\n' >> "$H2226_SLEEP_LOG"
    # Fires only once the terminate stub has run, so a hook can model the
    # launcher wrapper publishing its rc/cleanup status a beat AFTER the
    # harvest's cleanup attempt without perturbing the identity wait loop
    # that runs before it.
    if [ -n "${H2226_SLEEP_HOOK:-}" ] && [ -s "${H2226_TERMINATE_LOG:-/nonexistent}" ]; then
        bash "$H2226_SLEEP_HOOK"
    fi
    return 0
}
SH
(
    cd "$fx/repo" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
)
adv="$fx/repo/.git/codex-adv-out"
mkdir -p "$adv"
export H2226_PROBE_LOG="$fx/probe.log" H2226_SIGNAL_LOG="$fx/signals.log" \
       H2226_TERMINATE_LOG="$fx/terminate.log" H2226_SLEEP_LOG="$fx/sleep.log" \
       H2226_KILLED_MARKER="$fx/killed"
# Each case owns a fresh branch (so its .git/codex-adv-out/<branch>.* sidecars
# cannot collide with another case's) and a clean stub-log set.
fixture_reset() {
    : > "$fx/probe.log"; : > "$fx/signals.log"
    : > "$fx/terminate.log"; : > "$fx/sleep.log"
    rm -f "$fx/killed"
}
# run_kickoff/run_harvest <branch> [VAR=value ...] -- the trailing assignments
# are this case's stub knobs, handed to `env` so they cannot leak into the next
# case. CR_PROFILE is set non-empty so load-dotenv's non-clobbering load can
# never pull a real value out of a checkout's .env and change which branch of
# the script under test fires.
run_kickoff() {
    local branch="$1"; shift
    ( cd "$fx/repo" && git checkout -q -B "$branch" >/dev/null 2>&1 &&
      env HOME="$fx/home" RENDER_LEASE_DIR="$fx/leases" CR_PROFILE=fixturetest "$@" \
        bash "$fx/scripts/cr/codex-adv-kickoff.sh" )
}
run_harvest() {
    local branch="$1"; shift
    ( cd "$fx/repo" && git checkout -q -B "$branch" >/dev/null 2>&1 &&
      env HOME="$fx/home" RENDER_LEASE_DIR="$fx/leases" CR_PROFILE=fixturetest "$@" \
        bash "$fx/scripts/cr/codex-adv-harvest.sh" )
}

# HIMMEL-1957: the default-dormant path must look exactly like companion
# absence to /pr-check: clean rc, no process/ownership pid, and therefore no
# harvest attempt or availability record. Model the kickoff subshell too, which
# writes the wrapper rc after it returns.
unset CODEX_ADV_OK
mkdir -p "$tmp/dormant-stub-bin"
cat > "$tmp/dormant-stub-bin/node" <<'SH'
#!/usr/bin/env bash
: > "${HIMMEL_1957_COMPANION_STARTED:?}"
SH
chmod +x "$tmp/dormant-stub-bin/node"
(
    PATH="$tmp/dormant-stub-bin:$PATH" HIMMEL_1957_COMPANION_STARTED="$tmp/companion.started" \
        bash "$RUNNER" "$tmp/not-used.mjs" main "$tmp/dormant.stdout" "$tmp/dormant.stderr" "$tmp/dormant.pid" \
        2>"$tmp/dormant-runner.stderr"
    printf '%s\n' "$?" > "$tmp/dormant.rc"
)
check "dormant launch exits as a clean skip" "$(cat "$tmp/dormant.rc")" "0"
check "dormant launch spawns no node process" "$(test -e "$tmp/companion.started" && echo spawned || echo absent)" "absent"
check "dormant launch publishes no ownership pid" "$(test -e "$tmp/dormant.pid" && echo published || echo absent)" "absent"
check "dormant launch reports exactly one skip line" "$(wc -l < "$tmp/dormant-runner.stderr" | tr -d ' ')" "1"
check "dormant skip names its reason and opt-in" "$(cat "$tmp/dormant-runner.stderr")" "codex adversarial pass skipped: dormant pending investigation (HIMMEL-1957); set CODEX_ADV_OK=1 to launch"
# HIMMEL-2056: the dormant skip also writes a one-line machine-readable
# sentinel to stdout_file so codex-adv-completion-check.sh can positively
# classify it as ABSENT, never a HIMMEL-1420 silent death, wherever it's read.
check "dormant launch writes the ABSENT sentinel to stdout_file" "$(cat "$tmp/dormant.stdout" 2>/dev/null)" "codex-adv: dormant (HIMMEL-1957)"
# The harvest tests pid presence before reading rc or assigning an
# availability status; companion-absent and dormant-wrapper paths both have no
# pid. HIMMEL-2226: assert that end to end against the real harvest script --
# feed it the dormant launcher's OWN stdout with no ownership pid and require
# the dormant/absent classification, no findings, and NO availability record.
fixture_reset
cp "$tmp/dormant.stdout" "$adv/h-dormant"
harvest_dormant_rc=0
harvest_dormant_out=$(run_harvest h-dormant 2>"$fx/h-dormant.err") || harvest_dormant_rc=$?
check "dormant harvest exits clean" "$harvest_dormant_rc" "0"
check "harvest treats a missing pid as not launched" "$harvest_dormant_out" "codex-adv: dormant/absent (HIMMEL-1957) -- not launched, no retry"
check "dormant harvest records no availability status" "$(grep -Fc 'codex-adv-status:' "$fx/h-dormant.err")" "0"

# Every remaining test exercises the pre-existing live path.
export CODEX_ADV_OK=1

cat > "$tmp/stubborn-child.mjs" <<'JS'
import fs from 'node:fs';
const heartbeat = process.argv[2];
process.on('SIGTERM', () => {});
setInterval(() => fs.appendFileSync(heartbeat, 'x'), 100);
JS

cat > "$tmp/companion.mjs" <<'JS'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childScript = process.env.HIMMEL_R2_CHILD_SCRIPT;
const childPidFile = process.env.HIMMEL_R2_CHILD_PID_FILE;
const heartbeat = process.env.HIMMEL_R2_HEARTBEAT;
const child = spawn(process.execPath, [childScript, heartbeat], { stdio: 'ignore' });
fs.writeFileSync(childPidFile, String(child.pid));
process.on('SIGTERM', () => {});
setInterval(() => {}, 1000);
JS

cat > "$tmp/companion-exits.mjs" <<'JS'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childScript = process.env.HIMMEL_R2_CHILD_SCRIPT;
const childPidFile = process.env.HIMMEL_R2_CHILD_PID_FILE;
const heartbeat = process.env.HIMMEL_R2_HEARTBEAT;
const child = spawn(process.execPath, [childScript, heartbeat], { stdio: 'ignore' });
fs.writeFileSync(childPidFile, String(child.pid));
child.unref();
await new Promise(resolve => setTimeout(resolve, 2500));
JS

# HIMMEL-1474 r5: exercise the lease launch against a copied runner and a
# proc-tree stub so both host branches are deterministic on every platform.
mkdir -p "$tmp/lease-fixture/cr" "$tmp/lease-fixture/lib" "$tmp/lease-fixture/stub-bin"
cp "$RUNNER" "$tmp/lease-fixture/cr/run-codex-adversarial.sh"
# HIMMEL-1509: the runner sources the real render-lease lib; lease behavior
# stays inert unless a test opts in via RENDER_LEASE_BRANCH.
cp "$HERE/../lib/render-lease.sh" "$tmp/lease-fixture/lib/render-lease.sh"
: > "$tmp/lease-fixture/cr/codex-render-client-lease.ps1"
cat > "$tmp/lease-fixture/lib/proc-tree.sh" <<'SH'
proc_tree_is_windows() {
    [ "${HIMMEL_R5_WINDOWS:-0}" = "1" ]
}
proc_tree_winpid() {
    printf '%s\n' "${HIMMEL_R5_WINPID:-}"
}
proc_tree_process_identity() {
    if [ "${HIMMEL_R11_IDENTITY_UNAVAILABLE:-0}" = "1" ]; then
        [ -z "${HIMMEL_R12_IDENTITY_PROBE_CALLED:-}" ] || printf x >> "$HIMMEL_R12_IDENTITY_PROBE_CALLED"
        return 1
    fi
    printf '%s\n' test-identity
}
proc_tree_process_identity_matches() {
    return "${HIMMEL_R6_IDENTITY_RC:-0}"
}
proc_tree_group_members() {
    [ -z "${HIMMEL_R14_GROUP_MEMBERS:-}" ] || printf '%s\n' "$HIMMEL_R14_GROUP_MEMBERS"
    return "${HIMMEL_R14_GROUP_MEMBERS_RC:-0}"
}
proc_tree_terminate() {
    return "${HIMMEL_R6_TERMINATE_RC:-0}"
}
proc_tree_group_terminate() {
    [ -z "${HIMMEL_R6_GROUP_TERMINATE_CALLED:-}" ] || : > "$HIMMEL_R6_GROUP_TERMINATE_CALLED"
    if [ "${HIMMEL_R11_TERMINATE_REAL_GROUP:-0}" = "1" ]; then
        kill -TERM -"$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
    fi
    return "${HIMMEL_R6_GROUP_TERMINATE_RC:-0}"
}
SH
cat > "$tmp/lease-fixture/stub-bin/pwsh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HIMMEL_R5_PWSH_ARGS:?}"
SH
chmod +x "$tmp/lease-fixture/stub-bin/pwsh"
cat > "$tmp/lease-fixture/companion.mjs" <<'JS'
await new Promise(resolve => setTimeout(resolve, 100));
JS
cat > "$tmp/lease-fixture/companion-lease.mjs" <<'JS'
import fs from 'node:fs';
if (process.env.HIMMEL_1957_COMPANION_STARTED) {
    fs.writeFileSync(process.env.HIMMEL_1957_COMPANION_STARTED, 'started');
}
await new Promise(resolve => setTimeout(resolve, 3000));
JS
cat > "$tmp/lease-fixture/companion-delayed.mjs" <<'JS'
await new Promise(resolve => setTimeout(resolve, 12000));
JS
cat > "$tmp/lease-fixture/companion-fails.mjs" <<'JS'
process.exit(7);
JS

rm -f "$tmp/lease-windows.args" "$tmp/lease-windows.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=424242 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-windows.args" \
HIMMEL_1957_COMPANION_STARTED="$tmp/companion.started" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-lease.mjs" main "$tmp/lease-windows.stdout" "$tmp/lease-windows.stderr" "$tmp/lease-windows.pid" || runner_rc=$?
check "CODEX_ADV_OK=1 reaches the live launch path" "$(test -e "$tmp/companion.started" && echo started || echo absent)" "started"
check "Windows lease runner exits 0" "$runner_rc" "0"
check "Windows ownership pid sidecar is nonempty" "$(test -s "$tmp/lease-windows.pid" && echo nonempty || echo empty)" "nonempty"
check "Windows ownership identity sidecar is nonempty" "$(test -s "$tmp/lease-windows.pid.identity" && echo nonempty || echo empty)" "nonempty"
lease_pid=$(awk 'previous == "-ClientPid" { print; exit } { previous = $0 }' "$tmp/lease-windows.args" 2>/dev/null)
check "Windows lease receives translated native pid" "$lease_pid" "424242"

rm -f "$tmp/lease-posix.args" "$tmp/lease-posix.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=0 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-posix.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-posix.stdout" "$tmp/lease-posix.stderr" "$tmp/lease-posix.pid" || runner_rc=$?
check "POSIX lease runner exits 0" "$runner_rc" "0"
check "POSIX ownership pid sidecar is nonempty" "$(test -s "$tmp/lease-posix.pid" && echo nonempty || echo empty)" "nonempty"
check "POSIX ownership identity sidecar is nonempty" "$(test -s "$tmp/lease-posix.pid.identity" && echo nonempty || echo empty)" "nonempty"
lease_pid=$(awk 'previous == "-ClientPid" { print; exit } { previous = $0 }' "$tmp/lease-posix.args" 2>/dev/null)
check "POSIX lease receives unchanged node pid" "$lease_pid" "$(cat "$tmp/lease-posix.pid")"

rm -f "$tmp/lease-invalid.args" "$tmp/lease-invalid.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=not-a-pid \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-invalid.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-invalid.stdout" "$tmp/lease-invalid.stderr" "$tmp/lease-invalid.pid" || runner_rc=$?
check "invalid native pid runner exits 0" "$runner_rc" "0"
check "invalid native pid skips lease writer" "$(test -e "$tmp/lease-invalid.args" && echo launched || echo skipped)" "skipped"

# HIMMEL-1509: the branch render lease. RENDER_LEASE_BRANCH opts the launcher
# into the registry: atomic claim before node spawns, release only on a
# verified-clean exit, refusal (exit 75) on a held branch or unusable registry.
reg1509="$tmp/reg-1509"
rm -rf "$reg1509" "$tmp/lease-1509.pid"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-clean \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R5_WINDOWS=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509.stdout" "$tmp/lease-1509.stderr" "$tmp/lease-1509.pid" 2>"$tmp/lease-1509-runner.stderr" || runner_rc=$?
check "leased clean run exits 0" "$runner_rc" "0"
check "leased clean run creates the registry" "$(test -d "$reg1509" && echo present || echo absent)" "present"
check "verified-clean exit releases the branch lease" "$(test -e "$reg1509/feat+2F1509-clean" && echo held || echo released)" "released"

# The Windows heartbeat writer receives the lease dir so it can refresh the
# registry heartbeat + tokens alongside the cxc client lease.
rm -f "$tmp/lease-1509-win.args" "$tmp/lease-1509-win.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-win \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=424242 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-1509-win.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-lease.mjs" main "$tmp/lease-1509-win.stdout" "$tmp/lease-1509-win.stderr" "$tmp/lease-1509-win.pid" || runner_rc=$?
check "leased Windows runner exits 0" "$runner_rc" "0"
lease_dir_arg=$(awk 'previous == "-LeaseDir" { print; exit } { previous = $0 }' "$tmp/lease-1509-win.args" 2>/dev/null)
check "heartbeat writer receives the lease dir" "$(printf '%s\n' "$lease_dir_arg" | grep -Fc 'feat+2F1509-win')" "1"

# Second launch on a branch holding a live lease refuses loudly, spawns
# nothing, and preserves the holder's record (the HIMMEL-1496 TOCTOU closure).
mkdir -p "$reg1509/feat+2F1509-held"
printf 'branch\tfeat/1509-held\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t424242\nleader_winpid\t424242\nleader_identity\ttest-identity\nstatus\trunning\n' \
    "$tmp" > "$reg1509/feat+2F1509-held/lease.record"
rm -f "$tmp/lease-1509-refused.stdout"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-held \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_IDENTITY_RC=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-refused.stdout" "$tmp/lease-1509-refused.stderr" 2>"$tmp/lease-1509-refused-runner.stderr" || runner_rc=$?
check "second launch on a held branch exits 75" "$runner_rc" "75"
check "refused launch emits loud diagnostic" "$(grep -Fc 'launch REFUSED' "$tmp/lease-1509-refused-runner.stderr" 2>/dev/null)" "1"
check "refused launch spawns no companion" "$(test -e "$tmp/lease-1509-refused.stdout" && echo spawned || echo refused)" "refused"
check "refused launch preserves the holder record" "$(test -s "$reg1509/feat+2F1509-held/lease.record" && echo preserved || echo missing)" "preserved"

# A stale lease with a CONFIRMED-dead leader is reclaimed by the next launch.
mkdir -p "$reg1509/feat+2F1509-stale"
printf 'branch\tfeat/1509-stale\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2020-01-01T00:00:00Z\nleader_pid\t424243\nleader_winpid\t424243\nleader_identity\ttest-identity\nstatus\trunning\n' \
    "$tmp" > "$reg1509/feat+2F1509-stale/lease.record"
touch -t 202001010000 "$reg1509/feat+2F1509-stale/lease.record"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-stale \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_IDENTITY_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-stale.stdout" "$tmp/lease-1509-stale.stderr" 2>"$tmp/lease-1509-stale-runner.stderr" || runner_rc=$?
check "stale-lease launch reclaims and exits 0" "$runner_rc" "0"
check "stale-lease launch announces the reclaim" "$(grep -Fc 'reclaiming stale lease' "$tmp/lease-1509-stale-runner.stderr" 2>/dev/null)" "1"
check "reclaimed lease is released on clean exit" "$(test -e "$reg1509/feat+2F1509-stale" && echo held || echo released)" "released"

# An UNVERIFIED exit (cleanup rc nonzero) leaves the lease for adjudication.
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-dirty \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-dirty.stdout" "$tmp/lease-1509-dirty.stderr" 2>"$tmp/lease-1509-dirty-runner.stderr" || runner_rc=$?
check "unverified-cleanup leased run exits 125" "$runner_rc" "125"
check "unverified exit preserves the lease" "$(test -s "$reg1509/feat+2F1509-dirty/lease.record" && echo preserved || echo released)" "preserved"
check "preserved lease is announced for adjudication" "$(grep -Fc 'lease preserved for adjudication' "$tmp/lease-1509-dirty-runner.stderr" 2>/dev/null)" "1"

# An unusable registry refuses the launch (fail-closed) instead of running
# untracked.
printf 'not a dir' > "$tmp/reg-blocker"
runner_rc=0
RENDER_LEASE_DIR="$tmp/reg-blocker/sub" RENDER_LEASE_BRANCH=feat/1509-broken \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-broken.stdout" "$tmp/lease-1509-broken.stderr" 2>"$tmp/lease-1509-broken-runner.stderr" || runner_rc=$?
check "unusable registry refuses the launch with 75" "$runner_rc" "75"
check "unusable registry refusal is loud" "$(grep -Fc 'launch REFUSED' "$tmp/lease-1509-broken-runner.stderr" 2>/dev/null)" "1"

# HIMMEL-1509 launch claim. Both scripts export the per-branch claim before
# invoking the shared launcher (kickoff for the background render, harvest for
# its bounded retry). Neither launch path can be exercised here without
# spawning a real render, so this stays a source-level assertion -- but now
# against the scripts that carry the wiring rather than the runbook prose that
# no longer does (HIMMEL-2160: that coupling is exactly what left this suite
# red on a green pr-check.md).
# shellcheck disable=SC2016
lease_export_wiring=$(cat "$KICKOFF" "$HARVEST" | grep -Fc 'export RENDER_LEASE_BRANCH="$branch"')
check "kickoff and harvest both export the launch claim" "$lease_export_wiring" "2"
# The lease PROBE is behavioural: a live lease on this branch must refuse the
# kickoff loudly, spawn nothing, and leave the holder's record intact. This
# also subsumes the retired "kickoff sources the render-lease lib" text grep --
# a grep for a source line is vacuous once the probe it enables is executed,
# because the probe cannot fire at all unless the lib is sourced.
fixture_reset
mkdir -p "$fx/leases/h-leased"
printf 'branch\th-leased\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t424242\nleader_identity\ttest-identity\nstatus\trunning\n' \
    "$fx/repo" > "$fx/leases/h-leased/lease.record"
kickoff_leased_rc=0
run_kickoff h-leased \
    H2226_IDENTITY_RC=0 >"$fx/k-leased.out" 2>"$fx/k-leased.err" || kickoff_leased_rc=$?
check "kickoff pre-flights the branch lease probe" "$kickoff_leased_rc" "1"
check "lease-refused kickoff names the live lease" "$(grep -Fc 'holds a live render lease' "$fx/k-leased.err")" "1"
check "lease-refused kickoff preserves the holder record" "$(test -s "$fx/leases/h-leased/lease.record" && echo preserved || echo missing)" "preserved"
check "lease-refused kickoff publishes no ownership pid" "$(test -e "$adv/h-leased.pid" && echo published || echo absent)" "absent"

# HIMMEL-1474 r11: launch identity is a required ownership handshake. Persistent
# INITIAL probe failure must terminate the still-owned group before returning,
# and must never publish a pid without its identity anchor.
rm -f "$tmp/initial-identity.pid" "$tmp/initial-identity.pid.identity" "$tmp/initial-identity-terminated"
runner_rc=0
HIMMEL_R11_IDENTITY_UNAVAILABLE=1 \
HIMMEL_R11_TERMINATE_REAL_GROUP=1 \
HIMMEL_R6_GROUP_TERMINATE_CALLED="$tmp/initial-identity-terminated" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/initial-identity.stdout" "$tmp/initial-identity.stderr" "$tmp/initial-identity.pid" 2>"$tmp/initial-identity-runner.stderr" || runner_rc=$?
check "initial identity failure returns unavailable" "$runner_rc" "125"
check "initial identity failure terminates the owned group" "$(test -e "$tmp/initial-identity-terminated" && echo terminated || echo missed)" "terminated"
check "initial identity failure publishes no pid" "$(test -e "$tmp/initial-identity.pid" && echo published || echo absent)" "absent"
check "initial identity failure publishes no identity" "$(test -e "$tmp/initial-identity.pid.identity" && echo published || echo absent)" "absent"
initial_identity_diagnostic=$(grep -Fc "process identity could not be captured" "$tmp/initial-identity-runner.stderr" 2>/dev/null)
check "initial identity failure reports unavailable launch" "$initial_identity_diagnostic" "1"

# HIMMEL-1474 r12: a signal during that identity retry window must either reap
# the still-owned group or publish recovery handles before the wrapper exits.
rm -f "$tmp/handshake-signal.pid" "$tmp/handshake-signal.pid.identity" "$tmp/handshake-signal.pid.cleanup-rc" "$tmp/handshake-signal-probed"
HIMMEL_R11_IDENTITY_UNAVAILABLE=1 \
HIMMEL_R12_IDENTITY_PROBE_CALLED="$tmp/handshake-signal-probed" \
HIMMEL_R11_TERMINATE_REAL_GROUP=1 \
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/handshake-signal.stdout" "$tmp/handshake-signal.stderr" "$tmp/handshake-signal.pid" 0 "$tmp/handshake-signal.pid.cleanup-rc" 2>"$tmp/handshake-signal-runner.stderr" &
handshake_wrapper_pid=$!
waited=0
while [ ! -e "$tmp/handshake-signal-probed" ] && kill -0 "$handshake_wrapper_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
handshake_probes_before=$(wc -c < "$tmp/handshake-signal-probed" | tr -d ' ')
kill -TERM "$handshake_wrapper_pid" 2>/dev/null || true
handshake_signal_rc=0
wait "$handshake_wrapper_pid" 2>/dev/null || handshake_signal_rc=$?
handshake_probes_after=$(wc -c < "$tmp/handshake-signal-probed" | tr -d ' ')
check "signal during identity handshake exits 143" "$handshake_signal_rc" "143"
check "failed signal cleanup retries identity acquisition" "$([ "$handshake_probes_after" -gt "$handshake_probes_before" ] && echo retried || echo missed)" "retried"
check "failed handshake identity reacquisition leaves no pid marker" "$(test -e "$tmp/handshake-signal.pid" && echo published || echo absent)" "absent"
check "failed handshake identity reacquisition leaves no identity marker" "$(test -e "$tmp/handshake-signal.pid.identity" && echo published || echo absent)" "absent"
check "unverified handshake signal publishes cleanup status" "$(cat "$tmp/handshake-signal.pid.cleanup-rc" 2>/dev/null)" "1"
handshake_unrecoverable_diagnostic=$(grep -Fc "signal cleanup UNRECOVERABLE" "$tmp/handshake-signal-runner.stderr" 2>/dev/null)
check "failed handshake identity reacquisition emits loud diagnostic" "$handshake_unrecoverable_diagnostic" "1"

# HIMMEL-1474 r6: a cleanup primitive failure is separate from the companion
# result. A clean companion cannot publish rc 0 while its group may survive.
runner_rc=0
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/cleanup.stdout" "$tmp/cleanup.stderr" 2>"$tmp/cleanup-runner.stderr" || runner_rc=$?
check "cleanup failure after companion success exits 125" "$runner_rc" "125"
cleanup_diagnostic=$(grep -Fc "codex adversarial cleanup failed for pid/group" "$tmp/cleanup-runner.stderr" 2>/dev/null)
check "cleanup failure names the pid/group on stderr" "$cleanup_diagnostic" "1"

rm -f "$tmp/group-terminate-called" "$tmp/identity-unavailable.pid" "$tmp/identity-unavailable.pid.identity"
runner_rc=0
identity_started=$SECONDS
HIMMEL_R6_IDENTITY_RC=2 HIMMEL_R6_GROUP_TERMINATE_CALLED="$tmp/group-terminate-called" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/identity-unavailable.stdout" "$tmp/identity-unavailable.stderr" "$tmp/identity-unavailable.pid" 1 2>"$tmp/identity-unavailable-runner.stderr" || runner_rc=$?
identity_elapsed=$((SECONDS - identity_started))
check "identity-unavailable timeout keeps rc 124" "$runner_rc" "124"
check "identity-unavailable timeout skips blocking wait" "$([ "$identity_elapsed" -lt 10 ] && echo bounded || echo blocked)" "bounded"
check "identity-unavailable cleanup sends no group signal" "$(test -e "$tmp/group-terminate-called" && echo signaled || echo skipped)" "skipped"
check "identity-unavailable timeout preserves pid sidecar" "$(test -s "$tmp/identity-unavailable.pid" && echo preserved || echo missing)" "preserved"
check "identity-unavailable timeout preserves identity sidecar" "$(test -s "$tmp/identity-unavailable.pid.identity" && echo preserved || echo missing)" "preserved"
identity_cleanup_diagnostic=$(grep -Fc "identity probe unavailable; no signal sent" "$tmp/identity-unavailable-runner.stderr" 2>/dev/null)
check "identity-unavailable cleanup emits diagnostic" "$identity_cleanup_diagnostic" "1"
identity_wait_diagnostic=$(grep -Fc "timeout cleanup incomplete for pid/group" "$tmp/identity-unavailable-runner.stderr" 2>/dev/null)
check "identity-unavailable timeout reports skipped blocking wait" "$identity_wait_diagnostic" "1"
identity_unavailable_pid=$(cat "$tmp/identity-unavailable.pid")
kill -9 "$identity_unavailable_pid" 2>/dev/null || true
if command -v taskkill >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 taskkill /PID "$identity_unavailable_pid" /T /F >/dev/null 2>&1 || true
fi

runner_rc=0
HIMMEL_R6_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/cleanup-timeout.stdout" "$tmp/cleanup-timeout.stderr" "" 1 2>"$tmp/cleanup-timeout-runner.stderr" || runner_rc=$?
check "timeout keeps rc 124 when cleanup fails" "$runner_rc" "124"
timeout_cleanup_diagnostic=$(grep -Fc "codex adversarial cleanup failed for pid/group" "$tmp/cleanup-timeout-runner.stderr" 2>/dev/null)
check "timeout cleanup failure still emits diagnostic" "$timeout_cleanup_diagnostic" "1"

# HIMMEL-1501: proc_tree_terminate rc 3 (confirmed-gone before any signal) is
# distinct from rc 1/2 but must still be treated as "cleanup unverified" by
# publish_cleanup_rc -- the leader-only check never saw the group, so a
# survivors sidecar is still published for recovery.
rm -f "$tmp/cleanup-confirmed-gone.pid" "$tmp/cleanup-confirmed-gone.pid.identity" "$tmp/cleanup-confirmed-gone.pid.survivors"
runner_rc=0
HIMMEL_R6_TERMINATE_RC=3 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/cleanup-confirmed-gone.stdout" "$tmp/cleanup-confirmed-gone.stderr" "$tmp/cleanup-confirmed-gone.pid" 1 2>"$tmp/cleanup-confirmed-gone-runner.stderr" || runner_rc=$?
check "confirmed-gone (rc 3) timeout keeps rc 124" "$runner_rc" "124"
check "confirmed-gone (rc 3) preserves ownership pid sidecar" "$(test -s "$tmp/cleanup-confirmed-gone.pid" && echo preserved || echo missing)" "preserved"
check "confirmed-gone (rc 3) publishes a survivors sidecar" "$(test -e "$tmp/cleanup-confirmed-gone.pid.survivors" && echo published || echo absent)" "published"
confirmed_gone_pid=$(cat "$tmp/cleanup-confirmed-gone.pid" 2>/dev/null)
if [ -n "$confirmed_gone_pid" ]; then
    kill -9 "$confirmed_gone_pid" 2>/dev/null || true
    if command -v taskkill >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 taskkill /PID "$confirmed_gone_pid" /T /F >/dev/null 2>&1 || true
    fi
fi

runner_rc=0
HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    bash "$RUNNER" "$tmp/companion.mjs" main "$tmp/stdout" "$tmp/stderr" "" 1 || runner_rc=$?
check "timeout exits 124" "$runner_rc" "124"

waited=0
while [ ! -s "$tmp/heartbeat" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -s "$tmp/heartbeat" ]; then
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "timeout stops stubborn descendants with the companion group" "$size_after" "$size_before"
else
    echo "FAIL - stubborn child never wrote its heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r4: a successful leader exit is not group completion. The runner
# must sweep stubborn descendants before returning the leader's rc.
rm -f "$tmp/child.pid" "$tmp/heartbeat"
runner_rc=0
HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    bash "$RUNNER" "$tmp/companion-exits.mjs" main "$tmp/stdout-exit" "$tmp/stderr-exit" || runner_rc=$?
check "leader-exit companion preserves rc 0" "$runner_rc" "0"
if [ -s "$tmp/heartbeat" ]; then
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "leader exit sweeps stubborn group descendants" "$size_after" "$size_before"
else
    echo "FAIL - leader-exit stubborn child never wrote its heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r3: production uses the 5-argument async kickoff, then harvests
# the recorded node group leader later. A taskkill stub makes any Windows-only
# escape visible while the portable group kill must stop the stubborn child.
rm -f "$tmp/child.pid" "$tmp/heartbeat" "$tmp/async.pid" "$tmp/async.rc" "$tmp/taskkill-called"
mkdir -p "$tmp/stub-bin"
cat > "$tmp/stub-bin/taskkill" <<'SH'
#!/usr/bin/env bash
: > "${HIMMEL_R3_TASKKILL_CALLED:?}"
exit 127
SH
chmod +x "$tmp/stub-bin/taskkill"
(
    PATH="$tmp/stub-bin:$PATH" \
    HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
    HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
    HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    HIMMEL_R3_TASKKILL_CALLED="$tmp/taskkill-called" \
        bash "$RUNNER" "$tmp/companion.mjs" main "$tmp/stdout-async" "$tmp/stderr-async" "$tmp/async.pid"
    printf '%s\n' "$?" > "$tmp/async.rc"
) &
async_job=$!

waited=0
while { [ ! -s "$tmp/async.pid" ] || [ ! -s "$tmp/async.pid.identity" ] || [ ! -s "$tmp/heartbeat" ]; } && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -s "$tmp/async.pid" ] && [ -s "$tmp/async.pid.identity" ] && [ -s "$tmp/heartbeat" ]; then
    async_pid=$(cat "$tmp/async.pid")
    async_identity=$(cat "$tmp/async.pid.identity")
    check "5-arg kickoff publishes matching process identity" "$(proc_tree_process_identity_matches "$async_pid" "$async_identity" && echo match || echo mismatch)" "match"
    PATH="$tmp/stub-bin:$PATH" HIMMEL_R3_TASKKILL_CALLED="$tmp/taskkill-called" \
        proc_tree_terminate "$async_pid" 1 "$async_identity" || true
    wait "$async_job" 2>/dev/null || true
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "5-arg harvest stops stubborn descendants with the recorded group" "$size_after" "$size_before"
    check "5-arg harvest does not need taskkill" "$(test -e "$tmp/taskkill-called" && echo called || echo absent)" "absent"
else
    echo "FAIL - 5-arg kickoff did not publish pid and child heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r4: model the recycled-pid harvest case against the same guarded
# primitive wired into pr-check. A mismatched anchor must return before signal.
# HIMMEL-1501: identity_matches confirms this mismatch (rc 1, not the probe
# being merely unavailable), so proc_tree_terminate now returns the distinct
# rc 3 rather than the collapsed rc 2 -- the safety property under test
# (no signal reaches the unrelated live process) is unchanged.
set -m
sleep 30 &
unrelated_pid=$!
set +m
unrelated_identity=$(proc_tree_process_identity "$unrelated_pid") || unrelated_identity=''
guard_rc=0
proc_tree_terminate "$unrelated_pid" 0 "${unrelated_identity}-recycled" || guard_rc=$?
check "identity mismatch refuses to signal recycled pid" "$guard_rc" "3"
check "identity-mismatched unrelated process remains alive" "$(kill -0 "$unrelated_pid" 2>/dev/null && echo alive || echo dead)" "alive"
kill -9 "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=''

# HIMMEL-1474 r6: identity checks distinguish confirmed mismatch/exit from an
# unavailable probe so harvest can wait through transient infrastructure gaps.
identity_match_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    # shellcheck disable=SC2317,SC2329
    ps() { printf '%s\n' 'Mon Aug  3 00:00:00 2026 bash test-runner'; }
    current_identity=$(proc_tree_process_identity "$$") || exit 9
    proc_tree_process_identity_matches "$$" "$current_identity"
) || identity_match_rc=$?
check "identity probe returns 0 for a confirmed match" "$identity_match_rc" "0"

identity_exit_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    proc_tree_process_identity_matches 2147483647 "posix:gone"
) || identity_exit_rc=$?
check "identity probe returns 1 for a confirmed exit" "$identity_exit_rc" "1"

identity_unavailable_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    # shellcheck disable=SC2317,SC2329
    ps() { return 1; }
    proc_tree_process_identity_matches "$$" "posix:unavailable"
) || identity_unavailable_rc=$?
check "identity probe returns 2 when ps fails for a live pid" "$identity_unavailable_rc" "2"

process_alive_rc=0
proc_tree_process_alive "$$" || process_alive_rc=$?
check "identity-free liveness probe confirms current shell" "$process_alive_rc" "0"
process_gone_rc=0
proc_tree_process_alive 2147483647 || process_gone_rc=$?
check "identity-free liveness probe confirms absent pid" "$process_gone_rc" "1"

# HIMMEL-1474 r6b + r8: run the real harvest script's wait loop against the
# deterministic identity stub. An UNAVAILABLE probe must consume the wait
# budget (the loop cannot abandon a render it merely failed to inspect); the
# guarded cleanup that follows must carry the LAUNCH IDENTITY; and terminate
# rc 2 -- no signal sent, so the render may still be live -- must be reported
# as live-but-unreaped with its recovery sidecars preserved.
# CRITIC_TIMEOUT_SECS=1 makes the poll budget 2s, so one stubbed sleep
# exhausts it; the sidecar names are the ones the launcher publishes, which is
# what the retired "kickoff and harvest share the identity sidecar" text grep
# was really asserting.
fixture_reset
printf '%s\n' 424242 > "$adv/h-unreaped.pid"
printf '%s\n' test-identity > "$adv/h-unreaped.pid.identity"
run_harvest h-unreaped \
    H2226_IDENTITY_RC=2 H2226_TERMINATE_RC=2 CRITIC_TIMEOUT_SECS=1 >"$fx/h-unreaped.out" 2>"$fx/h-unreaped.err"
check "identity-unavailable harvest waits through waited=0" "$(wc -l < "$fx/probe.log" | tr -d ' ')" "2"
check "identity-unavailable harvest consumes its wait budget" "$(test -s "$fx/sleep.log" && echo waited || echo skipped)" "waited"
check "production harvest passes launch identity to proc_tree_terminate" "$(cat "$fx/terminate.log")" "424242 1 test-identity"
check "terminate-rc-2 harvest is live-but-unreaped" "$(grep -Fc 'live but unreaped' "$fx/h-unreaped.err")" "1"
check "live-but-unreaped harvest explains preserved handles" "$(grep -Fc 'because no signal was sent' "$fx/h-unreaped.err")" "1"
check "live-but-unreaped harvest records unavailable" "$(grep -Fc 'codex-adv-status: unavailable' "$fx/h-unreaped.err")" "1"
check "live-but-unreaped harvest preserves pid sidecar" "$(test -s "$adv/h-unreaped.pid" && echo preserved || echo missing)" "preserved"
check "live-but-unreaped harvest preserves identity sidecar" "$(test -s "$adv/h-unreaped.pid.identity" && echo preserved || echo missing)" "preserved"

# Only a CONFIRMED mismatch/exit may abandon the wait at waited=0. It must not
# reach the timeout cleanup at all, and with no launcher rc on disk
# (HIMMEL-1474 r12: killed pre-write) the ownership handles stay put.
fixture_reset
printf '%s\n' 424242 > "$adv/h-nolauncherrc.pid"
printf '%s\n' test-identity > "$adv/h-nolauncherrc.pid.identity"
printf '%s\n' 0 > "$adv/h-nolauncherrc.pid.cleanup-rc"
run_harvest h-nolauncherrc \
    H2226_IDENTITY_RC=1 CRITIC_TIMEOUT_SECS=1 >"$fx/h-nolauncherrc.out" 2>"$fx/h-nolauncherrc.err"
check "identity mismatch harvest breaks at waited=0" "$(wc -l < "$fx/probe.log" | tr -d ' ')" "1"
check "identity mismatch harvest skips the timeout cleanup" "$(test -s "$fx/terminate.log" && echo terminated || echo skipped)" "skipped"
check "missing launcher rc marks cleanup unverified" "$(grep -Fc 'launcher status missing' "$fx/h-nolauncherrc.err")" "1"
check "missing launcher rc records unavailable" "$(grep -Fc 'codex-adv-status: unavailable' "$fx/h-nolauncherrc.err")" "1"
check "missing launcher rc preserves pid sidecar" "$(test -s "$adv/h-nolauncherrc.pid" && echo preserved || echo missing)" "preserved"
check "missing launcher rc preserves identity sidecar" "$(test -s "$adv/h-nolauncherrc.pid.identity" && echo preserved || echo missing)" "preserved"
check "missing launcher rc preserves cleanup status" "$(cat "$adv/h-nolauncherrc.pid.cleanup-rc" 2>/dev/null)" "0"

# HIMMEL-1474 r11/r12: the kickoff recovery fence, now run as the real
# scripts/cr/codex-adv-kickoff.sh. Cleanup status is record-scoped, so a clean
# primary can be cleared independently of a failed retry while an unverifiable
# record still blocks overwrite. The launcher-published cleanup status feeding
# these cases is the REAL one from the r12 signal test above.
fixture_reset
cp "$tmp/handshake-signal.pid.cleanup-rc" "$adv/k-orphan.pid.retry.cleanup-rc"
handshake_next_kickoff_rc=0
run_kickoff k-orphan \
    H2226_IDENTITY_RC=9 H2226_TERMINATE_RC=9 >"$fx/k-orphan.out" 2>"$fx/k-orphan.err" || handshake_next_kickoff_rc=$?
check "failed blank-identity recovery does not block the next kickoff" "$handshake_next_kickoff_rc" "0"
check "next kickoff clears orphan cleanup status without a pid marker" "$(test -e "$adv/k-orphan.pid.retry.cleanup-rc" && echo preserved || echo cleared)" "cleared"

fixture_reset
printf '%s\n' 424243 > "$adv/k-mixed.pid"
printf '%s\n' primary-identity > "$adv/k-mixed.pid.identity"
printf '%s\n' 0 > "$adv/k-mixed.pid.cleanup-rc"
printf '%s\n' 424244 > "$adv/k-mixed.pid.retry"
printf '%s\n' retry-identity > "$adv/k-mixed.pid.retry.identity"
printf '%s\n' 1 > "$adv/k-mixed.pid.retry.cleanup-rc"
kickoff_mixed_rc=0
run_kickoff k-mixed \
    H2226_IDENTITY_RC=2 H2226_TERMINATE_RC=9 >"$fx/k-mixed.out" 2>"$fx/k-mixed.err" || kickoff_mixed_rc=$?
check "failed retry blocks kickoff after clean primary is cleared" "$kickoff_mixed_rc" "1"
check "clean primary record is removed independently" "$(test -e "$adv/k-mixed.pid" && echo preserved || echo cleared)" "cleared"
check "clean primary cleanup status is removed independently" "$(test -e "$adv/k-mixed.pid.cleanup-rc" && echo preserved || echo cleared)" "cleared"
check "failed retry pid remains preserved" "$(test -s "$adv/k-mixed.pid.retry" && echo preserved || echo missing)" "preserved"
check "failed retry cleanup status remains preserved" "$(cat "$adv/k-mixed.pid.retry.cleanup-rc" 2>/dev/null)" "1"

fixture_reset
printf '%s\n' 424244 > "$adv/k-recover.pid.retry"
printf '%s\n' retry-identity > "$adv/k-recover.pid.retry.identity"
printf '%s\n' 1 > "$adv/k-recover.pid.retry.cleanup-rc"
kickoff_recover_rc=0
run_kickoff k-recover \
    H2226_IDENTITY_RC=0 H2226_TERMINATE_RC=0 >"$fx/k-recover.out" 2>"$fx/k-recover.err" || kickoff_recover_rc=$?
check "kickoff recovers prior retry ownership state" "$kickoff_recover_rc" "0"
check "kickoff recovery clears retry pid sidecar" "$(test -e "$adv/k-recover.pid.retry" && echo preserved || echo cleared)" "cleared"
check "kickoff recovery clears retry identity sidecar" "$(test -e "$adv/k-recover.pid.retry.identity" && echo preserved || echo cleared)" "cleared"
check "kickoff recovery clears retry cleanup status" "$(test -e "$adv/k-recover.pid.retry.cleanup-rc" && echo preserved || echo cleared)" "cleared"
kickoff_recover_diagnostic=$(grep -Fc "recovered prior retry render" "$fx/k-recover.err" 2>/dev/null)
check "kickoff recovery reports recovered retry" "$kickoff_recover_diagnostic" "1"

fixture_reset
printf '%s\n' 424245 > "$adv/k-block.pid"
printf '%s\n' primary-identity > "$adv/k-block.pid.identity"
printf '%s\n' 2 > "$adv/k-block.pid.cleanup-rc"
kickoff_block_rc=0
run_kickoff k-block \
    H2226_IDENTITY_RC=2 H2226_TERMINATE_RC=9 >"$fx/k-block.out" 2>"$fx/k-block.err" || kickoff_block_rc=$?
check "kickoff blocks unverifiable preserved state" "$kickoff_block_rc" "1"
check "blocked kickoff preserves primary pid sidecar" "$(test -s "$adv/k-block.pid" && echo preserved || echo missing)" "preserved"
check "blocked kickoff preserves primary identity sidecar" "$(test -s "$adv/k-block.pid.identity" && echo preserved || echo missing)" "preserved"
check "blocked kickoff preserves primary cleanup status" "$(cat "$adv/k-block.pid.cleanup-rc" 2>/dev/null)" "2"
kickoff_block_diagnostic=$(grep -Fc "kickoff BLOCKED" "$fx/k-block.err" 2>/dev/null)
check "blocked kickoff emits actionable diagnostic" "$kickoff_block_diagnostic" "1"

# HIMMEL-1474 r14: once a failed cleanup record's leader exits, survivor
# identities are the remaining recovery authority. Exercise both unverified
# cleanup statuses through the launcher and the next kickoff fence.
for survivor_cleanup_rc in 1 2; do
    survivor_prefix="$tmp/survivor-anchor-$survivor_cleanup_rc"
    rm -f "$survivor_prefix.pid" "$survivor_prefix.pid.identity" "$survivor_prefix.pid.cleanup-rc" "$survivor_prefix.pid.survivors"
    runner_rc=0
    HIMMEL_R6_GROUP_TERMINATE_RC="$survivor_cleanup_rc" HIMMEL_R14_GROUP_MEMBERS=5151 \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$survivor_prefix.stdout" "$survivor_prefix.stderr" "$survivor_prefix.pid" 0 "$survivor_prefix.pid.cleanup-rc" 2>"$survivor_prefix-runner.stderr" || runner_rc=$?
    check "cleanup rc $survivor_cleanup_rc after leader exit remains unavailable" "$runner_rc" "125"
    survivor_record=$(awk -F'\t' '{ print $1 ":" $2; exit }' "$survivor_prefix.pid.survivors" 2>/dev/null)
    check "cleanup rc $survivor_cleanup_rc publishes survivor identity sidecar" "$survivor_record" "5151:test-identity"
    # Hand the launcher's OWN ownership record to the real kickoff script: the
    # sidecar names the launcher publishes are the ones the kickoff consumes,
    # which is the cross-script agreement the retired text greps counted.
    fixture_reset
    survivor_branch="k-survivor-$survivor_cleanup_rc"
    cp "$survivor_prefix.pid" "$adv/$survivor_branch.pid"
    cp "$survivor_prefix.pid.identity" "$adv/$survivor_branch.pid.identity"
    cp "$survivor_prefix.pid.cleanup-rc" "$adv/$survivor_branch.pid.cleanup-rc"
    cp "$survivor_prefix.pid.survivors" "$adv/$survivor_branch.pid.survivors"
    survivor_recover_rc=0
    run_kickoff "$survivor_branch" \
        H2226_IDENTITY_RC=1 H2226_ALIVE_RC=1 H2226_TERMINATE_RC=9 H2226_KILLABLE=5151 >"$survivor_prefix-recover.stdout" 2>"$survivor_prefix-recover.stderr" || survivor_recover_rc=$?
    check "cleanup rc $survivor_cleanup_rc next kickoff recovers through survivor anchor" "$survivor_recover_rc" "0"
    check "cleanup rc $survivor_cleanup_rc recovery signals verified survivor" "$(grep -Fc -- '-TERM:5151' "$fx/signals.log" 2>/dev/null)" "1"
    check "cleanup rc $survivor_cleanup_rc recovery clears survivor sidecar" "$(test -e "$adv/$survivor_branch.pid.survivors" && echo preserved || echo cleared)" "cleared"
done

# An unavailable process-table snapshot must not publish an empty sidecar that
# a later kickoff could mistake for definitive group absence.
rm -f "$tmp/survivor-snapshot-failed.pid" "$tmp/survivor-snapshot-failed.pid.identity" "$tmp/survivor-snapshot-failed.pid.cleanup-rc" "$tmp/survivor-snapshot-failed.pid.survivors"
runner_rc=0
HIMMEL_R6_GROUP_TERMINATE_RC=1 HIMMEL_R14_GROUP_MEMBERS_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/survivor-snapshot-failed.stdout" "$tmp/survivor-snapshot-failed.stderr" "$tmp/survivor-snapshot-failed.pid" 0 "$tmp/survivor-snapshot-failed.pid.cleanup-rc" 2>"$tmp/survivor-snapshot-failed-runner.stderr" || runner_rc=$?
check "unavailable survivor snapshot keeps cleanup unavailable" "$runner_rc" "125"
check "unavailable survivor snapshot publishes no false-empty sidecar" "$(test -e "$tmp/survivor-snapshot-failed.pid.survivors" && echo published || echo absent)" "absent"
check "unavailable survivor snapshot emits diagnostic" "$(grep -Fc 'survivor snapshot unavailable' "$tmp/survivor-snapshot-failed-runner.stderr" 2>/dev/null)" "1"

# A complete r14 snapshot may name survivors that exited before the next
# kickoff. Confirmed absence is definitive and clears the preserved record.
fixture_reset
printf '%s\n' 424250 > "$adv/k-survivors-gone.pid"
printf '%s\n' leader-identity > "$adv/k-survivors-gone.pid.identity"
printf '%s\n' 1 > "$adv/k-survivors-gone.pid.cleanup-rc"
printf '5152\ttest-identity\n' > "$adv/k-survivors-gone.pid.survivors"
survivors_gone_rc=0
run_kickoff k-survivors-gone \
    H2226_IDENTITY_RC=1 H2226_ALIVE_RC=1 H2226_TERMINATE_RC=9 >"$fx/k-survivors-gone.out" 2>"$fx/k-survivors-gone.err" || survivors_gone_rc=$?
check "exited leader with all survivor anchors gone proceeds" "$survivors_gone_rc" "0"
check "all-gone survivor recovery clears ownership record" "$(test -e "$adv/k-survivors-gone.pid" && echo preserved || echo cleared)" "cleared"
check "all-gone survivor recovery signals nothing" "$(test -s "$fx/signals.log" && echo signaled || echo silent)" "silent"

# HIMMEL-1501: a preserved cleanup rc of 3 (confirmed-gone before any signal
# was sent) must be recovered the same way as 1/2 -- the survivors sidecar
# stays the authority regardless of which rc the prior run left behind.
fixture_reset
printf '%s\n' 424254 > "$adv/k-rc3-record.pid"
printf '%s\n' leader-identity > "$adv/k-rc3-record.pid.identity"
printf '%s\n' 3 > "$adv/k-rc3-record.pid.cleanup-rc"
printf '5154\ttest-identity\n' > "$adv/k-rc3-record.pid.survivors"
confirmed_gone_record_rc=0
run_kickoff k-rc3-record \
    H2226_IDENTITY_RC=1 H2226_ALIVE_RC=1 H2226_TERMINATE_RC=9 >"$fx/k-rc3-record.out" 2>"$fx/k-rc3-record.err" || confirmed_gone_record_rc=$?
check "state cleanup rc=3 with all survivor anchors gone proceeds" "$confirmed_gone_record_rc" "0"
check "rc=3 survivor recovery clears ownership record" "$(test -e "$adv/k-rc3-record.pid" && echo preserved || echo cleared)" "cleared"

# The leader can match at the first probe and then exit before the guarded
# terminate call. Confirmed-gone rc 3 must join the same survivor recovery path
# rather than blocking the next kickoff.
fixture_reset
printf '%s\n' 424255 > "$adv/k-terminate-rc3.pid"
printf '%s\n' leader-identity > "$adv/k-terminate-rc3.pid.identity"
printf '%s\n' 1 > "$adv/k-terminate-rc3.pid.cleanup-rc"
printf '5156\ttest-identity\n' > "$adv/k-terminate-rc3.pid.survivors"
terminate_confirmed_gone_rc=0
run_kickoff k-terminate-rc3 \
    H2226_IDENTITY_RC=1 H2226_IDENTITY_RULES=424255:0 H2226_ALIVE_RC=1 \
    H2226_TERMINATE_RC=3 H2226_KILLABLE=5156 \
    >"$fx/k-terminate-rc3.out" 2>"$fx/k-terminate-rc3.err" || terminate_confirmed_gone_rc=$?
check "identity match followed by terminate rc 3 recovers through survivor anchor" "$terminate_confirmed_gone_rc" "0"
check "terminate rc 3 recovery attempted guarded leader cleanup" "$(grep -Fc '424255 1 leader-identity' "$fx/terminate.log")" "1"
check "terminate rc 3 recovery signals verified survivor" "$(grep -Fc -- '-TERM:5156' "$fx/signals.log" 2>/dev/null)" "1"
check "terminate rc 3 recovery clears ownership record" "$(test -e "$adv/k-terminate-rc3.pid" && echo preserved || echo cleared)" "cleared"

# A live pid with a different identity is not the recorded survivor and cannot
# be signaled or silently treated as absence.
fixture_reset
printf '%s\n' 424251 > "$adv/k-survivor-mismatch.pid"
printf '%s\n' leader-identity > "$adv/k-survivor-mismatch.pid.identity"
printf '%s\n' 2 > "$adv/k-survivor-mismatch.pid.cleanup-rc"
printf '5153\ttest-identity\n' > "$adv/k-survivor-mismatch.pid.survivors"
survivor_mismatch_rc=0
run_kickoff k-survivor-mismatch \
    H2226_IDENTITY_RC=1 H2226_ALIVE_RC=1 H2226_ALIVE_RULES=5153:0 \
    H2226_IDENTITY_VALUES=5153:recycled-identity H2226_TERMINATE_RC=9 \
    >"$fx/k-survivor-mismatch.out" 2>"$fx/k-survivor-mismatch.err" || survivor_mismatch_rc=$?
check "identity-mismatched survivor blocks kickoff" "$survivor_mismatch_rc" "1"
check "identity-mismatched survivor record stays preserved" "$(test -s "$adv/k-survivor-mismatch.pid.survivors" && echo preserved || echo missing)" "preserved"
check "identity-mismatched survivor diagnostic names mismatch" "$(grep -Fc 'identity mismatch' "$fx/k-survivor-mismatch.err" 2>/dev/null)" "1"
check "identity-mismatched survivor is never signaled" "$(test -s "$fx/signals.log" && echo signaled || echo silent)" "silent"

# Pre-r14 failed records have no survivor anchors. Preserve the old fail-closed
# manual path instead of guessing that a dead leader means an empty group.
fixture_reset
printf '%s\n' 424252 > "$adv/k-legacy.pid"
printf '%s\n' leader-identity > "$adv/k-legacy.pid.identity"
printf '%s\n' 1 > "$adv/k-legacy.pid.cleanup-rc"
rm -f "$adv/k-legacy.pid.survivors"
legacy_record_rc=0
run_kickoff k-legacy \
    H2226_IDENTITY_RC=1 H2226_ALIVE_RC=1 H2226_TERMINATE_RC=9 >"$fx/k-legacy.out" 2>"$fx/k-legacy.err" || legacy_record_rc=$?
check "legacy failed record without survivor sidecar stays blocked" "$legacy_record_rc" "1"
check "legacy failed record stays preserved" "$(test -s "$adv/k-legacy.pid" && echo preserved || echo missing)" "preserved"
check "legacy record diagnostic names manual recovery path" "$(grep -Fc 'legacy pre-r14 record); manual recovery required' "$fx/k-legacy.err" 2>/dev/null)" "1"

# HIMMEL-1474 r8: terminate rc 2 (no signal sent) is asserted above, on the
# same real-script run as the wait-budget case it shares a launch shape with.
#
# HIMMEL-1474 r9: terminate rc 1 means escalated cleanup left survivors. The
# gate remains a timeout while its recovery handles stay available.
fixture_reset
printf '%s\n' 424243 > "$adv/h-survivors.pid"
printf '%s\n' test-identity > "$adv/h-survivors.pid.identity"
run_harvest h-survivors \
    H2226_IDENTITY_RC=2 H2226_TERMINATE_RC=1 CRITIC_TIMEOUT_SECS=1 >"$fx/h-survivors.out" 2>"$fx/h-survivors.err"
check "terminate-rc-1 harvest remains a timeout" "$(grep -Fc 'codex adversarial pass timed out with survivors' "$fx/h-survivors.err")" "1"
check "terminate-rc-1 harvest records unavailable" "$(grep -Fc 'codex-adv-status: unavailable' "$fx/h-survivors.err")" "1"
check "terminate-rc-1 harvest is not live-but-unreaped" "$(grep -Fc 'live but unreaped' "$fx/h-survivors.err")" "0"
check "terminate-rc-1 harvest preserves pid sidecar" "$(test -s "$adv/h-survivors.pid" && echo preserved || echo missing)" "preserved"
check "terminate-rc-1 harvest preserves identity sidecar" "$(test -s "$adv/h-survivors.pid.identity" && echo preserved || echo missing)" "preserved"
harvest_survivors_diagnostic=$(grep -Fc "survivors after escalated cleanup" "$fx/h-survivors.err" 2>/dev/null)
check "terminate-rc-1 harvest reports preserved recovery sidecars" "$harvest_survivors_diagnostic" "1"

# HIMMEL-1501: terminate rc 3 means the leader was CONFIRMED already
# exited/recycled before any signal was sent. Unlike rc 2, this must NOT be
# classified as live-but-unreaped -- it falls through to the ordinary
# "exited" harvest path below, and once the launcher's own rc/cleanup status
# lands (simulated here via the rc_wait poll, same as the real "a beat
# later" race the production code documents), sidecars are removed rather
# than preserved.
fixture_reset
printf '%s\n' 424244 > "$adv/h-terminate-rc3.pid"
printf '%s\n' test-identity > "$adv/h-terminate-rc3.pid.identity"
# The launcher publishes its rc/cleanup status a BEAT LATER, after the
# harvest's cleanup attempt; the stub sleep runs this hook only once the
# terminate stub has fired, which is exactly that window.
cat > "$fx/h-terminate-rc3.hook" <<HOOK
printf '%s\n' 1 > "$adv/h-terminate-rc3.rc"
printf '5155\ttest-identity\n' > "$adv/h-terminate-rc3.pid.survivors"
printf '%s\n' 3 > "$adv/h-terminate-rc3.pid.cleanup-rc"
HOOK
run_harvest h-terminate-rc3 \
    H2226_IDENTITY_RC=2 H2226_TERMINATE_RC=3 H2226_KILLABLE=5155 \
    H2226_ALIVE_RC=1 H2226_SLEEP_HOOK="$fx/h-terminate-rc3.hook" \
    CRITIC_TIMEOUT_SECS=1 \
    >"$fx/h-terminate-rc3.out" 2>"$fx/h-terminate-rc3.err"
check "terminate-rc-3 harvest is NOT live-but-unreaped" "$(grep -Fc 'live but unreaped' "$fx/h-terminate-rc3.err")" "0"
check "terminate-rc-3 harvest never reports a timeout" "$(grep -Fc 'codex adversarial pass timed out' "$fx/h-terminate-rc3.err")" "0"
check "confirmed-gone harvest resolves survivor anchor" "$(grep -Fc -- '-TERM:5155' "$fx/signals.log" 2>/dev/null)" "1"
check "confirmed-gone harvest removes pid sidecar" "$(test -e "$adv/h-terminate-rc3.pid" && echo preserved || echo cleared)" "cleared"
check "confirmed-gone harvest removes identity sidecar" "$(test -e "$adv/h-terminate-rc3.pid.identity" && echo preserved || echo cleared)" "cleared"
check "confirmed-gone harvest removes survivor sidecar" "$(test -e "$adv/h-terminate-rc3.pid.survivors" && echo preserved || echo cleared)" "cleared"

# HIMMEL-1474 r12: cleanup is removable only after BOTH launcher status and a
# zero cleanup status exist. The killed-pre-write launcher half is asserted
# above (h-nolauncherrc); this is the late cleanup publication -- a recorded
# launcher rc with its cleanup status still missing keeps both handles. The
# recorded rc also proves the rc-first ordering: with a launcher status on
# disk the harvest never probes launch identity at all.
fixture_reset
printf '%s\n' 424247 > "$adv/h-late-cleanup.pid"
printf '%s\n' test-identity > "$adv/h-late-cleanup.pid.identity"
printf '%s\n' 7 > "$adv/h-late-cleanup.rc"
run_harvest h-late-cleanup \
    H2226_IDENTITY_RC=2 CRITIC_TIMEOUT_SECS=1 >"$fx/h-late-cleanup.out" 2>"$fx/h-late-cleanup.err"
check "production harvest checks rc before identity probing" "$(wc -l < "$fx/probe.log" | tr -d ' ')" "0"
check "late cleanup status reports the launcher rc" "$(grep -Fc 'codex adversarial pass failed (rc=7' "$fx/h-late-cleanup.err")" "1"
check "late cleanup status records unavailable" "$(grep -Fc 'codex-adv-status: unavailable' "$fx/h-late-cleanup.err")" "1"
check "late cleanup status preserves pid sidecar" "$(test -s "$adv/h-late-cleanup.pid" && echo preserved || echo missing)" "preserved"
check "late cleanup status preserves identity sidecar" "$(test -s "$adv/h-late-cleanup.pid.identity" && echo preserved || echo missing)" "preserved"
late_cleanup_diagnostic=$(grep -Fc "cleanup unverified (rc=missing)" "$fx/h-late-cleanup.err" 2>/dev/null)
check "late cleanup status reports missing cleanup rc" "$late_cleanup_diagnostic" "1"

# HIMMEL-1474 r10/r12: the synchronous retry owns distinct recovery sidecars. Its
# timeout status remains 124 while cleanup rc 1/2 and both handles survive.
# The retry RECORD path is the one cross-script name neither side can prove
# behaviourally here (kickoff's retry recovery is asserted above against
# ${pid}.retry.*, but harvest only writes that record on a real relaunch),
# so it stays a source-level assertion -- against the two scripts now, not the
# runbook. The primary/retry cleanup-status and identity/survivor sidecar
# greps are RETIRED: in the extracted kickoff they are one recover_codex_state
# function parameterized by the record prefix, and every one of those names is
# now exercised end to end above (the launcher publishes them, the kickoff and
# harvest consume them), so counting the text would only pass vacuously.
# shellcheck disable=SC2016
retry_pid_wiring=$(cat "$KICKOFF" "$HARVEST" | grep -Fc 'codex_retry_pid_file="${codex_pid_file}.retry"')
check "kickoff and harvest share the dedicated retry pid sidecar" "$retry_pid_wiring" "2"
# shellcheck disable=SC2016
retry_survivors_wiring=$(grep -Fc 'codex_retry_survivors_file="${codex_retry_pid_file}.survivors"' "$HARVEST" 2>/dev/null)
check "harvest gives its retry a dedicated survivor sidecar" "$retry_survivors_wiring" "1"
# shellcheck disable=SC2016
retry_launcher_wiring=$(grep -Fc '"$codex_retry_pid_file" "$codex_timeout" "$codex_retry_cleanup_rc_file"' "$HARVEST" 2>/dev/null)
check "production retry passes its pid and cleanup sidecars to the launcher" "$retry_launcher_wiring" "1"
for retry_cleanup_rc in 1 2; do
    rm -f "$tmp/retry-$retry_cleanup_rc.pid" "$tmp/retry-$retry_cleanup_rc.pid.identity" "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc"
    runner_rc=0
    HIMMEL_R6_TERMINATE_RC="$retry_cleanup_rc" \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/retry-$retry_cleanup_rc.stdout" "$tmp/retry-$retry_cleanup_rc.stderr" "$tmp/retry-$retry_cleanup_rc.pid" 1 "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc" 2>"$tmp/retry-$retry_cleanup_rc-runner.stderr" || runner_rc=$?
    check "retry-shaped cleanup rc $retry_cleanup_rc keeps exit 124" "$runner_rc" "124"
    check "retry-shaped cleanup rc $retry_cleanup_rc publishes record cleanup status" "$(cat "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc" 2>/dev/null)" "$retry_cleanup_rc"
    check "retry-shaped cleanup rc $retry_cleanup_rc preserves pid sidecar" "$(test -s "$tmp/retry-$retry_cleanup_rc.pid" && echo preserved || echo missing)" "preserved"
    check "retry-shaped cleanup rc $retry_cleanup_rc preserves identity sidecar" "$(test -s "$tmp/retry-$retry_cleanup_rc.pid.identity" && echo preserved || echo missing)" "preserved"
    retry_pid=$(cat "$tmp/retry-$retry_cleanup_rc.pid")
    kill -9 "$retry_pid" 2>/dev/null || true
    if command -v taskkill >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 taskkill /PID "$retry_pid" /T /F >/dev/null 2>&1 || true
    fi
done

# Companion failure keeps its own rc, while the independent cleanup status lets
# harvest preserve recovery handles for cleanup rc 1/2 instead of deleting them.
for companion_cleanup_rc in 1 2; do
    companion_prefix="$tmp/companion-cleanup-$companion_cleanup_rc"
    rm -f "$companion_prefix.pid" "$companion_prefix.pid.identity" "$companion_prefix.rc" "$companion_prefix.pid.cleanup-rc"
    runner_rc=0
    HIMMEL_R6_GROUP_TERMINATE_RC="$companion_cleanup_rc" \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-fails.mjs" main "$companion_prefix.stdout" "$companion_prefix.stderr" "$companion_prefix.pid" 0 "$companion_prefix.pid.cleanup-rc" 2>"$companion_prefix-runner.stderr" || runner_rc=$?
    check "companion rc wins over cleanup rc $companion_cleanup_rc" "$runner_rc" "7"
    check "companion failure publishes cleanup rc $companion_cleanup_rc" "$(cat "$companion_prefix.pid.cleanup-rc" 2>/dev/null)" "$companion_cleanup_rc"
    # Hand the launcher's real record (companion rc 7 plus an unverified
    # cleanup status) to the real harvest script.
    fixture_reset
    companion_branch="h-companion-$companion_cleanup_rc"
    printf '%s\n' "$runner_rc" > "$adv/$companion_branch.rc"
    cp "$companion_prefix.pid" "$adv/$companion_branch.pid"
    cp "$companion_prefix.pid.identity" "$adv/$companion_branch.pid.identity"
    cp "$companion_prefix.pid.cleanup-rc" "$adv/$companion_branch.pid.cleanup-rc"
    run_harvest "$companion_branch" \
        H2226_IDENTITY_RC=2 CRITIC_TIMEOUT_SECS=1 >"$companion_prefix-harvest.stdout" 2>"$companion_prefix-harvest.stderr"
    check "harvest sees companion rc 7 with cleanup rc $companion_cleanup_rc" "$(grep -Fc "codex adversarial pass failed (rc=7" "$companion_prefix-harvest.stderr")" "1"
    check "harvest marks companion cleanup rc $companion_cleanup_rc unverified" "$(grep -Fc "cleanup unverified (rc=$companion_cleanup_rc)" "$companion_prefix-harvest.stderr")" "1"
    check "harvest records unavailable for companion cleanup rc $companion_cleanup_rc" "$(grep -Fc 'codex-adv-status: unavailable' "$companion_prefix-harvest.stderr")" "1"
    check "companion cleanup rc $companion_cleanup_rc preserves pid sidecar" "$(test -s "$adv/$companion_branch.pid" && echo preserved || echo missing)" "preserved"
    check "companion cleanup rc $companion_cleanup_rc preserves identity sidecar" "$(test -s "$adv/$companion_branch.pid.identity" && echo preserved || echo missing)" "preserved"
    check "companion cleanup rc $companion_cleanup_rc preserves cleanup status" "$(cat "$adv/$companion_branch.pid.cleanup-rc" 2>/dev/null)" "$companion_cleanup_rc"
done

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
