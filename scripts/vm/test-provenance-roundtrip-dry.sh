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
  *'bin.js uninstall'*|*'.local/bin/himmelctl uninstall'*)
    case "${FAKE_UNINSTALL:-ok}" in
      halt) echo '[uninstall-log] Halted at: [7/8] Claude marketplaces: uninstall-plugins.sh reported failures'; exit 2 ;;
      rc3) echo '[uninstall-log] boom'; exit 3 ;;
      early) echo '[uninstall-log] Halted at: [3/8] Claude settings: jq failed'; exit 2 ;;
      mkt) echo '[uninstall-log]   marketplace remove: rt-dir-marketplace' ;;
    esac ;;
  *'find '*'.himmel -mindepth 1'*)
    case "${FAKE_HIMMEL_CONTENTS:-config}" in
      config) echo "/home/testuser/.himmel/config.json" ;;
      empty) : ;;
      extra) printf '%s\n' \
        "/home/testuser/.himmel/config.json" \
        "/home/testuser/.himmel/uninstall" \
        "/home/testuser/.himmel/uninstall/bundle.json" ;;
    esac ;;
esac
exit 0
EOF

# --- fake docker/podman: the aur-mode container runtime. `info` answers
# whether the runtime is "up" (FAKE_RUNTIME_NO_INFO forces both to refuse, for
# the no-runtime-answers case); `run` prints a fake container id; `exec`'s
# remote command is the LAST argv element, same shape ssh already forwards
# (aur_ssh's `bash -c "$1"` produces the identical trailing command-string),
# so the same $last case-match technique applies. The one exec that is NOT
# that shape is the root container-setup call (`exec <c> bash /root/aur-setup.sh
# ...`); it is matched separately, by substring, and always succeeds.
cat >"$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
tag=$(basename "$0" | tr '[:lower:]' '[:upper:]')
printf '%s %s\n' "$tag" "$*" >> "$FAKE_LOG"
case "${1:-}" in
  info)
    [ "$tag" != DOCKER ] || [ -z "${FAKE_DOCKER_ONLY_FAIL:-}" ] || exit 1
    [ -z "${FAKE_RUNTIME_NO_INFO:-}" ] || exit 1
    exit 0 ;;
  run) echo "${FAKE_CONTAINER_ID:-fakecontainer}"; exit 0 ;;
  cp) exit 0 ;;
  stop) exit 0 ;;
  exec)
    if [[ "$*" == *aur-setup.sh* ]]; then exit 0; fi
    for last in "$@"; do :; done
    if [ -n "${FAKE_FAIL_MATCH:-}" ] && [[ "$last" == *"$FAKE_FAIL_MATCH"* ]]; then exit 7; fi
    case "$last" in
      *'-xf -'|'cat > '*) cat >/dev/null ;;
      *assert-provenance.sh*) cat "$FAKE_ASSERT" ;;
      *'/usr/bin/himmelctl uninstall'*)
        case "${FAKE_UNINSTALL:-ok}" in
          halt) echo '[uninstall-log] Halted at: [7/8] Claude marketplaces: uninstall-plugins.sh reported failures'; exit 2 ;;
          rc3) echo '[uninstall-log] boom'; exit 3 ;;
          early) echo '[uninstall-log] Halted at: [3/8] Claude settings: jq failed'; exit 2 ;;
        esac ;;
      *'[ -e /opt/himmel ]'*) echo gone; echo gone ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
cp "$FAKEBIN/docker" "$FAKEBIN/podman"
chmod +x "$FAKEBIN/VBoxManage" "$FAKEBIN/fakepy" "$FAKEBIN/ssh" "$FAKEBIN/docker" "$FAKEBIN/podman"

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
            *'sha256sum -c himmel-'*) echo tarball-extract ;;
            *seed-provenance.sh*) echo seed ;;
            *'inventory.sh A'*) echo invA ;;
            *'bin.js install'*'--scope project'*) echo install-project ;;
            *'bin.js install'*'--scope user'*) echo install-user ;;
            *'inventory.sh B'*) echo invB ;;
            'SSH rm -rf /tmp/rt-src') echo clone-gone-rm ;;
            *'bin.js uninstall'*|*'.local/bin/himmelctl uninstall'*) echo uninstall ;;
            *'inventory.sh C'*) echo invC ;;
            *assert-provenance.sh*) echo assert ;;
        esac
    done | tr '\n' ' '
}

