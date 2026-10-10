#!/usr/bin/env bash
# scripts/cloud/setup-env.sh — setup script for a claude.ai CLOUD environment
# (HIMMEL-4206). Paste it into the environment's "Setup script" box as
#
#     #!/bin/bash
#     rm -rf /tmp/himmel-setup \
#       && git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
#       && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh || true
#
# (the box runs BEFORE the session's repo clone exists, hence the throwaway
# clone; the trailing `|| true` keeps a failed clone or step from blocking the
# session start, since a non-zero setup script stops the session). The apt/pip
# steps land system-wide; the Jira dist and obsidian deps
# build inside that throwaway clone, so a session that needs them re-runs this
# script from its own clone (idempotent, the system steps skip as present).
# Full paste instructions: docs/handover/cloud-brief-template.md.
#
# Runs as root on Ubuntu 24.04. The platform caches a setup that finishes in
# about 5 minutes. Every step is idempotent (skip when already present) and every
# network call is bounded by `timeout`, but those bounds are per-call ceilings: a
# cold run with failing mirrors can exceed 5 minutes and then simply is not
# cached. A normal cold run is well inside it.
#
# What a himmel cloud session needs that the image lacks: shellcheck (cloud
# briefs tell the session to lint), `at` and pre-commit (suites reach for them),
# the obsidian-triage tool deps (marketplace suites), and the Jira CLI dist
# (built offline; it needs no secret, only JIRA_* at call time, which the cloud
# never has). node, bun, python, git, gh, jq are preinstalled.
#
# Usage:
#   setup-env.sh [--dry-run] [--with-plugins | --plugins <a,b,...>]
#     --dry-run       print one `step=<name> action=<...>` line per step and
#                     change nothing
#     --with-plugins  install the lean cloud profile (himmel-ops,lean-skills)
#                     into the VM's ~/.claude. Off by default.
#     --plugins <a,b,...>  (also --plugins=<list>) install exactly that comma
#                     list (the cloud profile); names must be plugins under
#                     marketplace/plugins, unknown or malformed names are
#                     skipped with a warning.
# The plugin step is NON-fatal: a failure prints a warning and keeps rc 0,
# because a non-zero setup script stops the cloud session from starting. Plugins
# install from the clone the script runs in (/tmp/himmel-setup in the paste),
# which the platform caches with the environment, so they refresh only when the
# setup script changes or the cache expires (~7 days). Probed 2026-10-04
# (HIMMEL-4273): skills load and plugin hooks fire in the session.
# Test seam: HIMMEL_CLOUD_ROOT (default: this script's repo) is the tree to act
# on; scripts/cloud/test-setup-env.sh points it at a fixture.
#
# The Bash timeouts are NOT set here: the environment's "Environment variables"
# field sets them. A cloud probe showed an /etc/profile.d write never reaches
# the Bash tool's shell (HIMMEL-4429); see docs/setup/cloud-environment.md.
set -uo pipefail

DRY=0
PLUGINS=""   # comma list; empty = no plugin step (HIMMEL-4273)
LEAN_PLUGINS="himmel-ops,lean-skills"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --with-plugins) PLUGINS="$LEAN_PLUGINS" ;;
    --plugins) [ "$#" -ge 2 ] || { echo "setup-env: --plugins needs a comma list (try --help)" >&2; exit 2; }; PLUGINS="$2"; shift ;;
    --plugins=*) PLUGINS="${1#--plugins=}" ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "setup-env: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

ROOT="${HIMMEL_CLOUD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
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

# soft_step: run_step for an optional step — a failure warns but never fails the
# run (a non-zero setup script stops the cloud session from starting).
soft_step() {
  local name="$1" action="$2" detail="$3"; shift 4
  plan "$name" "$action" "$detail"
  [ "$DRY" -eq 1 ] && return 0
  "$@" || echo "setup-env: step $name FAILED (non-fatal, session still starts)" >&2
}

# build_step: soft_step for the slow npm builds (HIMMEL-4429). Output goes to a
# log, and a failure prints `step=<name> FAILED <reason>` plus the log tail, so a
# dead build is never silent in the setup log.
LOG_D="${TMPDIR:-/tmp}/himmel-setup-logs"
build_step() {
  local name="$1" action="$2" detail="$3"; shift 4
  plan "$name" "$action" "$detail"
  [ "$DRY" -eq 1 ] && return 0
  mkdir -p "$LOG_D"
  local log="$LOG_D/$name.log" rc=0
  "$@" > "$log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  local why="rc=$rc"; [ "$rc" -eq 124 ] && why="timed out (rc=124)"
  echo "step=$name FAILED $why (non-fatal, session still starts) log=$log" >&2
  tail -n 20 "$log" >&2
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

# 4. plugin cloud profile (HIMMEL-4273): install exactly $PLUGINS. Non-fatal.
if [ -n "$PLUGINS" ]; then
  if have claude || [ "$DRY" -eq 1 ]; then
    soft_step plugins-marketplace add "$ROOT/marketplace" -- $TMO 120 claude plugin marketplace add "$ROOT/marketplace"
    IFS=, read -r -a plugin_list <<< "$PLUGINS"
    for p in "${plugin_list[@]}"; do
      case "$p" in
        ''|*[!a-z0-9-]*) plan "plugin:$p" skip "invalid name"; echo "setup-env: plugin name '$p' is invalid, skipped" >&2 ;;
        *) if [ -d "$ROOT/marketplace/plugins/$p" ]; then
             soft_step "plugin:$p" install "$p@himmel" -- $TMO 120 claude plugin install "$p@himmel"
           else
             plan "plugin:$p" skip "not in marketplace/plugins"; echo "setup-env: plugin '$p' not in the marketplace, skipped" >&2
           fi ;;
      esac
    done
  else
    plan plugins skip "claude CLI absent in the setup VM"
  fi
