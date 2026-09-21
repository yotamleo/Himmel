#!/usr/bin/env bash
# test-provenance-roundtrip-dry.sh — hermetic coverage for
# scripts/vm/provenance-roundtrip.sh (HIMMEL-3332 S9b). NEVER touches a real
# VM: a fake `VBoxManage`, a fake venv python (HIMMEL_VM_PYTHON, standing in
# for every scripts/lib/vbox.py call) and a fake `ssh` on PATH log every call.
# The fake ssh answers the guest command shapes the harness sends and, for the
# assertion step, prints the CHECK lines the case put in $FAKE_ASSERT — so the
# host-side verdict logic (the two-direction RED) is exercised without a guest.
#
# Covers: the guest step order, the printed `env -i` environment equalling the
# one passed (HIMMEL-3321), --expect-red needing BOTH directions, the normal
# verdict, the uninstall step's flags, the himmelctl `--yes` / `--purge-state`
# pass-through the uninstall step relies on, the HIMMEL-2623 VBoxManage guard,
# cleanup (power off, snapshot restore, lock release) on success and on a
# failed guest step, a bad ref, seed-provenance.sh's refusals, the profile the
# seed step carries and the crontab capture (the guest-side helpers' own
# behaviour is test-assert-provenance.sh).
#
# Platform guard (linux-only): a bash harness driving FAKE VBoxManage/ssh —
# the script it covers is itself linux-only (flock, VirtualBox on the station).
#
# Usage: bash scripts/vm/test-provenance-roundtrip-dry.sh
# No pipefail: every assert is `producer | grep -q`, and under pipefail an
# early grep exit SIGPIPEs the producer and flips a match to a failure.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/provenance-roundtrip.sh"
SEED="$REPO_ROOT/scripts/vm/lib/seed-provenance.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-rt-dry.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

# --- fake VBoxManage: every call logged; `list vms` reports the clone as
# already registered, so vm_clone_ensure never reaches clonevm. -------------
cat >"$FAKEBIN/VBoxManage" <<'EOF'
#!/usr/bin/env bash
printf 'VBOX %s\n' "$*" >> "$FAKE_LOG"
if [ "${1:-}" = list ]; then printf '"ubuntu_new" {u0}\n"himmel-ar-1" {u1}\n"himmel-ar-2" {u2}\n'; fi
exit 0
EOF

# --- fake venv python: argv is `-c <code> <REPO_ROOT> <args...>`; logs the
# vbox.* verb and its args, answers the three calls whose output is parsed. ---
cat >"$FAKEBIN/fakepy" <<'EOF'
#!/usr/bin/env bash
code="$2"; shift 3
verb=$(printf '%s\n' "$code" | grep -o 'vbox\.[a-z_]*' | tail -n1)
printf 'PY %s %s\n' "$verb" "$*" >> "$FAKE_LOG"
case "$verb" in
  vbox.get_forwards) echo 2299 ;;
  vbox.wait_for_ssh) echo True ;;
esac
exit 0
EOF

# --- fake ssh: the remote command is the LAST argv element. ----------------
cat >"$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
for last in "$@"; do :; done
printf 'SSH %s\n' "$last" >> "$FAKE_LOG"
if [ -n "${FAKE_FAIL_MATCH:-}" ] && [[ "$last" == *"$FAKE_FAIL_MATCH"* ]]; then exit 7; fi
case "$last" in
  'command -v rsync'*) exit 1 ;;
  *'-xf -'|'cat > '*) cat >/dev/null ;;
  *assert-provenance.sh*) cat "$FAKE_ASSERT" ;;
  *'bin.js uninstall'*)
    case "${FAKE_UNINSTALL:-ok}" in
      halt) echo '[uninstall-log] Halted at: [7/8] Claude marketplaces: uninstall-plugins.sh reported failures'; exit 2 ;;
      rc3) echo '[uninstall-log] boom'; exit 3 ;;
      early) echo '[uninstall-log] Halted at: [3/8] Claude settings: jq failed'; exit 2 ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/VBoxManage" "$FAKEBIN/fakepy" "$FAKEBIN/ssh"

