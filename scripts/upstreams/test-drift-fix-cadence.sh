#!/usr/bin/env bash
# scripts/upstreams/test-drift-fix-cadence.sh — hermetic suite for the nightly
# upstream-drift repair cadence (HIMMEL-1323): two legs, HIMMEL-DriftFix
# (/drift-fix) and HIMMEL-ForkResync (/fork-resync).
#
# Never touches the real scheduler: schtasks/crontab are replaced by fakes via
# DRIFTFIX_SCHTASKS / DRIFTFIX_CRONTAB, the runner dir by DRIFTFIX_BAT_DIR, and
# the himmel root by DRIFTFIX_HIMMEL_ROOT pointing at a stub tree. The stub tree
# deliberately omits scripts/lib/ensure-workspace-trust.sh so the arm path's
# workspace pre-seed short-circuits instead of writing to the real ~/.claude.json.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CADENCE="$SCRIPT_DIR/drift-fix-cadence.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

assert_rc() {
  local want="$1" label="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label (rc=$rc)"
  else fail "$label — expected rc=$want got rc=$rc; output: $out"; fi
}

assert_has() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in output" ;;
  esac
}

assert_lacks() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) fail "$label — '$needle' unexpectedly present" ;;
    *) pass "$label" ;;
  esac
}

# A stub himmel root carrying exactly the six payload files require_payload
# checks for — and nothing else (see header: no ensure-workspace-trust.sh).
make_root() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/scripts/upstreams" "$root/.claude/commands"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/check-plugin-drift.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/upstreams/apply-drift-bump.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/upstreams/apply-tool-upgrade.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/upstreams/resync-fork.sh"
  printf 'stub runbook\n' > "$root/.claude/commands/drift-fix.md"
  printf 'stub runbook\n' > "$root/.claude/commands/fork-resync.md"
  printf '%s' "$root"
}

# Fake schtasks. Per-task-name aware (armed_<name> sentinel files instead of a
# single global one) so the two legs can be independently armed/not-armed —
# required to exercise "only one leg armed" dedup and rollback scenarios.
# Behaviour driven by files in $FAKE_STATE:
#   armed_<name>       -> /query /tn <name> succeeds and reports a Next Run Time
#   no_next_run_<name> -> /query /tn <name> succeeds but omits Next Run Time
#                         (simulates a post-arm verify failure)
#   query_fail         -> /query exits 1 with UNRECOGNIZED stderr (fail-closed probe)
# Records each invocation to $FAKE_STATE/calls.
make_fake_schtasks() {
  local state="$1" f="$1/schtasks"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
state="$(dirname "$0")"
echo "$*" >> "$state/calls"
tn=""
prev=""
for a in "$@"; do
  if [ "$prev" = "/tn" ]; then tn="$a"; fi
  prev="$a"
done
armed_file="$state/armed_${tn:-_none_}"
case "$1" in
  /query)
    if [ -f "$state/query_fail" ]; then
      echo "some unrecognized localized failure" >&2; exit 1
    fi
    if [ -f "$armed_file" ]; then
      echo "TaskName: \\$tn"
      if [ ! -f "$state/no_next_run_$tn" ]; then
        echo "Next Run Time: 1/1/2027 5:00:00 AM"
      fi
      echo "Status: Ready"
      exit 0
    fi
    echo "ERROR: The system cannot find the file specified." >&2; exit 1 ;;
  /create) touch "$armed_file"; echo "SUCCESS: created"; exit 0 ;;
  /delete) rm -f "$armed_file"; echo "SUCCESS: deleted"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

# Fake crontab backed by $FAKE_STATE/tab. `-l` prints it (rc 1 + "no crontab"
# when absent, the trusted-empty signature); `-` installs from stdin.
# $FAKE_STATE/install_fail fails ONLY the `-` (install) path, leaving `-l`
# (read) working — unlike cron_fail (below) which fails both, this isolates a
# failed INSTALL from a failed READ so cron_arm's write-before-install
# ordering fix can be exercised without also tripping the fail-closed
# cron_read guard.
make_fake_crontab() {
  local state="$1" f="$1/crontab"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
state="$(dirname "$0")"
if [ -f "$state/cron_fail" ]; then
  echo "crontab: totally unexpected failure" >&2; exit 7
fi
case "${1:-}" in
  -l)
    if [ -f "$state/tab" ]; then cat "$state/tab"; exit 0; fi
    echo "no crontab for tester" >&2; exit 1 ;;
  -)
    if [ -f "$state/install_fail" ]; then
      echo "crontab: simulated install failure" >&2; exit 9
    fi
    cat > "$state/tab"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