fi

# 5-6. The slow npm builds run LAST and soft (HIMMEL-4429): a cloud setup died
# silently inside the jira build and took the plugins with it. A failure prints
# its reason and log tail and never stops the session.
# 5. Jira CLI dist: deps + tsc, offline-capable after install, no secret.
JIRA_DIR="$ROOT/scripts/jira"
if [ -f "$JIRA_DIR/dist/index.js" ]; then
  plan jira-dist skip "built"
else
  # shellcheck disable=SC2016  # $1/$2 are the sh -c positional args (HIMMEL-4744)
  build_step jira-dist build "npm ci + tsc" -- sh -c 'cd "$1" && "$2" 150 npm ci --no-audit --no-fund && "$2" 60 npm run build' sh "$JIRA_DIR" "$TMO"
fi

# 6. obsidian-triage tool deps (js-yaml + playwright) the marketplace suites import.
OT="$ROOT/marketplace/plugins/obsidian-triage/tools"
if [ -d "$OT/node_modules" ]; then
  plan obsidian-deps skip "present"
elif [ -f "$OT/ensure-deps.sh" ] || [ "$DRY" -eq 1 ]; then
  build_step obsidian-deps install "ensure-deps.sh" -- $TMO 120 bash "$OT/ensure-deps.sh"
else
  plan obsidian-deps skip "no ensure-deps.sh in this tree"
fi

# 7-8. graphify, AST-only (HIMMEL-4726). Pinned to the version
# scripts/lib/graphify-bin.sh carries, with no backend extra: `graphify update`
# parses code locally and calls no model, so no repo content leaves the VM. The
# graph lands in $ROOT/graphify-out (the setup clone, frozen with the cache); a
# session queries it with --graph or rebuilds its own clone the same way.
GV=""
while IFS= read -r line; do
  if [[ "$line" =~ GRAPHIFY_VERSION:-([0-9][0-9.]*)\} ]]; then GV="${BASH_REMATCH[1]}"; break; fi
done < "$ROOT/scripts/lib/graphify-bin.sh" 2>/dev/null
if have graphify; then
  plan graphify skip "present"
elif [ -z "$GV" ]; then
  plan graphify skip "no graphify pin in this tree"
else
  build_step graphify install "graphifyy==$GV (pip, no backend extra)" -- $TMO 180 python3 -m pip install --disable-pip-version-check --break-system-packages "graphifyy==$GV"
fi
if have graphify || [ "$DRY" -eq 1 ]; then
  # shellcheck disable=SC2016  # $1/$2 are the sh -c positional args (HIMMEL-4744)
  build_step graphify-graph build "graphify update . (AST-only, in $ROOT)" -- sh -c 'cd "$1" && "$2" 180 graphify update .' sh "$ROOT" "$TMO"
else
  plan graphify-graph skip "graphify absent"
fi

# 9-10. qmd over THIS repo only (HIMMEL-4726): the pinned fork via
# scripts/lib/qmd-bin.sh (bun is preinstalled), then one collection, `himmel`,
# on $ROOT. Never a vault: luna and handover state stay on the station. BM25
# only: no `qmd pull` (~2 GB of models) and no embed, which do not fit the
# ~5 min cached setup, so `qmd search -c himmel` works and vector search does not.
# Use the shared resolver: bun's installed JS may exist without a global shim
# on PATH (HIMMEL-4814). The same bounded route is used by the session probe.
cloud_qmd() { QMD_TIMEOUT_SECS="${QMD_TIMEOUT_SECS:-180}" "$BASH" "$ROOT/scripts/lib/qmd-bounded.sh" "$@"; }
qmd_index() {
  if [[ $'\n'"$qmd_cols" == *$'\n'"himmel "* ]]; then
    cloud_qmd collection remove himmel || return $?
  fi
  cloud_qmd collection add "$ROOT" --name himmel || return $?
  local cols
  cols="$(cloud_qmd collection list)" || return $?
  if [[ $'\n'"$cols" != *$'\n'"himmel "* ]]; then
    echo "setup-env: himmel collection missing after setup" >&2
    return 1
  fi
}
if have qmd; then
  plan qmd skip "present"
else
  build_step qmd install "qmd-bin.sh install (pinned fork, bun)" -- $TMO 180 bash "$ROOT/scripts/lib/qmd-bin.sh" install
fi
qmd_cols="$(QMD_TIMEOUT_SECS=30 cloud_qmd collection list 2>/dev/null)"
if [[ $'\n'"$qmd_cols" == *$'\n'"himmel "* ]]; then
  # rebuilt, not skipped: the cached collection may index an older clone or path
  build_step qmd-index refresh "$ROOT --name himmel (BM25 only, no embed)" -- qmd_index
else
  build_step qmd-index add "$ROOT --name himmel (BM25 only, no embed)" -- qmd_index
fi

# 11. Stamp the hash of this script so a session's `check-env.sh` can tell a
# stale cached snapshot from the repo's current script (HIMMEL-5163).
soft_step env-stamp record "scripts/cloud/check-env.sh --stamp" -- bash "$ROOT/scripts/cloud/check-env.sh" --stamp

if [ "$failed" -ne 0 ]; then echo "setup-env: $failed step(s) failed" >&2; exit 1; fi
echo "setup-env: done (dry-run=$DRY)" >&2
