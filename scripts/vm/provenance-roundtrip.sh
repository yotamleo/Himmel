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
#            [--install-from clone|tarball|aur] [--runtime docker|podman] [--image <ref>]
#   --expect-red   pass only when BOTH directions fail (the pre-fix RED); any
#                  missing direction prints `RED incomplete: <dir> direction missing`
#   --install-from clone (default) stages the ref's tree and installs from it,
#                  byte-for-byte the pre-S6 behaviour. `tarball` builds the
#                  release tarball for this ref via scripts/release/build-tarball.sh,
#                  stages the two assets, then installs on the guest via the
#                  README recipe (sha256 verify, extract into the versioned
#                  dir + `current`), before running the same install/uninstall/
#                  assert chain (HIMMEL-3059 S6). `aur` (HIMMEL-3059 S6b, console
#                  ruling 2026-09-24) builds the same release tarball, then packages
#                  and installs it via the REAL PKGBUILD in an archlinux:base-devel
#                  container (docker or podman — no VM, pacman is Arch-only and
#                  no Arch VM exists in vms.json): makepkg -si installs
#                  /opt/himmel + /usr/bin/himmelctl owned by pacman, then the same
#                  seed/install/uninstall/assert chain runs as a non-root
#                  container user, then `pacman -R himmel` removes the payload.
#                  --runtime/--image only apply to this mode (default: autodetect
#                  docker then podman, image archlinux:base-devel).
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
    echo "usage: scripts/vm/provenance-roundtrip.sh <branch|sha> [--expect-red] [--profile core|all] [--purge-state] [--clone-gone] [--install-from clone|tarball|aur] [--runtime docker|podman] [--image <ref>]" >&2
    exit 2
}

REF="" EXPECT_RED=0 PROFILE=core PURGE=0 CLONE_GONE=0 INSTALL_FROM=clone RUNTIME_OPT="" IMAGE_OPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --expect-red) EXPECT_RED=1; shift ;;
        --purge-state) PURGE=1; shift ;;
        --clone-gone) CLONE_GONE=1; shift ;;
        --profile)
            case "${2:-}" in core|all) PROFILE="$2" ;; *) usage ;; esac
            shift 2 ;;
        --install-from)
            case "${2:-}" in clone|tarball|aur) INSTALL_FROM="$2" ;; *) usage ;; esac
            shift 2 ;;
        --runtime)
            case "${2:-}" in docker|podman) RUNTIME_OPT="$2" ;; *) usage ;; esac
            shift 2 ;;
        --image)
            [ -n "${2:-}" ] || usage; IMAGE_OPT="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$REF" ] || usage; REF="$1"; shift ;;
    esac
done
[ -n "$REF" ] || usage
# --runtime/--image only mean anything for the container backend.
[ "$INSTALL_FROM" = aur ] || { [ -z "$RUNTIME_OPT" ] && [ -z "$IMAGE_OPT" ]; } || usage

fail() {
    echo "ERROR: provenance-roundtrip: $1" >&2
    exit 2
}

# aur mode never stages a clone tree, so --clone-gone (which deletes one) is
# not a meaningful combination.
[ "$INSTALL_FROM" != aur ] || [ "$CLONE_GONE" = 0 ] || fail "--clone-gone is not supported with --install-from aur"

RUNTIME="" IMAGE="${IMAGE_OPT:-archlinux:base-devel}"
if [ "$INSTALL_FROM" = aur ]; then
    # No Arch VM exists (scripts/lib/vms.json lists ubuntu_new/win11_base_himmel/
    # win2 only) and pacman is Arch-only, so this mode never touches VirtualBox:
    # refuse before resolving the ref at all if no runtime answers, same
    # posture as a usage error, but its own exit code (3) since it is neither
    # a usage mistake nor a harness-step failure.
    pick_runtime() {
        local r
        if [ -n "$RUNTIME_OPT" ]; then
            command -v "$RUNTIME_OPT" >/dev/null 2>&1 && "$RUNTIME_OPT" info >/dev/null 2>&1 && { echo "$RUNTIME_OPT"; return 0; }
            return 1
        fi
        for r in docker podman; do
            command -v "$r" >/dev/null 2>&1 && "$r" info >/dev/null 2>&1 && { echo "$r"; return 0; }
        done
        return 1
    }
    RUNTIME=$(pick_runtime) || { echo "ERROR: provenance-roundtrip: --install-from aur: no container runtime answers ('docker info'/'podman info'); pass --runtime or start one" >&2; exit 3; }