# A real executable standing in for the claude binary. resolve_claude now
# existence-checks the DRIFTFIX_CLAUDE override, so a bare /usr/bin/claude
# (absent on Windows Git-Bash) would trip that guard instead of the case under
# test. The optional 2nd arg is a filename suffix: the Windows arm path requires
# a cmd-launchable extension, so the Windows block passes ".exe" (a real armbale
# target) while the POSIX block — which has no extension check — keeps the bare
# extensionless stub.
make_stub_claude() {
  local f="$1/claude${2:-}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

echo "[test-drift-fix-cadence] usage + arg validation"
assert_rc 1 "no subcommand is rc=1" bash "$CADENCE"
assert_rc 1 "unknown subcommand is rc=1" bash "$CADENCE" bogus
assert_rc 0 "--help is rc=0" bash "$CADENCE" --help
assert_rc 1 "bad --time rejected" bash "$CADENCE" arm --time 25:00
assert_rc 1 "non-numeric --time rejected" bash "$CADENCE" arm --time noon
assert_rc 1 "--time with no value rejected" bash "$CADENCE" arm --time
assert_rc 1 "bad --resync-time rejected" bash "$CADENCE" arm --resync-time 25:99
assert_rc 1 "--resync-time with no value rejected" bash "$CADENCE" arm --resync-time
assert_rc 1 "--model with no value rejected" bash "$CADENCE" arm --model
assert_rc 1 "--model with shell metacharacters rejected" bash "$CADENCE" arm --model 'sonnet; rm -rf /'
assert_rc 1 "--time is arm-only" bash "$CADENCE" status --time 05:00
assert_rc 1 "--resync-time is arm-only" bash "$CADENCE" status --resync-time 05:30
assert_rc 1 "--model is arm-only" bash "$CADENCE" disarm --model sonnet
assert_rc 1 "unknown flag rejected" bash "$CADENCE" arm --nope
# Input errors must be rc 1 on EVERY platform, never rc 2 from a platform gate.
assert_rc 1 "bad --time is rc=1 even on an unsupported platform" \
  env DRIFTFIX_PLATFORM=plan9 bash "$CADENCE" arm --time 99:99
assert_rc 2 "unsupported platform is rc=2" \
  env DRIFTFIX_PLATFORM=plan9 bash "$CADENCE" arm

echo "[test-drift-fix-cadence] missing payload is rc=2, never a silent arm"
state=$(mktemp -d); fake_cron=$(make_fake_crontab "$state"); fake_claude=$(make_stub_claude "$state")
assert_rc 2 "absent payload blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$state" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
# Each payload EITHER leg depends on is checked individually — a cadence armed
# against a half-present payload set fails at fire time, not at arm time.
root=$(make_root)
rm -f "$root/scripts/upstreams/apply-tool-upgrade.sh"
assert_rc 2 "absent vendor-CLI upgrader blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
rm -rf "$root"
root=$(make_root)
rm -f "$root/scripts/upstreams/apply-drift-bump.sh"
assert_rc 2 "absent pin bumper blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
rm -rf "$root"
root=$(make_root)
rm -f "$root/.claude/commands/fork-resync.md"
assert_rc 2 "absent /fork-resync runbook blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
rm -rf "$root"
root=$(make_root)
rm -f "$root/scripts/upstreams/resync-fork.sh"
assert_rc 2 "absent fork resync script blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
rm -rf "$root" "$state"

echo "[test-drift-fix-cadence] claude must resolve at arm time"
root=$(make_root); state=$(mktemp -d); fake_cron=$(make_fake_crontab "$state"); fake_claude=$(make_stub_claude "$state")
# Exercised through the OVERRIDE, not by stripping PATH. Emptying PATH is not a
# viable way to hide `claude` here: `env PATH=... bash` then cannot find bash
# itself, and a hand-built minimal PATH cannot carry MSYS coreutils (they need
# their DLL neighborhood), so the script dies resolving SCRIPT_DIR long before
# the branch under test. A non-executable DRIFTFIX_CLAUDE hits the same guard
# and is the failure an operator actually produces.
assert_rc 2 "a DRIFTFIX_CLAUDE pointing at nothing blocks arming" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$state/no-such-claude" bash "$CADENCE" arm
rm -rf "$root" "$state"

# --------------------------------------------------------------------------
echo "[test-drift-fix-cadence] POSIX (crontab) arm — both legs"
root=$(make_root); state=$(mktemp -d); fake_cron=$(make_fake_crontab "$state"); fake_claude=$(make_stub_claude "$state")
cron_env() {
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" "$@"
}

out=$(cron_env bash "$CADENCE" arm --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix dry-run arm exits 0"; else fail "posix dry-run arm rc=$rc: $out"; fi
assert_has "$out" "00 05 * * *" "dry-run shows the default 05:00 drift schedule"
assert_has "$out" "30 05 * * *" "dry-run shows the default 05:30 resync schedule"
assert_has "$out" "# HIMMEL-DriftFix" "drift cron entry is marker-tagged"
assert_has "$out" "# HIMMEL-ForkResync" "resync cron entry is marker-tagged"
assert_has "$out" "/drift-fix" "drift runner fires the /drift-fix runbook"
assert_has "$out" "/fork-resync" "resync runner fires the /fork-resync runbook"
assert_has "$out" "scripts/upstreams.json" "resync prompt selects registered fork entries, not qmd only"
assert_has "$out" "claude-obsidian" "resync prompt names claude-obsidian coverage"
assert_has "$out" "non-additive" "resync prompt treats claude-obsidian non-additive audit as designed"
assert_has "$out" "--push" "unattended resync prompt explicitly forbids the push path"
assert_has "$out" "< /dev/null" "runner gives the session stdin EOF"
assert_lacks "$out" "--print" "runner never uses --print (HIMMEL-128 billing)"
assert_lacks "$out" " -p " "runner never uses -p (HIMMEL-128 billing)"
assert_has "$out" "--model sonnet" "runner pins the model explicitly"
assert_has "$out" "himmel-cadence-runner-format:" "runner carries the format stamp"
if [ ! -f "$state/tab" ]; then pass "dry-run installed no crontab"; else fail "dry-run wrote a crontab"; fi
if [ ! -f "$state/bat/drift-fix.sh" ] && [ ! -f "$state/bat/fork-resync.sh" ]; then
  pass "dry-run wrote no runners"
else
  fail "dry-run wrote a runner"
fi

out=$(cron_env bash "$CADENCE" arm --time 06:30 --resync-time 07:15 --model haiku 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix arm exits 0"; else fail "posix arm rc=$rc: $out"; fi
assert_has "$out" "drift-fix-cadence ARMED" "arm prints the summary banner"
if [ -f "$state/tab" ]; then
  tab=$(cat "$state/tab")
  assert_has "$tab" "30 06 * * *" "--time landed in the drift leg's cron schedule"
  assert_has "$tab" "15 07 * * *" "--resync-time landed in the resync leg's cron schedule"
  assert_lacks "$tab" "30 07 * * *" "--resync-time did not change the drift leg's schedule"
  assert_has "$tab" "# HIMMEL-DriftFix" "drift entry is marker-tagged"
  assert_has "$tab" "# HIMMEL-ForkResync" "resync entry is marker-tagged"
  pass "crontab installed with both entries"
else
  fail "crontab was not installed"
fi
if [ -f "$state/bat/drift-fix.sh" ]; then
  runner=$(cat "$state/bat/drift-fix.sh")
  assert_has "$runner" "--model haiku" "--model landed in the drift runner"
  assert_has "$runner" "cd " "drift runner cds before running claude"
  assert_has "$runner" "$root" "drift runner cds into the resolved himmel root"
  assert_has "$runner" "/drift-fix" "drift runner carries the /drift-fix prompt"
  # shellcheck disable=SC2016  # literal '$log' is the assertion — the runner expands it at fire time, not here
  assert_has "$runner" '$log.prev' "drift runner rotates its log"
  assert_has "$runner" "[exit rc=" "drift runner stamps its exit rc for status"
  if [ -x "$state/bat/drift-fix.sh" ]; then pass "drift runner is executable"; else fail "drift runner is not executable"; fi
else
  fail "drift-fix.sh runner was not written"
fi
if [ -f "$state/bat/fork-resync.sh" ]; then
  runner=$(cat "$state/bat/fork-resync.sh")
  assert_has "$runner" "--model haiku" "--model landed in the resync runner"
  assert_has "$runner" "/fork-resync" "resync runner fires /fork-resync, not /drift-fix"
  assert_lacks "$runner" "/drift-fix" "resync runner does not carry the drift prompt"
  assert_has "$runner" "fork-resync.log" "resync runner carries its own log path"
  if [ -x "$state/bat/fork-resync.sh" ]; then pass "resync runner is executable"; else fail "resync runner is not executable"; fi
else
  fail "fork-resync.sh runner was not written"
fi

echo "[test-drift-fix-cadence] POSIX dedup: rc=3 when only ONE leg is armed"
# Simulate an externally-disarmed resync leg: strip its crontab entry so only
# the drift leg looks armed, then confirm arm still refuses and names only
# the leg it found (never the leg that is actually free).
cp "$state/tab" "$state/tab.full"
grep -v '# HIMMEL-ForkResync' "$state/tab.full" > "$state/tab"
out=$(cron_env bash "$CADENCE" arm 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "dedup refuses when only the drift leg is armed (rc=3)"; else fail "expected rc=3, got rc=$rc: $out"; fi
assert_has "$out" "already armed: HIMMEL-DriftFix." "dedup message names the armed leg"
assert_lacks "$out" "HIMMEL-ForkResync" "dedup message does not mention the unarmed leg"
mv "$state/tab.full" "$state/tab"

echo "[test-drift-fix-cadence] POSIX dedup + force (both legs armed)"
assert_rc 3 "second arm is refused (dedup, both legs armed)" cron_env bash "$CADENCE" arm
out=$(cron_env bash "$CADENCE" arm --force --time 08:00 --resync-time 08:30 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "--force replaces"; else fail "--force rc=$rc: $out"; fi
tab=$(cat "$state/tab")
assert_has "$tab" "00 08 * * *" "--force re-armed the drift leg at the new time"
assert_has "$tab" "30 08 * * *" "--force re-armed the resync leg at the new time"
drift_entries=$(printf '%s\n' "$tab" | grep -cF "# HIMMEL-DriftFix")
resync_entries=$(printf '%s\n' "$tab" | grep -cF "# HIMMEL-ForkResync")
if [ "$drift_entries" -eq 1 ]; then pass "--force left exactly one drift entry (no duplicate)"; else fail "--force left $drift_entries drift entries"; fi
if [ "$resync_entries" -eq 1 ]; then pass "--force left exactly one resync entry (no duplicate)"; else fail "--force left $resync_entries resync entries"; fi

echo "[test-drift-fix-cadence] POSIX --force re-arm with a failing install keeps old runners + entries"
# Both legs are already armed (08:00/08:30, from the --force case above).
# Snapshot the live state, then re-arm with --force AND a crontab install
# that fails (install_fail — read still succeeds, only `crontab -` fails).
# emit_runner writes the new runner bodies INSIDE the loop, before
# cron_install is even attempted — a failed install must not leave those
# bodies mutated to the new, never-installed config (CR codex-1).
before_drift=$(cat "$state/bat/drift-fix.sh")
before_resync=$(cat "$state/bat/fork-resync.sh")
before_tab=$(cat "$state/tab")
touch "$state/install_fail"
out=$(cron_env bash "$CADENCE" arm --force --time 09:00 --resync-time 09:30 --model opus 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "failed install under --force is rc=4"; else fail "expected rc=4, got rc=$rc: $out"; fi
assert_has "$out" "runners left in place" "failure message explains runners are left in place"
after_drift=$(cat "$state/bat/drift-fix.sh")
after_resync=$(cat "$state/bat/fork-resync.sh")
after_tab=$(cat "$state/tab")
if [ "$before_drift" = "$after_drift" ]; then
  pass "no runner promoted to its final path on write failure (drift runner byte-identical)"
else
  fail "drift runner content changed despite the failed install"
fi
if [ "$before_resync" = "$after_resync" ]; then
  pass "no runner promoted to its final path on write failure (resync runner byte-identical)"
else
  fail "resync runner content changed despite the failed install"
fi
assert_lacks "$after_drift" "--model opus" "restored drift runner does not carry the never-installed --model opus"
assert_lacks "$after_resync" "--model opus" "restored resync runner does not carry the never-installed --model opus"
if [ "$before_tab" = "$after_tab" ]; then
  pass "cron --force re-arm with failing install keeps old runners + entries (crontab untouched)"
else
  fail "crontab changed despite the failed install"
fi
rm -f "$state/install_fail"

echo "[test-drift-fix-cadence] POSIX: mid-loop runner-write failure restores ALL pre-existing runners (CR round 5)"
# Both legs are still armed (08:00/08:30, model=sonnet, from the --force case
# two blocks up — the failed-install case just above restored back to it).
# Shadow the SECOND leg's runner path with a DIRECTORY so
# `emit_runner ... > "$runner"` fails on leg 2 -- AFTER leg 1's runner has
# already been overwritten by the same loop. Under set -e (line 59) this used
# to exit WITHOUT restoring leg 1: a pre-existing armed runner silently
# mutated while the crontab still pointed at it (the same class the win_arm
# emit_bat fix closed on Windows, round 2).
before_drift=$(cat "$state/bat/drift-fix.sh")
before_resync=$(cat "$state/bat/fork-resync.sh")
before_tab=$(cat "$state/tab")
rm -f "$state/bat/fork-resync.sh"
mkdir -p "$state/bat/fork-resync.sh"
out=$(cron_env bash "$CADENCE" arm --force --time 10:00 --resync-time 10:30 --model haiku 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "mid-loop write failure is rc=4"; else fail "expected rc=4, got rc=$rc: $out"; fi
assert_has "$out" "could not write" "failure message names the write failure"
after_drift=$(cat "$state/bat/drift-fix.sh")
if [ "$before_drift" = "$after_drift" ]; then
  pass "leg processed BEFORE the mid-loop failure was restored to its pre-existing content"
else
  fail "leg processed before the mid-loop failure was left mutated (half-armed cadence)"
fi
assert_lacks "$after_drift" "--model haiku" "restored drift runner does not carry the never-installed --model haiku"
after_tab=$(cat "$state/tab")
if [ "$before_tab" = "$after_tab" ]; then
  pass "crontab untouched -- cron_install was never reached"
else
  fail "crontab changed despite the mid-loop write failure"
fi
# Leave the world as found: the shadow directory stands in for "leg 2 could
# not be written at all", not a real runner -- put the real one back so the
# next tests below see the same state this one started with.
rm -rf "$state/bat/fork-resync.sh"
printf '%s' "$before_resync" > "$state/bat/fork-resync.sh"
chmod +x "$state/bat/fork-resync.sh"

echo "[test-drift-fix-cadence] POSIX status + disarm"
out=$(cron_env bash "$CADENCE" status 2>&1)
assert_has "$out" "ARMED" "status reports ARMED"
assert_has "$out" "HIMMEL-DriftFix" "status names the drift leg"
assert_has "$out" "HIMMEL-ForkResync" "status names the resync leg"
out=$(cron_env bash "$CADENCE" disarm --dry-run 2>&1)
assert_has "$out" "DRY" "disarm --dry-run is a preview"
if [ -f "$state/bat/drift-fix.sh" ] && [ -f "$state/bat/fork-resync.sh" ]; then
  pass "disarm --dry-run kept both runners"
else
  fail "disarm --dry-run removed a runner"
fi
out=$(cron_env bash "$CADENCE" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "disarm exits 0"; else fail "disarm rc=$rc: $out"; fi
tab=$(cat "$state/tab")
if grepq "$tab" -F "# HIMMEL-DriftFix"; then
  fail "disarm left the drift cron entry behind"
else
  pass "disarm removed the drift cron entry"
fi
if grepq "$tab" -F "# HIMMEL-ForkResync"; then
  fail "disarm left the resync cron entry behind"
else
  pass "disarm removed the resync cron entry"
fi
if [ ! -f "$state/bat/drift-fix.sh" ] && [ ! -f "$state/bat/fork-resync.sh" ]; then
  pass "disarm removed both runners"
else
  fail "disarm left a runner behind"
fi
out=$(cron_env bash "$CADENCE" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "disarm is idempotent"; else fail "second disarm rc=$rc: $out"; fi
assert_has "$out" "no-op" "second disarm says it was a no-op"
out=$(cron_env bash "$CADENCE" status 2>&1)
assert_has "$out" "not armed" "status reports not armed after disarm"
rm -rf "$root" "$state"

echo "[test-drift-fix-cadence] POSIX: a failed crontab read never reads as 'not armed'"
root=$(make_root); state=$(mktemp -d); fake_cron=$(make_fake_crontab "$state"); fake_claude=$(make_stub_claude "$state")
touch "$state/cron_fail"
assert_rc 2 "crontab -l failure is fail-closed rc=2 on arm" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" arm
assert_rc 2 "crontab -l failure is fail-closed rc=2 on disarm" \
  env DRIFTFIX_PLATFORM=posix DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_CRONTAB="$fake_cron" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" bash "$CADENCE" disarm
rm -rf "$root" "$state"

# --------------------------------------------------------------------------
if command -v cygpath >/dev/null 2>&1; then
  echo "[test-drift-fix-cadence] Windows (schtasks) arm — both legs"
  root=$(make_root); state=$(mktemp -d); fake_st=$(make_fake_schtasks "$state"); fake_claude=$(make_stub_claude "$state" .exe)
  win_env() {
    env DRIFTFIX_PLATFORM=windows DRIFTFIX_HIMMEL_ROOT="$root" \
        DRIFTFIX_SCHTASKS="$fake_st" DRIFTFIX_BAT_DIR="$state/bat" \
        DRIFTFIX_CLAUDE="$fake_claude" "$@"
  }
  out=$(win_env bash "$CADENCE" arm --dry-run 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "windows dry-run arm exits 0"; else fail "windows dry-run rc=$rc: $out"; fi
  assert_has "$out" "StartWhenAvailable" "task XML sets StartWhenAvailable (missed fires catch up)"
  assert_has "$out" "InteractiveToken" "task XML runs as the interactive user"
  assert_has "$out" "2020-01-01T05:00:00" "default 05:00 lands in the drift trigger"
  assert_has "$out" "2020-01-01T05:30:00" "default 05:30 lands in the resync trigger"
  assert_has "$out" "< NUL" "runner gives the session stdin EOF"
  assert_lacks "$out" "--print" "runner never uses --print (HIMMEL-128 billing)"
  assert_has "$out" "himmel-cadence-runner-format:" "runner carries the format stamp"
  assert_has "$out" "/drift-fix" "drift runner fires the /drift-fix runbook"
  assert_has "$out" "/fork-resync" "resync runner fires the /fork-resync runbook"
  if [ ! -f "$state/bat/drift-fix.bat" ] && [ ! -f "$state/bat/fork-resync.bat" ]; then
    pass "dry-run wrote no .bat"
  else
    fail "dry-run wrote a .bat"
  fi
  if [ ! -f "$state/armed_HIMMEL-DriftFix" ] && [ ! -f "$state/armed_HIMMEL-ForkResync" ]; then
    pass "dry-run created no task"
  else
    fail "dry-run created a task"
  fi

  out=$(win_env bash "$CADENCE" arm --time 06:45 --resync-time 07:20 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "windows arm exits 0"; else fail "windows arm rc=$rc: $out"; fi
  assert_has "$out" "drift-fix-cadence ARMED" "arm prints the summary banner"
  if [ -f "$state/bat/drift-fix.bat" ]; then
    bat=$(cat "$state/bat/drift-fix.bat")
    assert_has "$bat" '--model "sonnet"' "drift runner pins the model"
    assert_has "$bat" "move /y" "drift runner rotates its log"
    assert_has "$bat" "exit rc=" "drift runner stamps its exit rc for status"
    assert_has "$bat" "/drift-fix" "drift .bat carries the drift prompt"
    pass "drift .bat runner written"
  else
    fail "drift .bat runner was not written"
  fi
  if [ -f "$state/bat/fork-resync.bat" ]; then
    bat=$(cat "$state/bat/fork-resync.bat")
    assert_has "$bat" "/fork-resync" "resync .bat fires /fork-resync, not /drift-fix"
    assert_lacks "$bat" "/drift-fix" "resync .bat does not carry the drift prompt"
    assert_has "$bat" "fork-resync.log" "resync .bat carries its own log path"
    pass "resync .bat runner written"
  else
    fail "resync .bat runner was not written"
  fi
  if grep -q '/create /tn HIMMEL-DriftFix' "$state/calls"; then
    pass "schtasks /create was invoked for the drift leg"
  else
    fail "schtasks /create was never invoked for the drift leg"
  fi
  if grep -q '/create /tn HIMMEL-ForkResync' "$state/calls"; then
    pass "schtasks /create was invoked for the resync leg"
  else
    fail "schtasks /create was never invoked for the resync leg"
  fi

  echo "[test-drift-fix-cadence] Windows dedup: rc=3 when only ONE leg is armed"
  # Simulate an externally-disarmed resync leg (delete just its armed sentinel)
  # and confirm arm still refuses, naming only the leg it actually found.
  rm -f "$state/armed_HIMMEL-ForkResync"
  out=$(win_env bash "$CADENCE" arm 2>&1); rc=$?
  if [ "$rc" -eq 3 ]; then pass "dedup refuses when only the drift leg is armed (rc=3)"; else fail "expected rc=3, got rc=$rc: $out"; fi
  assert_has "$out" "already armed: HIMMEL-DriftFix." "dedup message names the armed leg"
  assert_lacks "$out" "HIMMEL-ForkResync" "dedup message does not mention the unarmed leg"
  touch "$state/armed_HIMMEL-ForkResync"

  echo "[test-drift-fix-cadence] Windows dedup + force (both legs armed)"
  assert_rc 3 "second arm is refused (dedup, both legs armed)" win_env bash "$CADENCE" arm
  out=$(win_env bash "$CADENCE" arm --force 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "--force replaces"; else fail "--force rc=$rc: $out"; fi
  # /create /f overwrites in place — a pre-emptive /delete would leave no
  # cadence at all if a later prep step failed (HIMMEL-892 codex-adv-2).
  if grep -q '/delete' "$state/calls"; then fail "--force pre-deleted a task instead of /create /f"; else pass "--force replaced via /create /f, never a pre-emptive /delete"; fi

  out=$(win_env bash "$CADENCE" status 2>&1)
  assert_has "$out" "ARMED" "status reports ARMED"
  assert_has "$out" "HIMMEL-DriftFix" "status names the drift leg"
  assert_has "$out" "HIMMEL-ForkResync" "status names the resync leg"
  assert_has "$out" "next run:" "status surfaces the next run time"
  out=$(win_env bash "$CADENCE" disarm 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "disarm exits 0"; else fail "disarm rc=$rc: $out"; fi
  if [ ! -f "$state/armed_HIMMEL-DriftFix" ] && [ ! -f "$state/armed_HIMMEL-ForkResync" ]; then
    pass "disarm deleted both tasks"
  else
    fail "disarm left a task armed"
  fi
  if [ ! -f "$state/bat/drift-fix.bat" ] && [ ! -f "$state/bat/fork-resync.bat" ]; then
    pass "disarm removed both .bats"
  else
    fail "disarm left a .bat behind"
  fi

  echo "[test-drift-fix-cadence] Windows: an unrecognized query failure is fail-closed"
  touch "$state/query_fail"
  assert_rc 2 "unrecognized /query stderr is rc=2 on arm, never 'not armed'" \
    win_env bash "$CADENCE" arm
  assert_rc 2 "unrecognized /query stderr is rc=2 on status" win_env bash "$CADENCE" status
  assert_rc 2 "unrecognized /query stderr is rc=2 on disarm" win_env bash "$CADENCE" disarm
  rm -rf "$root" "$state"

  echo "[test-drift-fix-cadence] Windows: post-arm verify failure rolls back BOTH legs (all-or-nothing)"
  root=$(make_root); state=$(mktemp -d); fake_st=$(make_fake_schtasks "$state"); fake_claude=$(make_stub_claude "$state" .exe)
  # The resync leg's /query will report success but with no Next Run Time —
  # the fake's way of simulating a task that "created" but never really armed.
  touch "$state/no_next_run_HIMMEL-ForkResync"
  out=$(win_env bash "$CADENCE" arm 2>&1); rc=$?
  if [ "$rc" -eq 4 ]; then pass "post-arm verify failure is rc=4"; else fail "expected rc=4, got rc=$rc: $out"; fi
  assert_has "$out" "rolling back both legs" "verify failure message says it rolls back both legs"
  if [ ! -f "$state/armed_HIMMEL-DriftFix" ] && [ ! -f "$state/armed_HIMMEL-ForkResync" ]; then
    pass "post-arm verify failure leaves NEITHER leg armed (all-or-nothing)"
  else
    fail "post-arm verify failure left a leg armed"
  fi
  rm -rf "$root" "$state"

  echo "[test-drift-fix-cadence] Windows: mid-loop cygpath failure rolls back BOTH legs (CR)"
  root=$(make_root); state=$(mktemp -d); fake_st=$(make_fake_schtasks "$state"); fake_claude=$(make_stub_claude "$state" .exe)
  # A fake cygpath that delegates to the real one for every path except the
  # resync leg's — simulating the exact failure the drift leg's task has
  # ALREADY been created by the time it hits (arm is all-or-nothing).
  real_cygpath="$(command -v cygpath)"
  fake_cyg="$state/cygpath"
  cat > "$fake_cyg" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  *fork-resync*) echo "fake cygpath: simulated failure" >&2; exit 1 ;;
esac
exec "$real_cygpath" "\$@"
FAKE
  chmod +x "$fake_cyg"
  out=$(env DRIFTFIX_PLATFORM=windows DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_SCHTASKS="$fake_st" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_claude" PATH="$state:$PATH" bash "$CADENCE" arm 2>&1); rc=$?
  if [ "$rc" -eq 4 ]; then pass "mid-loop cygpath failure is rc=4"; else fail "expected rc=4, got rc=$rc: $out"; fi
  if [ ! -f "$state/armed_HIMMEL-DriftFix" ] && [ ! -f "$state/armed_HIMMEL-ForkResync" ]; then
    pass "mid-loop cygpath failure leaves NEITHER leg armed (all-or-nothing)"
  else
    fail "mid-loop cygpath failure left a leg armed (half-armed cadence)"
  fi
  rm -rf "$root" "$state"

  echo "[test-drift-fix-cadence] Windows: emit_bat write failure rolls back BOTH legs (CR)"
  root=$(make_root); state=$(mktemp -d); fake_st=$(make_fake_schtasks "$state"); fake_claude=$(make_stub_claude "$state" .exe)
  # A directory sitting where the drift leg's .bat should be a file -- the
  # `emit_bat ... > "$bat_file"` redirect fails, and that failure must not
  # slip past the `set -e` guard without rolling back both legs.
  mkdir -p "$state/bat/drift-fix.bat"
  out=$(win_env bash "$CADENCE" arm 2>&1); rc=$?
  if [ "$rc" -eq 4 ]; then pass "emit_bat write failure is rc=4"; else fail "expected rc=4, got rc=$rc: $out"; fi
  assert_has "$out" "could not write" "write failure message names the bat file"
  if [ ! -f "$state/armed_HIMMEL-DriftFix" ] && [ ! -f "$state/armed_HIMMEL-ForkResync" ]; then
    pass "emit_bat write failure leaves NEITHER leg armed (all-or-nothing)"
  else
    fail "emit_bat write failure left a leg armed (half-armed cadence)"
  fi
  rm -rf "$root" "$state"

  echo "[test-drift-fix-cadence] Windows: an extensionless claude shim is refused at arm time"
  # A literal extensionless shell shim (npm-style `claude`, no .exe sibling)
  # exists on disk, so an existence-only check accepts it — but the .bat then
  # invokes an extensionless path cmd.exe cannot run, and every 05:00 fire dies
  # in a log nobody reads. The arm path must refuse it at ARM time, when someone
  # is present to act on it, instead. (CR round-9)
  root=$(make_root); state=$(mktemp -d); fake_st=$(make_fake_schtasks "$state"); fake_shim=$(make_stub_claude "$state")
  out=$(env DRIFTFIX_PLATFORM=windows DRIFTFIX_HIMMEL_ROOT="$root" \
      DRIFTFIX_SCHTASKS="$fake_st" DRIFTFIX_BAT_DIR="$state/bat" \
      DRIFTFIX_CLAUDE="$fake_shim" bash "$CADENCE" arm 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then pass "extensionless claude shim refused at arm time (rc=2)"; else fail "expected rc=2 for extensionless shim, got rc=$rc: $out"; fi
  assert_has "$out" "cmd.exe can run" "refusal explains cmd.exe cannot run it"
  assert_has "$out" "DRIFTFIX_CLAUDE" "refusal points the operator at DRIFTFIX_CLAUDE"
  if [ ! -f "$state/bat/drift-fix.bat" ] && [ ! -f "$state/armed_HIMMEL-DriftFix" ]; then
    pass "extensionless shim armed nothing (no .bat, no task)"
  else
    fail "extensionless shim armed despite being unrunnable by cmd.exe"
  fi
  rm -rf "$root" "$state"
else
  echo "[test-drift-fix-cadence] Windows (schtasks) — skipped: no cygpath on this host"
fi

echo "[test-drift-fix-cadence] the runner basenames are registered for staleness probes"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"
case " $CADENCE_RUNNER_BASENAMES " in
  *" drift-fix "*) pass "drift-fix is in CADENCE_RUNNER_BASENAMES" ;;
  *) fail "drift-fix missing from CADENCE_RUNNER_BASENAMES — himmel-doctor/himmel-update will not see a stale runner" ;;
esac
case " $CADENCE_RUNNER_BASENAMES " in
  *" fork-resync "*) pass "fork-resync is in CADENCE_RUNNER_BASENAMES" ;;
  *) fail "fork-resync missing from CADENCE_RUNNER_BASENAMES — himmel-doctor/himmel-update will not see a stale runner" ;;
esac

echo ""
if [ "$fails" -eq 0 ]; then
  echo "[test-drift-fix-cadence] all checks passed"
  exit 0
fi
echo "[test-drift-fix-cadence] $fails check(s) FAILED"
exit 1