BOTH="$WORK/assert-both"
cat >"$BOTH" <<'EOF'
CHECK semantic too-much FAIL context7-enabled — enabledPlugins["context7@claude-plugins-official"] is absent
CHECK semantic too-little FAIL hud-allow-extra-cmd-removed — env.CLAUDE_HUD_ALLOW_EXTRA_CMD still set
CHECK removal too-little PASS no-launcher — ~/.local/bin/himmelctl absent
EOF
ONLY_MUCH="$WORK/assert-much"
grep -v 'too-little FAIL' "$BOTH" >"$ONLY_MUCH"
ONLY_LITTLE="$WORK/assert-little"
grep -v 'too-much FAIL' "$BOTH" >"$ONLY_LITTLE"
ALL_PASS="$WORK/assert-pass"
grep 'PASS' "$BOTH" >"$ALL_PASS"
NO_CHECKS="$WORK/assert-none"
echo "assert-provenance.sh: nothing to report" >"$NO_CHECKS"

N=0
# run_rt <assert-fixture> [harness args...] — one hermetic harness run; sets
# OUT, RC and LOG. Each run gets its own lock dirs and log.
run_rt() {
    local fixture="$1"; shift
    N=$((N + 1))
    LOG="$WORK/log-$N"; : >"$LOG"
    OUT=$(PATH="$FAKEBIN:$PATH" FAKE_LOG="$LOG" FAKE_ASSERT="$fixture" \
        VBOXMANAGE_PATH="$FAKEBIN/VBoxManage" HIMMEL_VM_PYTHON="$FAKEBIN/fakepy" \
        HIMMEL_VM_AR_GUEST_USER=testuser HIMMEL_VM_AR_RAM_MB=1 \
        HIMMEL_VM_AR_LOCK_DIR="$WORK/slots-$N" HIMMEL_VM_LOCK_DIR="$WORK/vmlock-$N" \
        HIMMEL_VM_AR_SSH_KEY="$WORK/nokey" \
        bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}
dump() { printf '%s\n' "$OUT" | sed 's/^/    /'; sed 's/^/    log: /' "$LOG"; }

# ssh_order <log> — the guest steps in the order the log saw them, one word each.
ssh_order() {
    grep '^SSH ' "$1" | while IFS= read -r l; do
        case "$l" in
            *'tar -C /tmp/rt-src'*) echo stage ;;
            *seed-provenance.sh*) echo seed ;;
            *'inventory.sh A'*) echo invA ;;
            *'bin.js install'*'--scope project'*) echo install-project ;;
            *'bin.js install'*'--scope user'*) echo install-user ;;
            *'inventory.sh B'*) echo invB ;;
            *'bin.js uninstall'*) echo uninstall ;;
            *'inventory.sh C'*) echo invC ;;
            *assert-provenance.sh*) echo assert ;;
        esac
    done | tr '\n' ' '
}

# =====================================================================
# D1 — step order; --expect-red with both directions = RED complete, rc 0
# =====================================================================
run_rt "$BOTH" f73a62f1 --expect-red
want='stage seed invA install-project install-user invB uninstall invC assert '
got=$(ssh_order "$LOG")
if [ "$got" = "$want" ]; then pass "D1 guest step order: $got"; else fail_case "D1 step order: got '$got' want '$want'"; dump; fi
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^RED complete: too-much=1 too-little=1'; then
    pass "D1b --expect-red with both directions exits 0 with RED complete"
else
    fail_case "D1b both directions: rc=$RC"; dump
fi