fi

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

[ "$INSTALL_FROM" = aur ] || vm_env_init
# shellcheck source=scripts/vm/vm-lock.sh
. "$REPO_ROOT/scripts/vm/vm-lock.sh"

if [ "$INSTALL_FROM" = aur ]; then
    # The guest is the container's own non-root user, a fixed identity
    # independent of any VM or vms.json lookup.
    GUEST_USER=builder
else
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
fi
case "$GUEST_USER" in ''|*[!A-Za-z0-9._-]*) fail "invalid guest user '$GUEST_USER'" ;; esac
GHOME="/home/$GUEST_USER"
SRC=/tmp/rt-src
WORKDIR=/tmp/rt-work
TARBALL_STAGE=/tmp/rt-tarball
SHARE_HIMMEL="$GHOME/.local/share/himmel"
case "$INSTALL_FROM" in
    clone)   RUN_BIN="node $SRC/scripts/himmelctl/bin.js"; INSTALLED_ROOT="$SRC" ;;
    tarball) RUN_BIN="node $SHARE_HIMMEL/current/scripts/himmelctl/bin.js"; INSTALLED_ROOT="$SHARE_HIMMEL/current" ;;
    aur)     RUN_BIN="/usr/bin/himmelctl"; INSTALLED_ROOT="/opt/himmel" ;;
esac

# The exact environment every install and the uninstall run under (HIMMEL-3321:
# printed, then passed — the printed line IS the argv).
INSTALL_ENV=(HOME="$GHOME" PATH="$GHOME/.local/bin:/usr/local/bin:/usr/bin:/bin" HIMMELCTL_CACHE_DIR="$GHOME/.claude/himmel")
ENV_CMD="env -i ${INSTALL_ENV[*]}"

HOST_TMP=""
LOCKED=0
CONTAINER=""
TARBALL_OUT=""
# shellcheck disable=SC2317,SC2329 # invoked via `trap cleanup EXIT`
cleanup() {
    local rc=$?
    if [ "$INSTALL_FROM" = aur ]; then
        [ -z "$CONTAINER" ] || "$RUNTIME" stop -t 5 "$CONTAINER" >&2 2>/dev/null || true
        [ -z "$HOST_TMP" ] || rm -rf "$HOST_TMP"
        [ -z "$TARBALL_OUT" ] || rm -rf "$TARBALL_OUT"
        exit "$rc"
    fi
    local off_rc=0 res_rc=0
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

if [ "$INSTALL_FROM" = aur ]; then
    echo "[run] ref=$REF sha=$SHA install-from=$INSTALL_FROM profile=$PROFILE purge-state=$PURGE expect-red=$EXPECT_RED runtime=$RUNTIME image=$IMAGE guest-user=$GUEST_USER"
else
    vm_slot_acquire
    vm_lock_acquire_waiting "$CLONE_NAME"
    case $? in
        0) LOCKED=1 ;;
        5) fail "timed out waiting for the vm-lock on '$CLONE_NAME'" ;;
        *) fail "could not acquire the vm-lock on '$CLONE_NAME'" ;;
    esac

    echo "[run] ref=$REF sha=$SHA install-from=$INSTALL_FROM profile=$PROFILE purge-state=$PURGE clone-gone=$CLONE_GONE expect-red=$EXPECT_RED clone=$CLONE_NAME snapshot=$SNAPSHOT guest-user=$GUEST_USER"
    vm_clone_ensure "$SNAPSHOT"
    vm_restore "$SNAPSHOT"
    vm_boot
fi

# aur_ssh <cmd> — run one command in the container as the non-root builder
# user, stdin forwarded (-i) so a tar pipe works the same way vm_ssh's does.
aur_ssh() { "$RUNTIME" exec -i -u "$GUEST_USER" -w "$GHOME" -e HOME="$GHOME" "$CONTAINER" bash -c "$1"; }
# guest_ssh <cmd> — the one guest dispatch point every mode's steps use:
# aur's container exec, or the existing VM's vm_ssh, byte-identical to before.
guest_ssh() { if [ "$INSTALL_FROM" = aur ]; then aur_ssh "$1"; else vm_ssh "$1"; fi; }

