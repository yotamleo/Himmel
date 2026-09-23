#!/usr/bin/env bash
# provenance-roundtrip.sh — the install-provenance VM acceptance harness
# (HIMMEL-3332 S9b). Installs a himmel ref into a freshly restored guest over a
# pre-seeded user environment, uninstalls it, and checks that uninstall took
# away exactly what install brought: nothing of the user's (too much) and
# nothing of himmel's (too little).
#
# STATION-ONLY: never run from CI. It needs VirtualBox, the ubuntu_new source
# VM and the suite-ready-v4 snapshot on the station; CI never discovers it
# (not a test-*.sh), and its hermetic twin, test-provenance-roundtrip-dry.sh,
# is the part CI runs.
#
# Usage: scripts/vm/provenance-roundtrip.sh <branch|sha> [--expect-red]
#            [--profile core|all] [--purge-state] [--clone-gone]
#   --expect-red   pass only when BOTH directions fail (the pre-fix RED); any
#                  missing direction prints `RED incomplete: <dir> direction missing`
#   --profile      the install profile (default core). `all` also arms the
#                  pipeline, qmd and graphmap cadences: the seed step then puts
#                  user-owned qmd/graphify stubs on the guest PATH (the arms
#                  need an executable) and the run asserts install armed a
#                  crontab line, so the cadence-crontab-removed direction is
#                  observable (HIMMEL-3351)
#   --purge-state  uninstall with --purge-state (the spec's second variant)
#   --clone-gone   after install, `rm -rf` the staged clone on the guest, then
#                  run `himmelctl uninstall` through the PATH launcher
#                  (~/.local/bin/himmelctl) instead of `node <clone>/…/bin.js`
#                  (HIMMEL-3312 S15). Verifies the standalone bundle/launcher
#                  fallback and what `claude plugin marketplace remove` does
#                  for a directory marketplace whose directory is gone; that
#                  step's observed output is printed on a `[marketplace-remove]`
#                  line. Combined with --purge-state, the run also asserts
#                  no `~/.himmel` is left.
# Exit: 0 green (or, with --expect-red, RED complete); 1 a FAIL (or RED
# incomplete); 2 usage, a refused VM precondition or a failed harness step.
#
# Steps, all inside the guest (a himmel-ar-N linked clone, restored to its
# snapshot first): stage the ref's tree to /tmp/rt-src; seed the user
# environment, incl. the telegram + bridge state --purge-state removes
# (lib/seed-provenance.sh); inventory A; `env -i` install from
# ~/proj with --scope project, then --scope user; inventory B (+ a copy of the
# ledger and the crontab); uninstall; inventory C; the named checks (lib/assert-provenance.sh).
# The verdict is computed HERE from the guest's `CHECK <group> <direction>
# <PASS|FAIL|SKIP> <name> — <detail>` lines.
#
# The uninstall step runs `himmelctl uninstall --yes`, not a bare
# `scripts/uninstall.sh --yes`: the seeded ~/.claude.json is a real-HOME marker
# for uninstall.sh's wet-run fence, and himmelctl is the operator path that
# lifts it. This harness never sets that variable itself.
#
# The guest HOME is the only HOME touched; the station's $HOME is never
# written. The VM env knobs are after-report.sh's (HIMMEL_VM_AR_*,
# VBOXMANAGE_PATH, HIMMEL_VM_PYTHON, HIMMEL_VM_LOCK_*); see docs/setup/vms.md.
set -uo pipefail
# shellcheck disable=SC2029 # deliberate: guest commands are built client-side.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
    echo "usage: scripts/vm/provenance-roundtrip.sh <branch|sha> [--expect-red] [--profile core|all] [--purge-state] [--clone-gone]" >&2
    exit 2
}

REF="" EXPECT_RED=0 PROFILE=core PURGE=0 CLONE_GONE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --expect-red) EXPECT_RED=1; shift ;;
        --purge-state) PURGE=1; shift ;;
        --clone-gone) CLONE_GONE=1; shift ;;
        --profile)
            case "${2:-}" in core|all) PROFILE="$2" ;; *) usage ;; esac
            shift 2 ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$REF" ] || usage; REF="$1"; shift ;;
    esac
done
[ -n "$REF" ] || usage

fail() {
    echo "ERROR: provenance-roundtrip: $1" >&2
    exit 2
}

