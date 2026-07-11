#!/usr/bin/env bash
set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
LUNA_REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --luna-remote) LUNA_REMOTE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# CR r2 (HIMMEL-887): fail CLOSED on --luna-remote BEFORE any provisioning.
# The old script cloned the remote vault itself; the delegated himmelctl flow
# does not support remote-vault restore yet (HIMMEL-755 scope), so accepting
# the flag and silently dropping it would let a machine rebuild complete
# WITHOUT the operator's vault.
if [[ -n "$LUNA_REMOTE" ]]; then
  echo "ERROR: --luna-remote is not supported by the delegated himmelctl flow yet (HIMMEL-755)." >&2
  echo "  Clone the vault manually first:  git clone $LUNA_REMOTE ~/Documents/luna" >&2
  echo "  then re-run this script WITHOUT --luna-remote." >&2
  exit 1
fi

# ── Paths ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC2034
HIMMEL_PATH="$HOME/github/himmel"

# ── PATH hoist ──────────────────────────────────────────────────────────────
# uv and the native Claude Code installer both drop binaries into
# ~/.local/bin. Prepend once here so every step picks them up — avoids the
# per-step re-export duplication.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# ── Progress ────────────────────────────────────────────────────────────────
TOTAL_STEPS=8
STEP=0

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "══════════════════════════════════════════════"
  echo "[$STEP/$TOTAL_STEPS] $1"
  echo "══════════════════════════════════════════════"
}

# ── Steps (1–8): set -e active throughout ───────────────────────────────────
step "Update package manager"
sudo apt update
sudo apt upgrade -y

step "Install core tools: git, Python, jq, curl, shellcheck, gitleaks"
# The shellcheck and gitleaks binaries are referenced by .pre-commit-config.yaml.
# pre-commit downloads its own copies inside the hook framework, but local
# direct invocation (manual lint runs, smoke tests) needs them on PATH.
sudo apt install -y git python3 python3-pip jq curl shellcheck gitleaks

step "Install nvm + Node from .nvmrc"
NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
NODE_VERSION="$(cat "$REPO_ROOT/.nvmrc")"
nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

ACTUAL_MAJOR="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"
_nv="${NODE_VERSION#v}"
EXPECT_MAJOR="${_nv%%.*}"
if [ "$ACTUAL_MAJOR" != "$EXPECT_MAJOR" ]; then
  echo "ERROR: node major $ACTUAL_MAJOR != expected $EXPECT_MAJOR from .nvmrc"
  exit 1
fi
echo "Node $(node --version) active (.nvmrc=$NODE_VERSION)"

step "Install uv + uvx"
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version

step "Install Claude Code CLI (native installer — no npm dependency)"
curl -fsSL https://claude.ai/install.sh | bash
claude --version

step "Install RTK"
# Use the unversioned `rtk_amd64.deb` alias rather than `rtk_${VER}_amd64.deb`.
# The release also publishes `rtk_${VER}-1_amd64.deb` (note the `-1` debian
# revision) but no `rtk_${VER}_amd64.deb` — the old derivation 404'd silently.
# The alias survives both version and revision bumps.
RTK_TAG=$(curl -s https://api.github.com/repos/rtk-ai/rtk/releases/latest | jq -r .tag_name)
RTK_DEB="rtk_amd64.deb"
curl -fL "https://github.com/rtk-ai/rtk/releases/download/${RTK_TAG}/${RTK_DEB}" \
  -o "/tmp/${RTK_DEB}"
sudo apt install -y "/tmp/${RTK_DEB}"
rtk init -g
rtk --version

step "Clone himmel repo"
mkdir -p "$(dirname "$HIMMEL_PATH")"
git clone https://github.com/yotamleo/himmel.git "$HIMMEL_PATH"
cd "$HIMMEL_PATH"

# HIMMEL-105: gate the clone for core.hooksPath misconfiguration BEFORE any
# further tooling runs. If the operator's machine inherited a bad
# core.hooksPath from a sibling repo (or copied .gitconfig), a later hook
# install would silently install hooks into a dir git is ignoring, and every
# gate (no-push-to-main, npm-audit, code-review-before-push, platforms-tested,
# hookspath-misconfig itself) would be bypassed.
bash scripts/hooks/check-hookspath.sh
cd -

step "Delegate himmel/luna wiring to himmelctl bootstrap (HIMMEL-887)"
# HIMMEL-887: this script is soft-deprecated for himmel/luna WIRING — the
# provisioning above (steps 1-6, full toolchain) is unchanged and stays the
# source of truth (locked decision O4: zero capability loss). Wiring (Claude
# config, plugins, luna vault, settings.json patching, hooks registration, …)
# now runs via `himmelctl bootstrap`, which re-execs into `himmelctl install`
# once node is confirmed present (it always is here — step 3 just installed
# it) — one wiring implementation instead of two drifting copies. Hard-remove
# of this now-deprecated shim script itself (once its toolchain-provisioning
# role is also absorbed) is deferred to the HIMMEL-755 fork.
# (--luna-remote fail-closes at arg parse above — CR r2 — so no remote-vault
# handling is needed here.)
#
# CR r4: delegate FROM the himmel clone, not from wherever the operator
# launched this shim. The wizard's role/scope inference reads the CWD's git
# origin, and scope=project wires .claude into the CWD — delegating from the
# launch directory would target the WRONG repo. cd (not a subshell) because
# the exec below replaces this process. The wizard is interactive by design:
# an unattended/non-TTY run fails loud with remediation (documented posture);
# this cd only guarantees that when it DOES run, its inference targets the
# himmel clone deterministically.
echo "NOTICE: himmel/luna wiring in this script is soft-deprecated (HIMMEL-887) -- delegating to himmelctl bootstrap. Hard-remove deferred to HIMMEL-755."
cd "$HIMMEL_PATH"
exec bash "$HIMMEL_PATH/scripts/himmelctl/bootstrap.sh"