# step <name> <guest-command> — one guest step; any failure ends the run (rc 2).
step() {
    local name="$1" rc
    echo "[step] $name"
    guest_ssh "$2"
    rc=$?
    [ "$rc" -eq 0 ] || fail "step $name failed (rc=$rc)"
}

# 1. Stage the ref's tree (git archive: tracked files only) + the helpers.
HOST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rt-src.XXXXXX") || fail "mktemp failed"
git -C "$REPO_ROOT" archive "$SHA" | tar -x -C "$HOST_TMP" || fail "git archive $SHA failed"
if [ "$INSTALL_FROM" = tarball ] || [ "$INSTALL_FROM" = aur ]; then
    # build-tarball.sh always archives HEAD of --src, so HOST_TMP (already the
    # ref's tree) is turned into a one-commit git checkout AT $SHA on the
    # HOST, mirroring the release job (reused unmodified, not re-implemented).
    echo "[step] host-git-init"
    if ! git -C "$HOST_TMP" init -q \
        || ! git -C "$HOST_TMP" add -A \
        || ! git -C "$HOST_TMP" -c user.name=rt -c user.email=rt@invalid commit -qm "rt $SHA"; then
        fail "step host-git-init failed"
    fi
    VERSION="0.0.0-rt${SHA:0:12}"
    TARBALL_OUT=$(mktemp -d "${TMPDIR:-/tmp}/rt-tarball-out.XXXXXX") || fail "mktemp failed"
    echo "[step] build-tarball"
    # HIMMEL_RT_TARBALL_NO_BUILD: a hermetic-test seam (test-provenance-roundtrip-dry.sh
    # only), same class as HIMMELCTL_CACHE_DIR / HIMMEL_CAPTURE_REPO_ROOT — skips
    # build-tarball.sh's `npm ci`/`npm run build` (network) so the dry twin still
    # runs the REAL build-tarball.sh (archive, tar, gzip, sha256, self-verify)
    # end to end. The station guest run never sets it: the tarball it installs
    # must be the real, buildable release artifact.
    BUILD_ARGS=()
    [ "${HIMMEL_RT_TARBALL_NO_BUILD:-0}" != 1 ] || BUILD_ARGS=(--no-build)
    bash "$REPO_ROOT/scripts/release/build-tarball.sh" --version "$VERSION" --src "$HOST_TMP" --out "$TARBALL_OUT" "${BUILD_ARGS[@]}" \
        || fail "step build-tarball failed"
    ASSET="himmel-$VERSION-linux.tar.gz"
    if [ "$INSTALL_FROM" = tarball ]; then
        echo "[step] stage-tarball"
        tar -C "$TARBALL_OUT" -cf - "$ASSET" "$ASSET.sha256" \
            | vm_ssh "rm -rf $TARBALL_STAGE && mkdir -p $TARBALL_STAGE && tar -C $TARBALL_STAGE -xf -" \
            || fail "step stage-tarball failed"
        # The README recipe verbatim: sha256 verify, extract into the versioned
        # dir with --strip-components=1, `current` symlink.
        step tarball-extract "cd $TARBALL_STAGE && sha256sum -c $ASSET.sha256 && mkdir -p $SHARE_HIMMEL/$VERSION && tar -xzf $ASSET -C $SHARE_HIMMEL/$VERSION --strip-components=1 && ln -sfn $VERSION $SHARE_HIMMEL/current"
    else
        # aur: package + install the SAME tarball via the real PKGBUILD, inside
        # a fresh --rm container (no host writes beyond $TARBALL_OUT/$HOST_TMP
        # scratch). pacman/makepkg is Arch-only, hence the container instead of
        # a VM. cronie is installed for crontab(1) only; nothing starts a
        # cron/systemd session inside the container.
        # ponytail: no running cron/systemd session in the container, so
        # --profile all's cadence-crontab-removed direction is observed via
        # crontab(1) spool state only, never a live fire; upgrade path is a
        # real Arch VM guest, HIMMEL-3059 follow-up.
        cp "$HOST_TMP/packaging/aur/PKGBUILD" "$HOST_TMP/packaging/aur/himmel.install" "$TARBALL_OUT/" \
            || fail "step aur-stage failed: packaging/aur/{PKGBUILD,himmel.install} missing at $SHA"
        SUM=$(awk '{print $1}' "$TARBALL_OUT/$ASSET.sha256")
        AUR_PKGVER="${VERSION//-/}"
        echo "[step] container-boot runtime=$RUNTIME image=$IMAGE"
        CONTAINER=$("$RUNTIME" run -d --rm -v "$TARBALL_OUT:/art:ro" "$IMAGE" sleep infinity) \
            || fail "step container-boot failed: could not start $IMAGE"
        cat >"$HOST_TMP/aur-setup.sh" <<'AURSETUP'