# The ref is resolved BEFORE anything touches VirtualBox.
SHA=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$REF^{commit}") \
    || fail "cannot resolve '$REF' to a commit in $REPO_ROOT"

# shellcheck source=scripts/vm/port-alloc.sh
. "$REPO_ROOT/scripts/vm/port-alloc.sh"
# shellcheck source=scripts/vm/lib/vm-clone.sh
. "$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
# The stage excludes come from THIS tree, never from the staged ref's.
# shellcheck source=scripts/lib/vm-guest-excludes.sh
. "$REPO_ROOT/scripts/lib/vm-guest-excludes.sh"

vm_env_init
# shellcheck source=scripts/vm/vm-lock.sh
. "$REPO_ROOT/scripts/vm/vm-lock.sh"

SOURCE_VM="${HIMMEL_VM_AR_SOURCE_VM:-ubuntu_new}"
SNAPSHOT="${HIMMEL_VM_AR_SNAPSHOT:-suite-ready-v4}"
if [ -n "${HIMMEL_VM_AR_GUEST_USER:-}" ]; then
    GUEST_USER="$HIMMEL_VM_AR_GUEST_USER"
else
    GUEST_USER=$("$HIMMEL_VM_PYTHON" -c '
import json, sys
u = json.load(open(sys.argv[1])).get(sys.argv[2], {}).get("user")
sys.exit(1) if not u else print(u)
' "$REPO_ROOT/scripts/lib/vms.json" "$SOURCE_VM" 2>/dev/null) \
        || fail "no 'user' for '$SOURCE_VM' in scripts/lib/vms.json"
fi
case "$GUEST_USER" in ''|*[!A-Za-z0-9._-]*) fail "invalid guest user '$GUEST_USER'" ;; esac
GHOME="/home/$GUEST_USER"
SRC=/tmp/rt-src
WORKDIR=/tmp/rt-work
BIN="$SRC/scripts/himmelctl/bin.js"

# The exact environment every install and the uninstall run under (HIMMEL-3321:
# printed, then passed — the printed line IS the argv).
INSTALL_ENV=(HOME="$GHOME" PATH="$GHOME/.local/bin:/usr/local/bin:/usr/bin:/bin" HIMMELCTL_CACHE_DIR="$GHOME/.claude/himmel")
ENV_CMD="env -i ${INSTALL_ENV[*]}"

HOST_TMP=""
LOCKED=0
# shellcheck disable=SC2317,SC2329 # invoked via `trap cleanup EXIT`
cleanup() {
    local rc=$? off_rc=0 res_rc=0
    if [ "$LOCKED" = 1 ]; then
        vbox_py '
try:
    vbox.power_off(sys.argv[1])
except Exception as e:
    print(f"WARN: power_off {sys.argv[1]} failed: {e}", file=sys.stderr)
    sys.exit(1)
' "$CLONE_NAME" >&2 || off_rc=$?
        # Leave the slot at its clean baseline, whatever the run did to it.
        vbox_py 'vbox.restore_snapshot(sys.argv[1], sys.argv[2])' "$CLONE_NAME" "$SNAPSHOT" >&2 || res_rc=$?
        vm_lock_release "$CLONE_NAME"
        vm_lock_release "himmel-vm-registry"
        if [ "$off_rc" -eq 0 ] && [ "$res_rc" -eq 0 ]; then
            echo "[cleanup] $CLONE_NAME powered off, restored to $SNAPSHOT, vm-lock released"
        else
            echo "[cleanup] WARN $CLONE_NAME power_off rc=$off_rc restore rc=$res_rc; vm-lock released" >&2
            [ "$rc" -ne 0 ] || rc=2
        fi
    fi
    vm_slot_release
    [ -z "$HOST_TMP" ] || rm -rf "$HOST_TMP"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

vm_slot_acquire
vm_lock_acquire_waiting "$CLONE_NAME"
case $? in
    0) LOCKED=1 ;;
    5) fail "timed out waiting for the vm-lock on '$CLONE_NAME'" ;;
    *) fail "could not acquire the vm-lock on '$CLONE_NAME'" ;;
esac