# container_order <log> — the aur-mode twin of ssh_order: same steps, over
# DOCKER/PODMAN exec lines and the /usr/bin/himmelctl RUN_BIN, plus the aur-only
# pacman-remove tail step.
container_order() {
    grep -E '^(DOCKER|PODMAN) exec' "$1" | while IFS= read -r l; do
        case "$l" in
            *seed-provenance.sh*) echo seed ;;
            *'inventory.sh A'*) echo invA ;;
            *'himmelctl install'*'--scope project'*) echo install-project ;;
            *'himmelctl install'*'--scope user'*) echo install-user ;;
            *'inventory.sh B'*) echo invB ;;
            *'/usr/bin/himmelctl uninstall'*) echo uninstall ;;
            *'inventory.sh C'*) echo invC ;;
            *assert-provenance.sh*) echo assert ;;
            *'pacman -R'*) echo pacman-remove ;;
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
   && ! grep -qE 'HIMMEL_UNINSTALL_REAL_HOME[=]' "$SCRIPT"; then
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


# =====================================================================
# D16 — --clone-gone: the clone is rm -rf'd after inventory B, then uninstall
# runs through the PATH launcher (~/.local/bin/himmelctl), never `node
# <clone>/.../bin.js` — the clone is gone (HIMMEL-3312 S15)
# =====================================================================
run_rt "$ALL_PASS" f73a62f1 --clone-gone
want='stage seed invA install-project install-user invB clone-gone-rm uninstall invC assert '
got=$(ssh_order "$LOG")
un=$(grep '^SSH ' "$LOG" | grep 'himmelctl uninstall')
if [ "$got" = "$want" ] && [[ "$un" == *'/home/testuser/.local/bin/himmelctl uninstall --yes'* ]] \
   && ! grep '^SSH ' "$LOG" | grep -q 'bin.js uninstall'; then
    pass "D16 --clone-gone: rm -rf's the clone after inventory B, uninstall runs through the PATH launcher"
else
    fail_case "D16 clone-gone step order/launcher: got='$got' un='$un'"; dump
fi

# D16b — the marketplace-remove observation is printed verbatim, whatever it
# says, even when absent (the one unverified claim this slice exists to check)
FAKE_UNINSTALL=mkt run_rt "$ALL_PASS" f73a62f1 --clone-gone
if printf '%s\n' "$OUT" | grep -qxF '[marketplace-remove] [uninstall-log]   marketplace remove: rt-dir-marketplace'; then
    pass "D16b marketplace-remove line captured verbatim from the uninstall log"
else
    fail_case "D16b marketplace-remove capture"; dump
fi
run_rt "$ALL_PASS" f73a62f1 --clone-gone
if printf '%s\n' "$OUT" | grep -qxF '[marketplace-remove] no marketplace-related line observed in the uninstall log'; then
    pass "D16c marketplace-remove absence is its own reported observation, not a harness bug"
else
    fail_case "D16c marketplace-remove absence"; dump
fi
run_rt "$ALL_PASS" f73a62f1
if ! printf '%s\n' "$OUT" | grep -q '^\[marketplace-remove\]'; then
    pass "D16d without --clone-gone, no marketplace-remove line at all"
else
    fail_case "D16d marketplace-remove printed without --clone-gone"; dump
fi

# D16e — --clone-gone: uninstall must still run from $GHOME/proj (HIMMEL-3540).
# $SRC (the staged clone, rm -rf'd above) is not the adopter's project; the
# launcher may change (PATH vs node <clone>/bin.js) but the cwd must not.
run_rt "$ALL_PASS" f73a62f1 --clone-gone
un=$(grep '^SSH ' "$LOG" | grep 'himmelctl uninstall')
if [[ "$un" == 'SSH cd /home/testuser/proj &&'* ]]; then
    pass "D16e --clone-gone: uninstall runs from \$GHOME/proj, not \$GHOME"
else
    fail_case "D16e clone-gone uninstall cwd: un='$un'"; dump
fi

# =====================================================================
# D17 — --clone-gone --purge-state must leave nothing beyond baseline A's
# ~/.himmel/config.json (never the whole directory — config.json is the
# user's own file, untouched by design); the check runs AFTER invdiff/assert
# so a legitimate failure still preserves their output (console ruling,
# HIMMEL-3528, 2026-09-23)
# =====================================================================
FAKE_HIMMEL_CONTENTS=config run_rt "$ALL_PASS" f73a62f1 --clone-gone --purge-state
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF '[clone-gone-purge] ~/.himmel contents: /home/testuser/.himmel/config.json' \
   && [ "$(printf '%s\n' "$OUT" | grep -n '^\[step\] assert$' | head -n1 | cut -d: -f1)" -lt \
        "$(printf '%s\n' "$OUT" | grep -n '^\[clone-gone-purge\]' | head -n1 | cut -d: -f1)" ]; then
    pass "D17 clone-gone --purge-state: only baseline-A config.json left, checked after the assert step"
