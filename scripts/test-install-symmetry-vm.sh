#!/usr/bin/env bash
# test-install-symmetry-vm.sh -- host-driven VM validation for the install/
# uninstall symmetry initiative (R8, HIMMEL-460). Copies THIS worktree to an
# Ubuntu VM over ssh and runs the hermetic bash suites + the real out-of-repo
# auto-approve check (SC2) on real Linux.
#
# EXITS 0 iff SC1/SC2/SC3/SC5/SC6/SC7 all pass on the VM. Tools that setup should
# provide but the VM lacks are emitted to stderr as `GAP:` lines; a GAP fails the
# run only when the missing tool is in setup's hard-required set (that is the R6
# bug the initiative guards against), else it warns.
#
# Usage:
#   bash scripts/test-install-symmetry-vm.sh [user@host] [port] [identity]
#   defaults: localhost 2222 $HOME/.ssh/id_ed25519
#
# Exit codes: 0 = all assertions passed; 1 = an assertion failed; 3 = the VM was
# unreachable (key auth) -- not a code failure, re-run when the VM is provisioned.
set -uo pipefail

HOSTSPEC="${1:-localhost}"
PORT="${2:-2222}"
IDENT="${3:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-p $PORT -i $IDENT -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="/tmp/himmel-symmetry-vm"

# Intentional: $SSH_OPTS word-splits into flags (SC2086) and the remote command
# expands host-side before transport (SC2029 -- we WANT host vars like REMOTE_DIR
# substituted before the VM runs the body).
# shellcheck disable=SC2086,SC2029
ssh_vm() { ssh $SSH_OPTS "$HOSTSPEC" "$@"; }

echo "==> VM validation: $HOSTSPEC:$PORT (worktree: $REPO)"

# 0. connectivity (fail soft with rc 3 -- VM not ready is not a code defect).
if ! ssh_vm 'echo connected' >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to $HOSTSPEC:$PORT with key $IDENT (publickey rejected)." >&2
  echo "  The VM is not reachable by this session -- run this script once the VM" >&2
  echo "  is provisioned (the agent's pubkey in the VM's authorized_keys)." >&2
  exit 3
fi

# 1. stage the branch (rsync when both sides have it, else scp -r the scripts tree).
echo "[stage] copying worktree to $REMOTE_DIR ..."
ssh_vm "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
if command -v rsync >/dev/null 2>&1 && ssh_vm 'command -v rsync >/dev/null 2>&1'; then
  rsync -az -e "ssh $SSH_OPTS" --exclude '.git' --exclude 'node_modules' --exclude 'dist' \
    "$REPO/scripts" "$REPO/.env.example" "$HOSTSPEC:$REMOTE_DIR/"
else
  # shellcheck disable=SC2086
  scp -P $PORT -i "$IDENT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -r \
    "$REPO/scripts" "$HOSTSPEC:$REMOTE_DIR/"
  # shellcheck disable=SC2086
  scp -P $PORT -i "$IDENT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$REPO/.env.example" "$HOSTSPEC:$REMOTE_DIR/" 2>/dev/null || true
fi

# 2. run the assertions on the VM. The remote body is self-contained: it runs the
#    hermetic suites that map to each SC, the real out-of-repo auto-approve (SC2),
#    a setup.sh syntax+arg-parse smoke, and the GAP scan. It echoes a final
#    RESULT: line and exits non-zero on any failure.
ssh_vm "REMOTE_DIR=$REMOTE_DIR bash -s" <<'REMOTE'
set -uo pipefail
DIR="$REMOTE_DIR"
fails=0
run_suite() {
  local label="$1" script="$2"
  if [ ! -f "$DIR/$script" ]; then echo "MISS  $label ($script not staged)"; fails=$((fails+1)); return; fi
  # Run from the staged repo root: some suites (test-inject-initiative) resolve
  # their repo via a CWD-relative `git rev-parse --show-toplevel`.
  if ( cd "$DIR" && bash "$script" ) >"/tmp/vm-$(basename "$script").log" 2>&1; then
    echo "PASS  $label"
  else
    echo "FAIL  $label -- see /tmp/vm-$(basename "$script").log"; fails=$((fails+1))
    tail -5 "/tmp/vm-$(basename "$script").log" | sed 's/^/      /'
  fi
}

echo "---- VM: $(uname -srm) ----"

# Bootstrap the TEST-HARNESS deps (bash/git/jq) -- separate from the user runtime
# set (HIMMEL-469). Best-effort: on a NOPASSWD test VM / CI runner this installs
# git+jq; on a password-sudo box it fails loud and the git-dependent suites are
# reported as GAPs below (the non-git suites still run).
if [ -f "$DIR/scripts/machine-setup/test-bootstrap.sh" ]; then
  bash "$DIR/scripts/machine-setup/test-bootstrap.sh" 2>&1 | sed 's/^/  /' || echo "  test-bootstrap: could not install all test deps (non-fatal; see GAP scan)"