echo "[run] ref=$REF sha=$SHA profile=$PROFILE purge-state=$PURGE clone-gone=$CLONE_GONE expect-red=$EXPECT_RED clone=$CLONE_NAME snapshot=$SNAPSHOT guest-user=$GUEST_USER"
vm_clone_ensure "$SNAPSHOT"
vm_restore "$SNAPSHOT"
vm_boot

# step <name> <guest-command> — one guest step; any failure ends the run (rc 2).
step() {
    local name="$1" rc
    echo "[step] $name"
    vm_ssh "$2"
    rc=$?
    [ "$rc" -eq 0 ] || fail "step $name failed (rc=$rc)"
}

# 1. Stage the ref's tree (git archive: tracked files only) + the helpers.
HOST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rt-src.XXXXXX") || fail "mktemp failed"
git -C "$REPO_ROOT" archive "$SHA" | tar -x -C "$HOST_TMP" || fail "git archive $SHA failed"
TOP=()
while IFS= read -r f; do TOP+=("$f"); done < <(ls -A "$HOST_TMP")
echo "[step] stage"
rsync_e="ssh -i ${HIMMEL_VM_AR_SSH_KEY:-$HOME/.ssh/id_ed25519} -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
vm_stage_tree "$HOST_TMP" "$SRC" vm_ssh "$rsync_e" "$GUEST_USER@127.0.0.1" "${TOP[@]}" || fail "step stage failed"
step git-init "cd $SRC && git init -q && git add -A && git -c user.name=rt -c user.email=rt@invalid commit -qm 'rt $SHA'"
echo "[step] helpers"
tar -C "$REPO_ROOT/scripts/vm/lib" -cf - seed-provenance.sh assert-provenance.sh inventory.sh invdiff.py \
    | vm_ssh "rm -rf $WORKDIR && mkdir -p $WORKDIR && tar -C $WORKDIR -xf -" || fail "step helpers failed"

# 2-3. Seed, inventory A.
step seed "HIMMEL_RT_GUEST=1 RT_PROFILE=$PROFILE bash $WORKDIR/seed-provenance.sh"
step inventory-A "bash $WORKDIR/inventory.sh A"

# 4. Install, project scope then user scope, under the printed env.
# `--profile all` has no flag at this CLI: its profile is DERIVED on the guest
# from the shipped adopter-<scope> profile by one jq overlay (a vault, so
# adopt.sh runs --profile all, and the three cadences armed) — derived, never
# a committed copy, so it cannot drift from the shipped file.
# shellcheck disable=SC2016 # $v is jq's, bound by --arg on the guest
OVERLAY='.vault = {mode: "default-template", path: $v} | .cadences = {pipeline: "armed", qmd: "armed", graphmap: "armed"}'
if [ "$PROFILE" = all ]; then
    echo "[overlay] jq --arg v $GHOME/luna '$OVERLAY' $SRC/docs/setup/profiles/adopter-<scope>.install-profile.json"
    for scope in project user; do
        step "profile-$scope" "jq --arg v $GHOME/luna '$OVERLAY' $SRC/docs/setup/profiles/adopter-$scope.install-profile.json >$WORKDIR/profile-all-$scope.json"
    done
fi
echo "[env] $ENV_CMD"
for scope in project user; do
    INSTALL_ARGS=""
    [ "$PROFILE" != all ] || INSTALL_ARGS="--from-profile $WORKDIR/profile-all-$scope.json"
    # `install` takes no --profile/--yes (spec §11 step 4 says so; the CLI does
    # not): `--scope` alone is the non-interactive adopter path, whose shipped
    # profile (starter, vault none) maps to adopt.sh --profile core.
    INSTALL_CMD="cd $GHOME/proj && $ENV_CMD node $BIN install ${INSTALL_ARGS:+$INSTALL_ARGS }--scope $scope >$WORKDIR/install-$scope.log 2>&1; rc=\$?; sed 's/^/[install-$scope-log] /' $WORKDIR/install-$scope.log; exit \$rc"
    step "install-$scope" "$INSTALL_CMD"
done

# 5. Inventory B + the ledger and the crontab as they stood after install.
step inventory-B "bash $WORKDIR/inventory.sh B && { L=\${HIMMEL_PROVENANCE_DIR:-$GHOME/.himmel}/provenance.jsonl; [ ! -f \$L ] || cp \$L $WORKDIR/ledger-B.jsonl; } && { crontab -l >$WORKDIR/crontab-B.txt 2>/dev/null; true; }"

