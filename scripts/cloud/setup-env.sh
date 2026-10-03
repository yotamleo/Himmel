#!/usr/bin/env bash
# scripts/cloud/setup-env.sh — setup script for a claude.ai CLOUD environment
# (HIMMEL-4206). Paste it into the environment's "Setup script" box as
#
#     #!/bin/bash
#     git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
#       && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh
#
# (the box runs BEFORE the session's repo clone exists, hence the throwaway
# clone). Full paste instructions: docs/handover/cloud-brief-template.md.
#
# Runs as root on Ubuntu 24.04. The platform caches a setup that finishes in
# about 5 minutes, so every step is idempotent (skip when already present) and
# every network call is bounded by `timeout`.
#
# What a himmel cloud session needs that the image lacks: shellcheck (cloud
# briefs tell the session to lint), `at` and pre-commit (suites reach for them),
# the obsidian-triage tool deps (marketplace suites), and the Jira CLI dist
# (built offline; it needs no secret, only JIRA_* at call time, which the cloud
# never has). node, bun, python, git, gh, jq are preinstalled.
#
# Usage:
#   setup-env.sh [--dry-run] [--with-plugins]
#     --dry-run       print one `step=<name> action=<...>` line per step and
#                     change nothing
#     --with-plugins  slice-7 EXPERIMENT: try to install the himmel plugins into
#                     the VM's ~/.claude. Undocumented by Anthropic; treat a
#                     silent no-load in the session as "no". Off by default.
# Test seam: HIMMEL_CLOUD_ROOT (default: this script's repo) is the tree to act
# on; scripts/cloud/test-setup-env.sh points it at a fixture.
#
# ponytail: BASH_DEFAULT_TIMEOUT_MS is persisted via /etc/profile.d, which only
# reaches shells that source it; the environment's own "Environment variables"
# field is the documented route and wins, upgrade = drop the profile.d write once
# a cloud session proves that field alone sets it (HIMMEL-4206).
set -uo pipefail

DRY=0
PLUGINS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --with-plugins) PLUGINS=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "setup-env: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

ROOT="${HIMMEL_CLOUD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TIMEOUT_MS=600000   # the cloud's Bash maximum; the default is 2 minutes
failed=0
TMO=timeout   # gnu-ok: runs only on the Ubuntu 24.04 cloud VM (GNU coreutils, apt)

have() { command -v "$1" >/dev/null 2>&1; }
plan() { echo "step=$1 action=$2${3:+ $3}"; }

# run_step <name> <action> <detail> -- <cmd...>: dry-run prints, otherwise runs.
run_step() {
  local name="$1" action="$2" detail="$3"; shift 4
  plan "$name" "$action" "$detail"
  [ "$DRY" -eq 1 ] && return 0
  "$@" || { echo "setup-env: step $name FAILED" >&2; failed=$((failed + 1)); }
}

apt_install() { # apt_install <pkg>: plain install first, refresh only on failure
  $TMO 120 apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=60 "$1" \
    || { $TMO 120 apt-get update -o Acquire::Retries=3 -o DPkg::Lock::Timeout=60 \
         && $TMO 120 apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=60 "$1"; }
}

# 1-2. apt packages. `at` ships without a running atd here; the suites only need the binary.
for pkg in shellcheck at; do
  if have "$pkg"; then plan "$pkg" skip "present"; else run_step "$pkg" install "apt" -- apt_install "$pkg"; fi
done

# 3. pre-commit (scripts/test-template-nostash-hooks.sh hard-SKIPs without it).
if have pre-commit; then
  plan pre-commit skip "present"
else
  run_step pre-commit install "pip" -- $TMO 120 python3 -m pip install --disable-pip-version-check --break-system-packages pre-commit
fi

# 4. Jira CLI dist: deps + tsc, offline-capable after install, no secret.
JIRA_DIR="$ROOT/scripts/jira"
if [ -f "$JIRA_DIR/dist/index.js" ]; then
  plan jira-dist skip "built"
else
  run_step jira-dist build "npm ci + tsc" -- sh -c "cd '$JIRA_DIR' && $TMO 240 npm ci --no-audit --no-fund && npm run build"
fi

# 5. obsidian-triage tool deps (js-yaml + playwright) the marketplace suites import.
OT="$ROOT/marketplace/plugins/obsidian-triage/tools"
if [ -d "$OT/node_modules" ]; then
  plan obsidian-deps skip "present"
elif [ -f "$OT/ensure-deps.sh" ] || [ "$DRY" -eq 1 ]; then
  run_step obsidian-deps install "ensure-deps.sh" -- bash "$OT/ensure-deps.sh"
else
  plan obsidian-deps skip "no ensure-deps.sh in this tree"
fi

# 6. environment: Bash timeouts. Exported for this script, persisted for later shells.
export BASH_DEFAULT_TIMEOUT_MS="$TIMEOUT_MS" BASH_MAX_TIMEOUT_MS="$TIMEOUT_MS"
plan env export "BASH_DEFAULT_TIMEOUT_MS=$TIMEOUT_MS BASH_MAX_TIMEOUT_MS=$TIMEOUT_MS"
if [ "$DRY" -eq 0 ] && [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  printf 'export BASH_DEFAULT_TIMEOUT_MS=%s\nexport BASH_MAX_TIMEOUT_MS=%s\n' "$TIMEOUT_MS" "$TIMEOUT_MS" > /etc/profile.d/himmel-cloud.sh
fi

# 7. EXPERIMENT (slice 7): plugins into ~/.claude. Off unless asked.
if [ "$PLUGINS" -eq 1 ]; then
  if have claude; then
    run_step plugins experiment "marketplace add + install" -- sh -c "
      $TMO 120 claude plugin marketplace add '$ROOT/marketplace' &&
      $TMO 120 claude plugin install himmel-ops@himmel &&
      $TMO 120 claude plugin install lean-skills@himmel"
  else
    plan plugins experiment "claude CLI absent in the setup VM: result is NO"
  fi
fi

if [ "$failed" -ne 0 ]; then echo "setup-env: $failed step(s) failed" >&2; exit 1; fi
echo "setup-env: done (dry-run=$DRY)" >&2