# =====================================================================
# D2 — the printed env is exactly the env passed to both installs (3321)
# =====================================================================
envline='env -i HOME=/home/testuser PATH=/home/testuser/.local/bin:/usr/local/bin:/usr/bin:/bin HIMMELCTL_CACHE_DIR=/home/testuser/.claude/himmel'  # leak-allow: home-path fixture guest user testuser, not a real home
if printf '%s\n' "$OUT" | grep -qxF "[env] $envline" \
   && [ "$(grep '^SSH ' "$LOG" | grep -c "bin.js install" )" -eq 2 ] \
   && [ "$(grep '^SSH ' "$LOG" | grep "bin.js install" | grep -cF "$envline node ")" -eq 2 ] \
   && grep '^SSH ' "$LOG" | grep 'bin.js uninstall' | grep -qF "$envline node "; then
    pass "D2 printed [env] line equals the env -i passed to both installs and the uninstall"
else
    fail_case "D2 printed env vs passed env"; dump
fi

# =====================================================================
# D3 — --expect-red with only the too-much direction: RED incomplete
# =====================================================================
run_rt "$ONLY_MUCH" f73a62f1 --expect-red
if [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qxF 'RED incomplete: too-little direction missing'; then
    pass "D3 --expect-red with only too-much exits $RC: RED incomplete: too-little direction missing"
else
    fail_case "D3 only too-much: rc=$RC"; dump
fi

# D4 — the mirror: only too-little
run_rt "$ONLY_LITTLE" f73a62f1 --expect-red
if [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qxF 'RED incomplete: too-much direction missing'; then
    pass "D4 --expect-red with only too-little exits $RC: RED incomplete: too-much direction missing"
else
    fail_case "D4 only too-little: rc=$RC"; dump
fi

# =====================================================================
# D5 — normal mode: all PASS = 0; any FAIL = 1; --expect-red on all-PASS = 1
# =====================================================================
run_rt "$ALL_PASS" f73a62f1
r_pass=$RC
run_rt "$BOTH" f73a62f1
r_fail=$RC
run_rt "$ALL_PASS" f73a62f1 --expect-red
r_red_green=$RC
if [ "$r_pass" -eq 0 ] && [ "$r_fail" -eq 1 ] && [ "$r_red_green" -eq 1 ]; then
    pass "D5 normal verdict: all-PASS=0, FAIL=1; --expect-red on a green run=1"
else
    fail_case "D5 normal verdict: all-pass=$r_pass fail=$r_fail red-on-green=$r_red_green"; dump
fi

# D6 — no CHECK lines at all is a harness failure, never a verdict
run_rt "$NO_CHECKS" f73a62f1 --expect-red
if [ "$RC" -eq 2 ]; then pass "D6 zero CHECK lines exits 2"; else fail_case "D6 zero checks: rc=$RC"; dump; fi

# =====================================================================
# D7 — the uninstall step: himmelctl --yes (+ --purge-state), and the
# harness never sets HIMMEL_UNINSTALL_REAL_HOME itself
# =====================================================================
run_rt "$BOTH" f73a62f1 --expect-red --purge-state
un=$(grep '^SSH ' "$LOG" | grep 'bin.js uninstall')
if [[ "$un" == *'bin.js uninstall --yes --purge-state'* ]] \
   && ! grep -q 'HIMMEL_UNINSTALL_REAL_HOME' "$LOG" \
   && ! grep -q 'HIMMEL_UNINSTALL_REAL_HOME=' "$SCRIPT"; then
    pass "D7 uninstall runs 'himmelctl uninstall --yes --purge-state'; HIMMEL_UNINSTALL_REAL_HOME never set by the harness"
else
    fail_case "D7 uninstall step: '$un'"; dump
fi

# D7b — the plain variant (spec §11 runs both): no --purge-state reaches the
# uninstall, and every reported direction names the variant it came from
run_rt "$BOTH" f73a62f1 --expect-red
un=$(grep '^SSH ' "$LOG" | grep 'bin.js uninstall')
if [[ "$un" == *'bin.js uninstall --yes'* ]] && [[ "$un" != *purge-state* ]] \
   && printf '%s\n' "$OUT" | grep -qF 'RED complete: too-much=1 too-little=1 variant=(profile=core uninstall=plain)' \
   && printf '%s\n' "$OUT" | grep -qF '[summary] variant=(profile=core uninstall=plain)' \
   && printf '%s\n' "$OUT" | grep -qF '[witness] (profile=core uninstall=plain) context7-enabled FAIL pre-halt (predicted)'; then
    pass "D7b plain variant: 'uninstall --yes' without --purge-state; directions tagged uninstall=plain"
else
    fail_case "D7b plain variant: '$un'"; dump
fi
run_rt "$BOTH" f73a62f1 --expect-red --purge-state --profile all
if printf '%s\n' "$OUT" | grep -qF 'variant=(profile=all uninstall=purge-state)'; then
    pass "D7c purge variant under --profile all is tagged profile=all uninstall=purge-state"
else
    fail_case "D7c purge variant tag"; dump
fi
# D7d — the install argv per profile (console ruling): core = `install --scope
# <s>` with no --profile/--yes; all = `--from-profile` of a profile the guest
# derives from the shipped adopter-<s> file by the printed jq overlay
# shellcheck disable=SC2016 # $v is jq's
ov='jq --arg v /home/testuser/luna '"'"'.vault = {mode: "default-template", path: $v} | .cadences = {pipeline: "armed", qmd: "armed", graphmap: "armed"}'"'"
if [ "$(grep '^SSH ' "$LOG" | grep -c "adopter-project.install-profile.json >/tmp/rt-work/profile-all-project.json")" -eq 1 ] \
   && [ "$(grep '^SSH ' "$LOG" | grep -c "adopter-user.install-profile.json >/tmp/rt-work/profile-all-user.json")" -eq 1 ] \
   && grep '^SSH ' "$LOG" | grep 'profile-all-user.json' | grep -qF "$ov" \
   && printf '%s\n' "$OUT" | grep -qF "[overlay] $ov" \
   && grep '^SSH ' "$LOG" | grep -qF 'bin.js install --from-profile /tmp/rt-work/profile-all-user.json --scope user' \
   && ! grep '^SSH ' "$LOG" | grep 'bin.js install' | grep -qE -- '--profile |--yes'; then
    pass "D7d --profile all: guest derives adopter-<scope> + printed overlay, installs --from-profile it"
else
    fail_case "D7d profile-all install argv"; dump
fi
run_rt "$BOTH" f73a62f1 --expect-red
if grep '^SSH ' "$LOG" | grep -qF 'bin.js install --scope project >' \
   && ! grep -q 'profile-all' "$LOG"; then
    pass "D7e core: 'install --scope <s>', no derived profile"
else
    fail_case "D7e core install argv"; dump
fi

# =====================================================================
# D8 — the pass-through D7 relies on (console ruling): the CURRENT tree's
# himmelctl `uninstall --yes --purge-state` reaches scripts/uninstall.sh with
# both flags and no prompt; without --yes a non-interactive run aborts rc 2
# before uninstall.sh runs. A stub uninstall.sh under HIMMELCTL_REPO_ROOT
# logs its argv; HOME is a scratch dir. Nothing real is uninstalled.
# =====================================================================
FIX="$WORK/d8-repo"
mkdir -p "$FIX/scripts" "$WORK/d8-home"
cat >"$FIX/scripts/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "$D8_LOG"
exit 0
EOF
D8_LOG="$WORK/d8.log"; : >"$D8_LOG"
if command -v node >/dev/null 2>&1; then
    HOME="$WORK/d8-home" HIMMELCTL_REPO_ROOT="$FIX" D8_LOG="$D8_LOG" \
        node "$REPO_ROOT/scripts/himmelctl/bin.js" uninstall --yes --purge-state </dev/null >/dev/null 2>&1
    d8_yes=$?
    d8_first=$(cat "$D8_LOG")
    HOME="$WORK/d8-home" HIMMELCTL_REPO_ROOT="$FIX" D8_LOG="$D8_LOG" \
        node "$REPO_ROOT/scripts/himmelctl/bin.js" uninstall --purge-state </dev/null >/dev/null 2>&1
    d8_noyes=$?
    if [ "$d8_yes" -eq 0 ] && [ "$d8_first" = 'argv=--yes --purge-state' ] \
       && [ "$d8_noyes" -eq 2 ] && [ "$(cat "$D8_LOG")" = "$d8_first" ]; then
        pass "D8 himmelctl uninstall --yes --purge-state reaches uninstall.sh as '--yes --purge-state'; without --yes: rc 2, uninstall.sh not run"
    else
        fail_case "D8 pass-through: yes-rc=$d8_yes argv='$d8_first' noyes-rc=$d8_noyes log=$(cat "$D8_LOG")"
    fi
else
    echo "SKIP D8: node not on PATH"
fi

# =====================================================================
# D9 — HIMMEL-2623 guard: no VBOXMANAGE_PATH and no HIMMEL_VM_AR_LIVE=1
# refuses before a single VBoxManage call
# =====================================================================
LOG="$WORK/log-d9"; : >"$LOG"
OUT=$(env -u VBOXMANAGE_PATH -u HIMMEL_VM_AR_LIVE PATH="$FAKEBIN:$PATH" FAKE_LOG="$LOG" \
    HIMMEL_VM_PYTHON="$FAKEBIN/fakepy" HIMMEL_VM_AR_LOCK_DIR="$WORK/slots-d9" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-d9" bash "$SCRIPT" f73a62f1 --expect-red 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -s "$LOG" ]; then
    pass "D9 unset VBOXMANAGE_PATH refuses (rc=$RC) with zero VBoxManage/ssh calls"
else
    fail_case "D9 guard: rc=$RC"; dump
fi

# =====================================================================
# D10 — cleanup after a normal run: power off, then restore the clean
# snapshot, then the lock is free again (a fresh run acquires it at once)
# =====================================================================
run_rt "$BOTH" f73a62f1 --expect-red
cleanup_order=$(grep -E '^PY vbox\.(power_off|restore_snapshot)' "$LOG" | awk '{print $2}' | tr '\n' ' ')
lockdir="$WORK/vmlock-$N"
if [ "$cleanup_order" = 'vbox.restore_snapshot vbox.power_off vbox.restore_snapshot ' ] \
   && printf '%s\n' "$OUT" | grep -q '^\[cleanup\] himmel-ar-1 powered off, restored to suite-ready-v4, vm-lock released'; then
    pass "D10 cleanup: power_off then restore_snapshot, lock released"
else
    fail_case "D10 cleanup order: '$cleanup_order'"; dump
fi
if OUT=$(HIMMEL_VM_LOCK_DIR="$lockdir" bash -c '. "$1"; vm_lock_acquire himmel-ar-1' _ "$REPO_ROOT/scripts/vm/vm-lock.sh" 2>&1); then
    pass "D10b the vm-lock on himmel-ar-1 is free after the run"; else fail_case "D10b lock still held: $OUT"; fi

# D11 — a ref that does not resolve: rc 2 before any VBoxManage call
run_rt "$BOTH" no-such-ref-himmel-3332 --expect-red
if [ "$RC" -eq 2 ] && [ ! -s "$LOG" ]; then pass "D11 bad ref exits 2 before touching VBoxManage"; else fail_case "D11 bad ref: rc=$RC"; dump; fi

# D11b — usage errors
run_rt "$BOTH" f73a62f1 --profile bogus
r1=$RC
run_rt "$BOTH"
r2=$RC
if [ "$r1" -eq 2 ] && [ "$r2" -eq 2 ]; then pass "D11b bad --profile / missing ref exit 2"; else fail_case "D11b usage: profile=$r1 noref=$r2"; fi

# =====================================================================
# D12 — a failed guest step: rc 2, later steps never run, cleanup still ran
# =====================================================================
FAKE_FAIL_MATCH='--scope user' run_rt "$BOTH" f73a62f1 --expect-red
got=$(ssh_order "$LOG")
if [ "$RC" -eq 2 ] && [ "$got" = 'stage seed invA install-project install-user ' ] \
   && grep -q '^PY vbox.power_off' "$LOG" \
   && printf '%s\n' "$OUT" | grep -q 'step install-user failed'; then
    pass "D12 failed install-user step: rc 2, stops there, cleanup powered off"
else
    fail_case "D12 failed step: rc=$RC order='$got'"; dump
fi

# =====================================================================
# D13 — seed-provenance.sh refuses off-guest and over existing state
# (only the refusal paths run here: the seeding itself writes a crontab
# and belongs on the guest)
# =====================================================================
SH="$WORK/d13-home"; mkdir -p "$SH"
out=$(env -u HIMMEL_RT_GUEST HOME="$SH" bash "$SEED" 2>&1); r_noflag=$?
mkdir -p "$SH/.claude"; echo '# mine' >"$SH/.claude/CLAUDE.md"
out2=$(HIMMEL_RT_GUEST=1 HOME="$SH" bash "$SEED" 2>&1); r_exists=$?
if [ "$r_noflag" -eq 2 ] && [ "$r_exists" -eq 2 ] && [ "$(ls -A "$SH")" = .claude ] \
   && [ "$(ls -A "$SH/.claude")" = CLAUDE.md ] && [[ "$out2" == *'.claude/CLAUDE.md'* ]]; then
    pass "D13 seed refuses without HIMMEL_RT_GUEST=1 and over an existing target, writing nothing"
else
    fail_case "D13 seed refusals: noflag=$r_noflag exists=$r_exists out='$out' out2='$out2' ls=$(ls -A "$SH")"
fi

# =====================================================================
# D14 — a halted uninstall is a result (console ruling): its rc and halt step
# print as their own line, the run continues to inventory C, and a witness
# owned by a step after the halt ([8/8] ~/.claude/himmel, the post-teardown
# PATH launchers) is post-halt and does not count toward the two directions
# =====================================================================
POST="$WORK/assert-post"
cat >"$POST" <<'EOF'
CHECK semantic too-much FAIL context7-enabled — enabledPlugins["context7@claude-plugins-official"] is absent
CHECK removal too-little FAIL claude-himmel-dir-removed — ~/.claude/himmel present
CHECK residue too-little FAIL left:~/.local/bin/himmelctl — 1 path(s) left behind
EOF
FAKE_UNINSTALL=halt run_rt "$POST" f73a62f1 --expect-red
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qxF 'uninstall-exit rc=2 halted-at=[7/8]' \
   && grep '^SSH ' "$LOG" | grep -q 'inventory.sh C' \
   && printf '%s\n' "$OUT" | grep -qxF '[halt] post-halt too-little claude-himmel-dir-removed' \
   && printf '%s\n' "$OUT" | grep -qxF '[halt] post-halt too-little left:~/.local/bin/himmelctl' \
   && printf '%s\n' "$OUT" | grep -qxF 'RED incomplete: too-little direction missing'; then
    pass "D14 halt at [7/8]: rc line printed, inventory C taken, [8/8]/launcher witnesses post-halt, RED incomplete"
else
    fail_case "D14 halted uninstall rc=$RC"; dump
fi
cat "$BOTH" "$POST" >"$WORK/assert-both-post"
FAKE_UNINSTALL=halt run_rt "$WORK/assert-both-post" f73a62f1 --expect-red
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'RED complete: too-much=2 too-little=1 ' \
   && printf '%s\n' "$OUT" | grep -qF 'hud-allow-extra-cmd-removed FAIL pre-halt (predicted)'; then
    pass "D14b halt: a pre-halt too-little witness still completes the RED"
else
    fail_case "D14b halt with a pre-halt witness rc=$RC"; dump
fi
run_rt "$POST" f73a62f1 --expect-red
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF 'uninstall-exit rc=0 halted-at=none' \
   && ! printf '%s\n' "$OUT" | grep -q '^\[halt\]' \
   && printf '%s\n' "$OUT" | grep -qF 'RED complete: too-much=1 too-little=2 '; then
    pass "D14c no halt: the same witnesses are all pre-halt"
else
    fail_case "D14c no halt rc=$RC"; dump
fi
FAKE_UNINSTALL=rc3 run_rt "$BOTH" f73a62f1 --expect-red
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF "step uninstall failed (rc=3) with no 'Halted at:' line" \
   && ! grep '^SSH ' "$LOG" | grep -q 'inventory.sh C'; then
    pass "D14d a failed uninstall with no halt line is a harness failure (rc 2)"
else
    fail_case "D14d unexplained uninstall failure rc=$RC"; dump
fi
FAKE_UNINSTALL=early run_rt "$BOTH" f73a62f1 --expect-red
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'uninstall halted at [3/8]; the pre/post-halt owner map only resolves' \
   && ! grep '^SSH ' "$LOG" | grep -q 'inventory.sh C'; then
    pass "D14f a halt before [7/8] is refused (rc 2): the owner map cannot attribute it"
else
    fail_case "D14f early halt rc=$RC"; dump
fi
# D14e/g — HIMMEL-3351: the guest is provisioned by the seed step, so `all` no
# longer tolerates a failed install nor prints an UNOBSERVABLE witness
run_rt "$BOTH" f73a62f1 --expect-red --profile all
if ! printf '%s\n' "$OUT" | grep -q 'UNOBSERVABLE' && ! printf '%s\n' "$OUT" | grep -q '^install-exit '; then
    pass "D14e --profile all: no UNOBSERVABLE witness, no tolerated install exit"
else
    fail_case "D14e cadence witness"; dump
fi
FAKE_FAIL_MATCH='bin.js install' run_rt "$BOTH" f73a62f1 --expect-red --profile all
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'step install-project failed (rc=7)' \
   && ! grep '^SSH ' "$LOG" | grep -q 'inventory.sh C'; then
    pass "D14g --profile all: a failed install ends the run (rc 2) before inventory C"
else
    fail_case "D14g all-profile install failure rc=$RC"; dump
fi
FAKE_FAIL_MATCH='bin.js install' run_rt "$BOTH" f73a62f1 --expect-red
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'step install-project failed (rc=7)'; then
    pass "D14h --profile core: a failed install still ends the run (rc 2)"
else
    fail_case "D14h core install failure rc=$RC"; dump
fi

# D15 — HIMMEL-3351: the seed step carries the profile (the `all` seed puts the
# qmd/graphify stubs on the guest); inventory B also captures the crontab the
# armed-at-B precondition reads
for prof in core all; do
    run_rt "$BOTH" f73a62f1 --expect-red --profile "$prof"
    if grep '^SSH ' "$LOG" | grep 'seed-provenance.sh' | grep -qF "HIMMEL_RT_GUEST=1 RT_PROFILE=$prof bash /tmp/rt-work/seed-provenance.sh"; then
        pass "D15 seed step carries RT_PROFILE=$prof"
    else
        fail_case "D15 seed step under $prof"; dump
    fi
done
if grep '^SSH ' "$LOG" | grep 'inventory.sh B' | grep -qF 'crontab -l >/tmp/rt-work/crontab-B.txt'; then
    pass "D15b inventory B step captures crontab -l to crontab-B.txt"
else
    fail_case "D15b crontab capture"; dump
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILED FAILED"; exit 1