# 5b. --clone-gone: delete the staged clone on the guest so the uninstall
# below has no source tree to fall back on (HIMMEL-3312 S15).
[ "$CLONE_GONE" = 0 ] || step clone-gone-rm "rm -rf $SRC"

# 6. Uninstall. --clone-gone runs it through the PATH launcher
# (~/.local/bin/himmelctl) rather than `node <clone>/…/bin.js`, since the
# clone is gone: this is the launcher-fallback / standalone-bundle path
# S13 added.
UNINSTALL_FLAGS="--yes"
[ "$PURGE" = 0 ] || UNINSTALL_FLAGS="--yes --purge-state"
if [ "$CLONE_GONE" = 1 ]; then
    UNINSTALL_ENTRY="$GHOME/.local/bin/himmelctl"
    UNINSTALL_CD="cd $GHOME"
else
    UNINSTALL_ENTRY="node $BIN"
    UNINSTALL_CD="cd $GHOME/proj"
fi
# A non-zero uninstall is itself a result (console ruling): record its rc and
# the step it halted at, then take inventory C anyway.
echo "[step] uninstall"
UN_OUT=$(vm_ssh "$UNINSTALL_CD && $ENV_CMD $UNINSTALL_ENTRY uninstall $UNINSTALL_FLAGS >$WORKDIR/uninstall.log 2>&1; rc=\$?; sed 's/^/[uninstall-log] /' $WORKDIR/uninstall.log; exit \$rc")
UN_RC=$?
printf '%s\n' "$UN_OUT"
# "Halted at: [7/8] ..." -> 7; empty when the uninstall ran every step.
HALT_N=$(printf '%s\n' "$UN_OUT" | sed -n 's/^\[uninstall-log\] Halted at: \[\([0-9]*\)\/[0-9]*\].*/\1/p' | head -n 1)
[ "$UN_RC" -eq 0 ] || [ -n "$HALT_N" ] || fail "step uninstall failed (rc=$UN_RC) with no 'Halted at:' line"
# owner() below resolves only [8/8] and the launchers after it, so a halt
# before [7/8] would count leftovers of unexecuted steps as pre-halt.
[ -z "$HALT_N" ] || [ "$HALT_N" -ge 7 ] || fail "uninstall halted at [$HALT_N/8]; the pre/post-halt owner map only resolves halts at [7/8] or later"
HALT_AT=none
[ -z "$HALT_N" ] || HALT_AT="[$HALT_N/8]"
echo "uninstall-exit rc=$UN_RC halted-at=$HALT_AT"

# 6b. --clone-gone: the observed rc/output of `claude plugin marketplace
# remove` for the gone directory marketplace — the one unverified claim this
# slice exists to check. Reported verbatim, on its own harness line, whatever
# it says: uninstall-plugins.sh does not always echo a per-command rc, so an
# absent rc here is itself an observation, not a harness bug.
if [ "$CLONE_GONE" = 1 ]; then
    MKT_LINES=$(printf '%s\n' "$UN_OUT" | grep -i 'marketplace' || true)
    if [ -n "$MKT_LINES" ]; then
        printf '[marketplace-remove] %s\n' "$MKT_LINES"
    else
        echo "[marketplace-remove] no marketplace-related line observed in the uninstall log"
    fi
fi

# 7. Inventory C, the diff summaries, the named checks.
step inventory-C "bash $WORKDIR/inventory.sh C"

echo "[step] invdiff"
vm_ssh "INVDIFF_BASE=/tmp python3 $WORKDIR/invdiff.py A B | grep '^###'; INVDIFF_BASE=/tmp python3 $WORKDIR/invdiff.py A C | grep '^###'" || true
echo "[step] assert"
ASSERT_OUT=$(vm_ssh "HIMMEL_RT_GUEST=1 RT_PURGE=$PURGE RT_PROFILE=$PROFILE bash $WORKDIR/assert-provenance.sh") \
    || fail "step assert failed (rc=$?)"
printf '%s\n' "$ASSERT_OUT"

