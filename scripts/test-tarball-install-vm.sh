#!/usr/bin/env bash
# test-tarball-install-vm.sh -- host-driven fresh-guest acceptance for the
# checksummed release tarball (HIMMEL-3059 slice 1, prerequisite P4). Builds the
# tarball + a git bundle of THIS worktree's HEAD, ships them to a guest, and runs
# scripts/release/tarball-vs-clone.sh there: install via the README's tarball
# steps AND via a clone of the same commit, then assert the two END STATES
# CONVERGE (ADR Q3) -- not merely that both installs exited 0.
#
# STATUS: RUN ON A GUEST, GREEN (HIMMEL-3262). At 0aacaa42 on a guest restored from
# suite-ready-v4 this exits 0 -- "clone and tarball installs CONVERGED" (314 snapshot
# lines identical after path normalization); the vm_guest_assert_clean false positive
# that used to gate it (HIMMEL-3252) is fixed. Its hermetic halves are tested
# (scripts/release/test-tarball-vs-clone.sh: the convergence assertion against a
# stub himmelctl, with a divergent RED control; this driver's fail-soft path).
# ponytail: both installs go into a fake HOME under /tmp, and there is no uninstall
# leg nor a vm_guest_assert_clean AFTER the run -- the real-HOME uninstall round trip
# is covered by the clone path (scripts/test-install-symmetry-vm.sh), not here.
#
# Guest needs: bash, git, node+npm, jq, python3, sha256sum, tar.
#
# Usage:
#   bash scripts/test-tarball-install-vm.sh [user@host] [port] [identity]
#   defaults: localhost 2222 $HOME/.ssh/id_ed25519
#
# Exit: 0 = converged | 1 = an assertion failed | 3 = the VM was unreachable
# (not a code failure -- re-run once the VM is up).
set -uo pipefail

HOSTSPEC="${1:-localhost}"
PORT="${2:-2222}"
IDENT="${3:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-p $PORT -i $IDENT -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Unique per run: two drivers against one guest must not delete each other's artifacts.
REMOTE_DIR="/tmp/himmel-tarball-vm-$$-$RANDOM"
VERSION="0.0.0-acceptance"

# shellcheck disable=SC2086,SC2029
ssh_vm() { ssh $SSH_OPTS "$HOSTSPEC" "$@"; }

echo "==> tarball-install VM acceptance: $HOSTSPEC:$PORT (HEAD of $REPO)"

# 0. connectivity (fail soft with rc 3 -- an unreachable VM is not a code defect).
if ! ssh_vm 'echo connected' >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to $HOSTSPEC:$PORT with key $IDENT." >&2
  echo "  The VM is not reachable by this session -- re-run once it is provisioned." >&2
  exit 3
fi

# 1. build the two artifacts from the SAME commit: the release tarball (with the
#    real node builds) and a bundle for the clone path.
stage="$(mktemp -d "${TMPDIR:-/tmp}/himmel-tarball-vm.XXXXXX")" || { echo "test-tarball-install-vm: cannot create a staging dir" >&2; exit 1; }
trap 'rm -rf "$stage"' EXIT
bash "$REPO/scripts/release/build-tarball.sh" --version "$VERSION" --src "$REPO" --out "$stage" >"$stage/build.log" 2>&1 \
  || { echo "==> BUILD FAILED:" >&2; cat "$stage/build.log" >&2; exit 1; }
git -C "$REPO" bundle create "$stage/himmel.bundle" HEAD >/dev/null 2>&1 \
  || { echo "==> git bundle failed" >&2; exit 1; }
cp "$REPO/scripts/release/converge-check.sh" "$REPO/scripts/release/tarball-vs-clone.sh" "$stage/"
rm -f "$stage/build.log"

# 2. ship, then assert the guest holds no secrets before anything runs there
#    (HIMMEL-2540). Only git-tracked content + the built tarball travel.
# shellcheck source=lib/vm-guest-excludes.sh
. "$REPO/scripts/lib/vm-guest-excludes.sh" \
  || { echo "==> REFUSING: cannot load scripts/lib/vm-guest-excludes.sh; nothing was copied" >&2; exit 1; }
ssh_vm "mkdir $REMOTE_DIR" || { echo "==> STAGE FAILED (mkdir $REMOTE_DIR; it must not already exist)" >&2; exit 1; }
tar -C "$stage" -cf - . | ssh_vm "tar -C $REMOTE_DIR -xf -" \
  || { echo "==> STAGE FAILED: the copy to the guest did not complete" >&2; exit 1; }
vm_guest_assert_clean ssh_vm "$REMOTE_DIR" full || exit 1

# 3. run the acceptance body on the guest.
ssh_vm "cd $REMOTE_DIR && bash tarball-vs-clone.sh --work $REMOTE_DIR/work --tarball $REMOTE_DIR/himmel-$VERSION-linux.tar.gz --bundle $REMOTE_DIR/himmel.bundle"
rc=$?
echo "==> guest run exit=$rc"
exit $((rc == 0 ? 0 : 1))