fi

# The staged tree is a plain scp copy (no .git). test-inject-initiative resolves
# its repo root via `git rev-parse --show-toplevel`, so make the staging dir a git
# repo (a real clone would already be one). Guarded on git presence.
if command -v git >/dev/null 2>&1 && [ ! -d "$DIR/.git" ]; then
  ( cd "$DIR" && git init -q . && git config user.email t@e.co && git config user.name t ) 2>/dev/null \
    && echo "  [stage] git-initialised $DIR (test-inject-initiative needs a git toplevel)"
fi

# SC1/SC8 (setup wires the UNIVERSAL hooks; basename dedup survives a path move).
run_suite "SC1/SC8 setup-wire"        scripts/lib/test-setup-wire.sh
# SC3 (inject-initiative resolves legs from the himmel .env; CWD-safety).
# These two need `git` (git-toplevel resolution + decoy-repo fixtures). On a
# bare VM without git they're GAP-skipped (a test-dep provisioning gap, not a
# code failure); CI / a NOPASSWD VM has git via test-bootstrap, so they run.
if command -v git >/dev/null 2>&1; then
  run_suite "SC3 inject-initiative"   scripts/hooks/test-inject-initiative.sh
  run_suite "SC3 load-dotenv --root"  scripts/lib/test-load-dotenv.sh
else
  echo "GAP:  git missing -- SC3 inject-initiative + load-dotenv suites SKIPPED (test-dep; run test-bootstrap.sh)" >&2
fi
# SC5/SC11 (dup detection advisory; benign double-fire).
run_suite "SC5/SC11 detect-hook-dup"  scripts/lib/test-detect-hook-dup.sh
# SC6 (uninstall [6/6] + unwire helpers).
run_suite "SC6 uninstall"             scripts/test-uninstall.sh
run_suite "SC6 unwire-pretooluse"     scripts/lib/test-unwire-pretooluse-hooks.sh
run_suite "SC6 unwire-singlekey"      scripts/lib/test-unwire-singlekey.sh
# SC7 (preflight ordering + ensure-tools branches).
run_suite "SC7 setup-preflight"       scripts/setup/test-setup-preflight.sh
# wire lib sanity.
run_suite "wire-pretooluse"           scripts/lib/test-wire-pretooluse-hooks.sh
# E2E install -> uninstall roundtrip (drives the REAL setup-wire sequence + the
# REAL uninstall.sh [6/6] against a sandbox settings.json; jq-only, no git).
run_suite "E2E install->uninstall"    scripts/test-e2e-symmetry.sh

# SC2 (the real Goal): an out-of-repo Bash call to the abs-path Jira CLI is
# auto-approved by the user-scope hook. Run from /tmp (outside the repo) and feed
# the hook the exact payload Claude Code would.
echo "---- SC2: out-of-repo auto-approve ----"
AA="$DIR/scripts/hooks/auto-approve-safe-bash.sh"
SC2_IN="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node $DIR/scripts/jira/dist/index.js transition HIMMEL-1 Done\"}}"
if command -v jq >/dev/null 2>&1; then
  sc2_out=$(cd /tmp && printf '%s' "$SC2_IN" | bash "$AA" 2>/dev/null)
  if printf '%s' "$sc2_out" | grep -q '"permissionDecision"[: ]*"allow"'; then
    echo "PASS  SC2 out-of-repo jira call auto-approved"
  else
    echo "FAIL  SC2 out-of-repo jira call NOT auto-approved: $sc2_out"; fails=$((fails+1))
  fi
else
  echo "GAP:  jq missing on VM -- SC2 (and the hooks) need jq; setup must provide it" >&2
  fails=$((fails+1))   # jq is hard-required
fi

# setup.sh smoke: syntax + arg-parse path (exercises the relocated SETUP_DIR top
# without the heavy full install).
echo "---- setup.sh smoke ----"
if bash -n "$DIR/scripts/setup.sh" && bash "$DIR/scripts/setup.sh" --help >/dev/null 2>&1; then
  echo "PASS  setup.sh syntax + --help"
else
  echo "FAIL  setup.sh syntax/--help"; fails=$((fails+1))
fi

# GAP scan: tools setup's [0/10] treats as hard-required.
echo "---- GAP scan (hard-required tools) ----"
for t in bash git node npm bun python3 jq gh mktemp; do
  command -v "$t" >/dev/null 2>&1 || echo "GAP:  hard-required '$t' missing on VM (setup [0/10] would auto-install/flag it)" >&2
done

echo "RESULT: $fails failure(s)"
[ "$fails" -eq 0 ]
REMOTE
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "==> VM validation PASSED"
else
  echo "==> VM validation FAILED (rc=$rc)" >&2
fi
exit "$rc"