# 7b. --clone-gone --purge-state must leave no ~/.himmel (design §5.2/§4: the
# bundle is removed last, as the final statement of the purge). Runs AFTER
# invdiff/assert so a legitimate failure here still preserves their diagnostic
# output in the captured run log.
if [ "$CLONE_GONE" = 1 ] && [ "$PURGE" = 1 ]; then
    HIMMEL_LEFT=$(vm_ssh "test -e $GHOME/.himmel -o -L $GHOME/.himmel && echo PRESENT || echo ABSENT")
    echo "[clone-gone-purge] ~/.himmel: $HIMMEL_LEFT"
    [ "$HIMMEL_LEFT" = ABSENT ] || fail "clone-gone --purge-state left $GHOME/.himmel behind"
fi

# 8. The verdict.
# owner <check-id> — the uninstall step whose removal the check observes:
# [8/8] removes ~/.claude/himmel, and himmelctl drops its PATH launchers only
# after a clean teardown (9 = after [8/8]); every other check is a step <= 6.
owner() {
    case "$1" in
        claude-himmel-dir-removed | 'left:~/.claude/himmel' | 'left:~/.claude/himmel/'*) echo 8 ;;
        himmelctl-gone | launcher-removed | 'left:~/.local/bin/himmelctl'*) echo 9 ;;
        *) echo 0 ;;
    esac
}
# phase <check-id> — post-halt when the owning step never ran (console ruling:
# a witness left only because steps after the halt did not run).
phase() {
    if [ -n "$HALT_N" ] && [ "$(owner "$1")" -gt "$HALT_N" ]; then echo post-halt; else echo pre-halt; fi
}
PHASED=$(printf '%s\n' "$ASSERT_OUT" | grep -E '^CHECK [^ ]+ [^ ]+ FAIL ' | while read -r _ _ d _ id _; do
    echo "$(phase "$id") $d $id"
done)
[ -z "$HALT_N" ] || printf '%s\n' "$PHASED" | grep '^post-halt ' | sed 's/^/[halt] /'
count() { printf '%s\n' "$PHASED" | grep -c "^pre-halt $1 " ; }
TOTAL=$(printf '%s\n' "$ASSERT_OUT" | grep -c '^CHECK ')
[ "$TOTAL" -gt 0 ] || fail "the guest reported no CHECK lines"
MUCH=$(count too-much) LITTLE=$(count too-little)
FAILS=$(printf '%s\n' "$ASSERT_OUT" | grep -cE '^CHECK [^ ]+ [^ ]+ FAIL ')
# Every reported direction is tagged with the variant it came from: the plain
# and the --purge-state uninstall remove different state (spec §11 runs both).
VARIANT="profile=$PROFILE uninstall=$([ "$PURGE" = 1 ] && echo purge-state || echo plain)"
echo "[summary] variant=($VARIANT) checks=$TOTAL fail=$FAILS pre-halt too-much=$MUCH too-little=$LITTLE identity=$(count identity) ledger=$(count ledger) post-halt=$(printf '%s\n' "$PHASED" | grep -c '^post-halt ') uninstall-rc=$UN_RC"

if [ "$EXPECT_RED" = 1 ]; then
    # The spec's predicted witnesses — informational: a missing one is reported,
    # the exit code rests on the two directions.
    witness="context7-enabled user-statusline handover-dir hud-config worktree-sh hud-allow-extra-cmd-removed"
    for w in $witness; do
        if grep -qE "^CHECK [^ ]+ [^ ]+ FAIL $w " <<<"$ASSERT_OUT"; then
            echo "[witness] ($VARIANT) $w FAIL $(phase "$w") (predicted)"
        else
            echo "[witness] ($VARIANT) $w did not fail (predicted to)"
        fi
    done
    if [ "$MUCH" -gt 0 ] && [ "$LITTLE" -gt 0 ]; then
        echo "RED complete: too-much=$MUCH too-little=$LITTLE variant=($VARIANT)"
        exit 0
    fi
    [ "$MUCH" -gt 0 ] || echo "RED incomplete: too-much direction missing"
    [ "$LITTLE" -gt 0 ] || echo "RED incomplete: too-little direction missing"
    echo "[variant] $VARIANT"
    exit 1
fi
if [ "$FAILS" -eq 0 ]; then
    echo "RESULT: GREEN ($TOTAL checks)"
    exit 0
fi
echo "RESULT: FAIL ($FAILS of $TOTAL checks)"
exit 1