#!/usr/bin/env bash
set -euo pipefail
GHOME="$1" ASSET="$2" PKGVER="$3" SUM="$4" TAG="$5"
pacman -Syu --noconfirm --needed git jq nodejs python sudo cronie
useradd -m -d "$GHOME" builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
mkdir -p /build/pkg
cp /art/PKGBUILD /art/himmel.install "/art/$ASSET" "/art/$ASSET.sha256" /build/pkg/
# _tag normally reconstructs from pkgver via the "pre" substitution (real
# releases only), which does nothing for a dashless rt-sha pkgver -- so _tag
# would stay dashless while the tarball's own top-level dir keeps the dash
# build-tarball.sh was given. Pin _tag straight to that dir name instead of
# relying on the substitution to invert a string it does not recognize.
sed -i \
    -e "s|^pkgver=.*|pkgver=$PKGVER|" \
    -e "s|^_tag=.*|_tag=\"$TAG\"|" \
    -e "s|^source=.*|source=(\"$ASSET\")|" \
    -e "s|^sha256sums=.*|sha256sums=('$SUM')|" \
    /build/pkg/PKGBUILD
chown -R builder /build/pkg
AURSETUP
        echo "[step] container-setup"
        if ! "$RUNTIME" cp "$HOST_TMP/aur-setup.sh" "$CONTAINER:/root/aur-setup.sh" \
            || ! "$RUNTIME" exec "$CONTAINER" bash /root/aur-setup.sh "$GHOME" "$ASSET" "$AUR_PKGVER" "$SUM" "$VERSION"; then
            fail "step container-setup failed"
        fi
        step makepkg "cd /build/pkg && makepkg -si --noconfirm --nocolor >/tmp/makepkg.log 2>&1; rc=\$?; sed 's/^/[makepkg-log] /' /tmp/makepkg.log; exit \$rc"
    fi
else
    TOP=()
    while IFS= read -r f; do TOP+=("$f"); done < <(ls -A "$HOST_TMP")
    echo "[step] stage"
    rsync_e="ssh -i ${HIMMEL_VM_AR_SSH_KEY:-$HOME/.ssh/id_ed25519} -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
    vm_stage_tree "$HOST_TMP" "$SRC" vm_ssh "$rsync_e" "$GUEST_USER@127.0.0.1" "${TOP[@]}" || fail "step stage failed"
    step git-init "cd $SRC && git init -q && git add -A && git -c user.name=rt -c user.email=rt@invalid commit -qm 'rt $SHA'"
fi
echo "[step] helpers"
tar -C "$REPO_ROOT/scripts/vm/lib" -cf - seed-provenance.sh assert-provenance.sh inventory.sh invdiff.py \
    | guest_ssh "rm -rf $WORKDIR && mkdir -p $WORKDIR && tar -C $WORKDIR -xf -" || fail "step helpers failed"

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
    echo "[overlay] jq --arg v $GHOME/luna '$OVERLAY' $INSTALLED_ROOT/docs/setup/profiles/adopter-<scope>.install-profile.json"
    for scope in project user; do
        step "profile-$scope" "jq --arg v $GHOME/luna '$OVERLAY' $INSTALLED_ROOT/docs/setup/profiles/adopter-$scope.install-profile.json >$WORKDIR/profile-all-$scope.json"
    done