else
    fail_case "D17 clone-gone-purge pass case (config.json only): rc=$RC"; dump
fi

FAKE_HIMMEL_CONTENTS=empty run_rt "$ALL_PASS" f73a62f1 --clone-gone --purge-state
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF '[clone-gone-purge] ~/.himmel contents: (empty)'; then
    pass "D17a clone-gone --purge-state: ~/.himmel fully gone also passes (nothing beyond A, vacuously)"
else
    fail_case "D17a clone-gone-purge pass case (empty): rc=$RC"; dump
fi

FAKE_HIMMEL_CONTENTS=extra run_rt "$ALL_PASS" f73a62f1 --clone-gone --purge-state
if [ "$RC" -eq 2 ] \
   && printf '%s\n' "$OUT" | grep -qxF '[clone-gone-purge] ~/.himmel contents: /home/testuser/.himmel/config.json /home/testuser/.himmel/uninstall /home/testuser/.himmel/uninstall/bundle.json' \
   && printf '%s\n' "$OUT" | grep -q 'clone-gone --purge-state left unexpected ~/.himmel content:.*uninstall' \
   && printf '%s\n' "$OUT" | grep -q '^\[step\] assert$' \
   && printf '%s\n' "$OUT" | grep -q '^CHECK '; then
    pass "D17b clone-gone-purge failure (rc 2) names the unexpected paths and still preserves the invdiff/assert diagnostic output"
else
    fail_case "D17b clone-gone-purge fail case: rc=$RC"; dump
fi

# D17c — plain --clone-gone (no --purge-state) never runs the purge check
run_rt "$ALL_PASS" f73a62f1 --clone-gone
if ! printf '%s\n' "$OUT" | grep -q '^\[clone-gone-purge\]'; then
    pass "D17c --clone-gone without --purge-state: no clone-gone-purge check"
else
    fail_case "D17c clone-gone-purge ran without --purge-state"; dump
fi

# D17d — the clone-gone-purge listing follows a symlinked ~/.himmel (plain
# `find` does not descend into a symlink start-point, so a leftover symlink
# would list empty and pass silently; codex-1, HIMMEL-3528 panel round 1)
FAKE_HIMMEL_CONTENTS=config run_rt "$ALL_PASS" f73a62f1 --clone-gone --purge-state
if grep -q '^SSH .*find -L .*\.himmel -mindepth 1' "$LOG"; then
    pass "D17d clone-gone-purge listing uses find -L (traverses a symlinked ~/.himmel)"
else
    fail_case "D17d clone-gone-purge listing did not use find -L"; dump
fi

# =====================================================================
# D18 — HIMMEL-3059 S6: --install-from clone|tarball|aur
# =====================================================================
# D18 — a bad --install-from value is a usage error, rc 2, before VBoxManage
run_rt "$BOTH" f73a62f1 --install-from bogus
if [ "$RC" -eq 2 ] && [ ! -s "$LOG" ]; then
    pass "D18 bad --install-from value exits 2 before touching VBoxManage"
else
    fail_case "D18 bad --install-from: rc=$RC"; dump
fi

# D18b — aur: no container runtime answers refuses (its own rc 3), only
# `info` was probed (docker then podman), nothing else ran
FAKE_RUNTIME_NO_INFO=1 run_rt "$BOTH" f73a62f1 --install-from aur
if [ "$RC" -eq 3 ] && [ "$(grep -cE '^(DOCKER|PODMAN) info$' "$LOG")" -eq 2 ] \
   && ! grep -qE '^(DOCKER|PODMAN) (run|exec|cp|stop)' "$LOG" \
   && ! grep -q '^VBOX ' "$LOG" \
   && printf '%s\n' "$OUT" | grep -qF 'no container runtime answers'; then
    pass "D18b aur: no container runtime answers refuses (rc=3) after probing docker then podman info, nothing else runs"
else
    fail_case "D18b aur no-runtime refusal: rc=$RC"; dump
fi

# D18b2 — aur + --clone-gone is refused (rc 2) before any runtime is probed:
# aur mode never stages a clone, so there is nothing for --clone-gone to remove
run_rt "$BOTH" f73a62f1 --install-from aur --clone-gone
if [ "$RC" -eq 2 ] && [ ! -s "$LOG" ] \
   && printf '%s\n' "$OUT" | grep -qF -- '--clone-gone is not supported with --install-from aur'; then
    pass "D18b2 aur + --clone-gone refuses (rc=2) before touching any runtime"
else
    fail_case "D18b2 aur clone-gone: rc=$RC"; dump
fi

