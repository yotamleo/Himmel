# shellcheck shell=bash
# scripts/lib/qmd-bin.sh
#
# Resolver for the qmd CLI. qmd ships as a Claude plugin (path stub at
# ~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) AND as a bun-installed
# binary (~/.bun/install/global/...). On Windows the plugin stub
# references a missing dist/cli/qmd.js and shadows the bun shim on
# Git Bash $PATH, so plain `qmd` fails with:
#   error: Module not found "...claude/plugins/cache/qmd/.../dist/cli/qmd.js"
# Real Git Bash terminals resolve qmd correctly; only Claude Code's
# Bash tool sees the broken plugin-cache PATH prepend. This helper
# picks the working invoker by preferring the canonical bun install
# when present, honoring BUN_INSTALL for relocated bun roots.
#
# scripts/lib/fix-qmd-stub.sh patches the broken plugin-cache stub at
# source (HIMMEL-163), which fixes plain `qmd` for call sites that don't
# source this lib; this resolver stays as the consumer-side path until
# the upstream plugin fix is pulled.
#
# Project rule: qmd is installed via bun, never npm. Bash callers get
# the install hint via qmd_install_hint() (single source of truth for
# bash); the pwsh mirror in scripts/setup.ps1 hardcodes the same
# string and must be updated in lockstep.

qmd_install_hint() {
  echo 'bun add -g @tobilu/qmd@latest --ignore-scripts'
}

# Resolve bun-direct qmd.js path. Respects BUN_INSTALL (bun's own override)
# so non-default global installs at /opt/bun etc. are picked up.
_qmd_bun_js() {
  local bun_root="${BUN_INSTALL:-$HOME/.bun}"
  echo "$bun_root/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
}

qmd_cmd() {
  local bun_qmd
  bun_qmd="$(_qmd_bun_js)"
  if [ -f "$bun_qmd" ] && command -v bun >/dev/null 2>&1; then
    bun "$bun_qmd" "$@"
  elif command -v qmd >/dev/null 2>&1; then
    qmd "$@"
  else
    return 127
  fi
}

# Presence check ONLY — does not invoke the binary, so real runtime errors
# (corrupt better-sqlite3 prebuild, broken cache) reach the caller instead
# of being masked as "qmd not installed".
has_qmd() {
  local bun_qmd
  bun_qmd="$(_qmd_bun_js)"
  if [ -f "$bun_qmd" ] && command -v bun >/dev/null 2>&1; then
    return 0
  fi
  command -v qmd >/dev/null 2>&1
}