fi
echo "[env] $ENV_CMD"
for scope in project user; do
    INSTALL_ARGS=""
    [ "$PROFILE" != all ] || INSTALL_ARGS="--from-profile $WORKDIR/profile-all-$scope.json"
    # `install` takes no --profile/--yes (spec §11 step 4 says so; the CLI does
    # not): `--scope` alone is the non-interactive adopter path, whose shipped
    # profile (starter, vault none) maps to adopt.sh --profile core.
    INSTALL_CMD="cd $GHOME/proj && $ENV_CMD $RUN_BIN install ${INSTALL_ARGS:+$INSTALL_ARGS }--scope $scope >$WORKDIR/install-$scope.log 2>&1; rc=\$?; sed 's/^/[install-$scope-log] /' $WORKDIR/install-$scope.log; exit \$rc"
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
    UNINSTALL_CD="cd $GHOME/proj"
else
    UNINSTALL_ENTRY="$RUN_BIN"
    UNINSTALL_CD="cd $GHOME/proj"
fi
# A non-zero uninstall is itself a result (console ruling): record its rc and
# the step it halted at, then take inventory C anyway.
echo "[step] uninstall"
UN_OUT=$(guest_ssh "$UNINSTALL_CD && $ENV_CMD $UNINSTALL_ENTRY uninstall $UNINSTALL_FLAGS >$WORKDIR/uninstall.log 2>&1; rc=\$?; sed 's/^/[uninstall-log] /' $WORKDIR/uninstall.log; exit \$rc")
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
guest_ssh "INVDIFF_BASE=/tmp python3 $WORKDIR/invdiff.py A B | grep '^###'; INVDIFF_BASE=/tmp python3 $WORKDIR/invdiff.py A C | grep '^###'" || true
echo "[step] assert"
ASSERT_OUT=$(guest_ssh "HIMMEL_RT_GUEST=1 RT_PURGE=$PURGE RT_PROFILE=$PROFILE bash $WORKDIR/assert-provenance.sh") \
    || fail "step assert failed (rc=$?)"
printf '%s\n' "$ASSERT_OUT"

# aur only: complete the real-world lifecycle (himmelctl uninstall, then
# `pacman -R himmel`, per packaging/aur/himmel.install's documented order) and
# print explicit confirmation that pacman's own payload is gone. assert-provenance.sh
# is $HOME-scoped only, so it never sees /opt/himmel or /usr/bin/himmelctl either
# way — this is extra evidence beyond what the shared assertion checks.
if [ "$INSTALL_FROM" = aur ]; then
    step pacman-remove "sudo pacman -R --noconfirm himmel >/tmp/pacman-remove.log 2>&1; rc=\$?; sed 's/^/[pacman-remove-log] /' /tmp/pacman-remove.log; exit \$rc"
    PAYLOAD=$(guest_ssh "{ [ -e /opt/himmel ] && echo present || echo gone; } ; { [ -e /usr/bin/himmelctl ] && echo present || echo gone; }")
    echo "[pacman-payload] /opt/himmel=$(printf '%s\n' "$PAYLOAD" | sed -n 1p) /usr/bin/himmelctl=$(printf '%s\n' "$PAYLOAD" | sed -n 2p)"
fi

# 7b. --clone-gone --purge-state must leave no purge-owned ~/.himmel content
# (design §5.2/§4: provenance.jsonl, provenance-backups/ and the standalone
# uninstall/ bundle are the purge's own last statement) and nothing beyond
# what baseline A seeded there — ~/.himmel/config.json (seed-provenance.sh),
# never the whole directory: config.json is the user's own file and
# uninstall.sh deliberately never removes it (console ruling, HIMMEL-3528,
# 2026-09-23). Runs AFTER invdiff/assert so a legitimate failure here still
# preserves their diagnostic output in the captured run log.
if [ "$CLONE_GONE" = 1 ] && [ "$PURGE" = 1 ]; then
    HIMMEL_LIST=$(vm_ssh "find -L $GHOME/.himmel -mindepth 1 2>/dev/null | LC_ALL=C sort")
    HIMMEL_LIST_LINE=$(printf '%s' "$HIMMEL_LIST" | tr '\n' ' ')
    echo "[clone-gone-purge] ~/.himmel contents: ${HIMMEL_LIST_LINE:-(empty)}"
    UNEXPECTED=$(printf '%s\n' "$HIMMEL_LIST" | grep -vxF "$GHOME/.himmel/config.json" | grep -v '^$' || true)
    if [ -n "$UNEXPECTED" ]; then
        fail "clone-gone --purge-state left unexpected ~/.himmel content: $(printf '%s' "$UNEXPECTED" | tr '\n' ' ')"
    fi
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