# D18c — clone stays the default and byte-for-byte unaffected: same guest step
# order as D1, and the [run] line now names it
run_rt "$ALL_PASS" f73a62f1
got=$(ssh_order "$LOG")
if printf '%s\n' "$OUT" | grep -qE '^\[run\] .*install-from=clone ' \
   && [ "$got" = 'stage seed invA install-project install-user invB uninstall invC assert ' ]; then
    pass "D18c default --install-from is clone; guest step order unchanged: $got"
else
    fail_case "D18c clone default: order='$got'"; dump
fi

# D18d — --install-from tarball: runs the REAL build-tarball.sh (HIMMEL_RT_TARBALL_NO_BUILD=1
# skips only its npm build, a hermetic-test seam — see provenance-roundtrip.sh),
# stages the built asset instead of the source tree (no stage/git-init step),
# and every guest install/uninstall argv targets the extracted
# ~/.local/share/himmel/current tree instead of /tmp/rt-src.
HIMMEL_RT_TARBALL_NO_BUILD=1 run_rt "$ALL_PASS" f73a62f1 --install-from tarball
got=$(ssh_order "$LOG")
want='tarball-extract seed invA install-project install-user invB uninstall invC assert '
bin_ok=0
if [ "$(grep '^SSH ' "$LOG" | grep -c '\.local/share/himmel/current/scripts/himmelctl/bin\.js install')" -eq 2 ] \
   && grep '^SSH ' "$LOG" | grep -q '\.local/share/himmel/current/scripts/himmelctl/bin\.js uninstall'; then
    bin_ok=1
fi
if [ "$RC" -eq 0 ] && [ "$got" = "$want" ] && [ "$bin_ok" -eq 1 ] \
   && printf '%s\n' "$OUT" | grep -qE '^\[run\] .*install-from=tarball ' \
   && printf '%s\n' "$OUT" | grep -qxF '[step] build-tarball' \
   && printf '%s\n' "$OUT" | grep -qE '^asset: .*himmel-0\.0\.0-rt[0-9a-f]+-linux\.tar\.gz$'; then
    pass "D18d --install-from tarball: real build-tarball.sh ran, guest installs from the extracted ~/.local/share/himmel/current tree, no stage/git-init: $got"
else
    fail_case "D18d tarball mode: rc=$RC order='$got' bin_ok=$bin_ok"; dump
fi

# =====================================================================
# D19 — --install-from aur: the full round trip, hermetically, through a
# fake docker (HIMMEL-3059 S6b). AUR_REF is f8ef4333 (post-S5), the first
# commit on main carrying packaging/aur/{PKGBUILD,himmel.install} — f73a62f1
# predates S5 and has neither file, so it cannot exercise this mode.
# =====================================================================
AUR_REF=f8ef4333e3f0e03bc540da932a09a3eb84696d67
HIMMEL_RT_TARBALL_NO_BUILD=1 run_rt "$ALL_PASS" "$AUR_REF" --install-from aur
got=$(container_order "$LOG")
want='seed invA install-project install-user invB uninstall invC assert pacman-remove '
if [ "$RC" -eq 0 ] && [ "$got" = "$want" ] \
   && printf '%s\n' "$OUT" | grep -qE '^\[run\] .*install-from=aur .*runtime=docker image=archlinux:base-devel guest-user=builder$' \
   && printf '%s\n' "$OUT" | grep -qxF '[step] container-boot runtime=docker image=archlinux:base-devel' \
   && printf '%s\n' "$OUT" | grep -qxF '[step] container-setup' \
   && printf '%s\n' "$OUT" | grep -qxF '[step] makepkg' \
   && printf '%s\n' "$OUT" | grep -qE '^asset: .*himmel-0\.0\.0-rt[0-9a-f]+-linux\.tar\.gz$' \
   && printf '%s\n' "$OUT" | grep -qxF '[pacman-payload] /opt/himmel=gone /usr/bin/himmelctl=gone'; then
    pass "D19 --install-from aur: full hermetic round trip through the container, guest steps in order: $got"
else
    fail_case "D19 aur hermetic green: rc=$RC order='$got'"; dump
fi

# D19b — podman is tried only when docker's `info` refuses (autodetect order)
FAKE_DOCKER_ONLY_FAIL=1 HIMMEL_RT_TARBALL_NO_BUILD=1 run_rt "$ALL_PASS" "$AUR_REF" --install-from aur
if printf '%s\n' "$OUT" | grep -qE '^\[run\] .*runtime=podman '; then
    pass "D19b docker refusing 'info' falls back to podman"
else
    fail_case "D19b docker->podman fallback"; dump
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILED FAILED"; exit 1
