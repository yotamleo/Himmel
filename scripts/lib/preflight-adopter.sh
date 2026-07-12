# shellcheck shell=bash
# preflight-adopter.sh — shared adopter preflight checks (HIMMEL-842 fix-batch).
#
# Sourced (not executed) by both scripts/adopt.sh (auto-invoked from
# require_tools) and scripts/preflight-adopter.sh (the standalone check-only
# runner an adopter can run BEFORE committing to adopt.sh — operator answer Q4:
# "BOTH standalone check-only AND auto-invoked"). Mirrors the existing
# scripts/lib/qmd-bin.sh / wire-*.sh pattern: small, single-purpose, sourced by
# multiple entry points so the check logic lives in exactly one place.
#
# FUNCTIONS ONLY — sourcing this file has NO side effects (no globals, nothing
# runs at source time). Callers invoke the preflight_check_* functions, each of
# which returns 0 when the environment is clean and 1 when its gap is detected
# (after printing a WARN line to stderr). WARN-not-fail in the sense that a check
# never exits the process — the caller decides severity. adopt.sh escalates the
# npm-less-node return into a hard fail when there is no JS package manager at
# all; the standalone runner just counts. The detection is not duplicated between
# the two entry points; only the severity policy differs.
#
# Checks (each closes a HIMMEL-842 gap from the preflight design spec):
#   preflight_check_uv_pipx       — uv OR pipx present (gap 1: pre-commit install)
#   preflight_check_npm_invocable — npm invocable when node is (gap 2: npm-less
#                                   distro node)
#   preflight_check_jira_dist     — scripts/jira/dist/index.js + node_modules
#                                   both built (gap 3)
#
# $HIMMEL_ROOT must be set by the caller before calling the jira-dist check —
# an unset/empty $HIMMEL_ROOT WARNs and returns 1 (caller bug) rather than
# silently passing.

# Internal: print a WARN line to stderr.
preflight_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

# uv OR pipx must be present so the luna-vault setup can install pre-commit
# (PEP 668 blocks raw pip). Neither himmel's adopt.sh nor ensure-tools.sh
# auto-installs uv today, so surface the gap + the same astral.sh command used
# ad hoc in 3 other places. Returns 1 (advisory) on the gap.
preflight_check_uv_pipx() {
  if ! command -v uv >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
    preflight_warn "neither 'uv' nor 'pipx' found — the luna-vault setup's pre-commit install will fail. Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
    return 1
  fi
  return 0
}

# Ubuntu's distro 'nodejs' ships WITHOUT npm. node-without-npm breaks the
# plugin-install workflow, the lockfile/audit pre-commit gates, and a bare node
# with no package manager can't build dist/ artifacts. Returns 1 (advisory) when
# node is present but npm is not — bun covers every himmel JS build, so this is
# advisory here; adopt.sh escalates to a hard fail only when there is no JS
# package manager AT ALL (npm AND bun both absent).
preflight_check_npm_invocable() {
  if command -v node >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
    preflight_warn "'node' found but 'npm' is missing (Ubuntu's nodejs ships without npm). Install Node + npm via NodeSource: https://github.com/nodesource/distributions OR use bun: https://bun.sh (covers all himmel JS builds; required for qmd/handover)"
    return 1
  fi
  return 0
}

# scripts/jira/dist/index.js AND scripts/jira/node_modules are gitignored
# build artifacts — a fresh clone bootstrapped via adopt.sh hits
# MODULE_NOT_FOUND without dist/ (CLAUDE.md's "worktrees lack dist/" warning is
# scoped too narrowly; a fresh PRIMARY clone via adopt.sh hits the identical
# failure), and a STALE dist/ without node_modules/ passes as "already built"
# then fails at runtime (fix-batch F3: setup.sh's invariant checks BOTH, so
# this check now does too — naming which half is missing). Returns 1
# (advisory) when either is absent. Also returns 1 (fix-batch F2) when
# $HIMMEL_ROOT is unset/empty — a caller bug, not a silent pass. adopt.sh's
# build_jira_cli() builds both; this check only surfaces the gap so a
# standalone preflight run flags it up front.
preflight_check_jira_dist() {
  if [ -z "${HIMMEL_ROOT:-}" ]; then
    preflight_warn "HIMMEL_ROOT not set — jira-dist check skipped (caller bug)"
    return 1
  fi
  local jira_dir="$HIMMEL_ROOT/scripts/jira"
  local gap=""
  if [ ! -d "$jira_dir/node_modules" ] && [ ! -f "$jira_dir/dist/index.js" ]; then
    gap="scripts/jira/node_modules and scripts/jira/dist/index.js not built"
  elif [ ! -d "$jira_dir/node_modules" ]; then
    gap="scripts/jira/node_modules not installed"
  elif [ ! -f "$jira_dir/dist/index.js" ]; then
    gap="scripts/jira/dist/index.js not built"
  fi
  if [ -n "$gap" ]; then
    preflight_warn "$gap (gitignored build artifact) — the Jira CLI won't run until it is. Build it: (cd scripts/jira && npm install && npm run build)   [adopt.sh builds this automatically via build_jira_cli]"
    return 1
  fi
  return 0
}
