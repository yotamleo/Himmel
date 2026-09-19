#!/usr/bin/env bash
# scripts/lib/override-env.sh -- the ONE list of guard-override environment
# variables, and the scrub that unsets them inside a test process (HIMMEL-3092).
#
# SOURCED, never executed. bash 3.2-safe (no mapfile, no associative arrays).
# Platform guard (gitbash-only): pure bash builtins + grep/sed/sort; sourced by
# suites that already run under Git Bash on Windows. No .ps1 twin needed.
#
# WHY: a console-spawned leg's shell exports guard overrides (INLINE_IMPL_OK,
# IMPL_GUARD_OK, HIMMEL_CONSOLE_LEG by console-kit/headed-arm-leg.sh;
# CLAUDE_CODE_CHILD_SESSION by claude itself; HIMMEL_HOOK_INTEGRITY_BYPASS_OK by
# the operator for a hooks-touching leg). A hook suite that invokes the hook
# under test with a plain `bash "$HOOK"` inherits them, so every case that means
# "override UNSET, the guard should FIRE" takes the override arm instead: 63 of
# 132 inline-guard cases and 41 of 90 hook-integrity (tamper-detection) cases
# went red -- or, worse, passed through a bypass and asserted nothing.
#
# The overrides are real operator levers and keep their semantics. This lib only
# clears them from the ENVIRONMENT OF A TEST PROCESS: the runner calls
# scrub_override_env once per suite subshell, and each suite whose hook reads an
# override calls it at its top. A case that needs an override sets it explicitly
# on its own invocation, exactly as before. Never call it from an interactive or
# leg shell -- it would unset the operator's own levers.
#
# THE LIST CANNOT DRIFT SILENTLY: scripts/lib/test-override-env.sh scans every
# non-test hook/guardrail/lib script for a `$..._OK` read and fails when one is
# missing from the list below (override_env_undeclared).

# Guard overrides read as a shell variable expansion or a JS process-env property named NAME_OK by a hook,
# guardrail or lib script. MCP_<SERVICE>_OK is per-service and dynamic
# (block-backend-tier.sh), so scrub_override_env also clears every `MCP_*_OK`.
HIMMEL_OVERRIDE_ENV_OK_VARS="GRAPHIFY_SALUS_LOCAL_OK GH_ADMIN_MERGE_OK EDIT_ON_MAIN_OK
FIND_ROOTWALK_OK MCP_ALL_OK MCP_JIRA_OK MCP_BITBUCKET_OK MCP_GITHUB_OK
ENV_PREFIX_GUARD_OK DESTRUCTIVE_OK DOCKER_PRIVESC_OK EDIT_LIVE_SETTINGS_OK
GIT_STASH_OK GLM_EXTERNAL_WRITES_OK HIMMEL_HOOK_INTEGRITY_BYPASS_OK
JIRA_COMPOUND_WRITE_OK MERGED_PR_COMMIT_OK PR_CHECK_ARGS_OK READ_SECRETS_OK
ROGUE_SCHEDULE_OK CODEX_EXEC_RAW_OK CODEX_WSL_RAW_OK CODEX_EXTERNAL_WRITES_OK
CADENCE_POWERSHELL_OK AGENTS_MD_OK PUSH_FOREIGN_REF_OK DOC_GUARD_OK
DOCTOR_CHECK_IDS_OK GRAPH_COMMIT_OK HOOKSPATH_OK LANES_GUARD_OK
MAIN_REF_TRANSACTION_OK NEW_SHELL_PLATFORM_GUARD_OK PLATFORMS_TESTED_OK
TEMPLATE_VERSION_OK CONSOLE_DISPATCH_OK IMPL_GUARD_OK MEMORY_CAPTURE_OK
SUBAGENT_MODEL_OK INLINE_IMPL_OK HIMMEL_READ_CLAMP_OK FLEET_CAP_OK
CI_MERGE_GATE_OK CR_MERGE_GATE_OK GRAPHIFY_UNPROBED_OK"

# Overrides / leg markers that do not end in _OK, so the scan cannot find them.
HIMMEL_OVERRIDE_ENV_MARKERS="IMPL_GUARD_DISABLE HIMMEL_CONSOLE_LEG CLAUDE_CODE_CHILD_SESSION"

# Variable reads named LIB_OK or HOOK_OK are internal flags, not overrides -- exempt from the scan.
HIMMEL_OVERRIDE_ENV_INTERNAL="LIB_OK HOOK_OK"

# scrub_override_env -- unset every listed override in the CURRENT process.
# Call it only inside a test suite or a runner subshell (see WHY).
scrub_override_env() {
  local _v
  for _v in $HIMMEL_OVERRIDE_ENV_OK_VARS $HIMMEL_OVERRIDE_ENV_MARKERS; do
    unset "$_v"
  done
  for _v in $(compgen -e); do
    case "$_v" in
      MCP_*_OK) unset "$_v" ;;
    esac
  done
  return 0
}

# override_env_undeclared <file>... -- print (sorted, unique) every shell expansion or
# JS process-env read (dot or quoted-bracket notation) of an _OK name in the given
# files that is in neither the override
# list nor the internal-flag exemptions. Empty output = the list is complete for
# those files. Reads only; safe to run anywhere.
override_env_undeclared() {
  local _f _v
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    grep -ohE '(\$\{?|env\.)[A-Z][A-Z0-9_]*_OK([^A-Za-z0-9_]|$)|env\[[[:space:]]*["'"'"'][A-Z][A-Z0-9_]*_OK["'"'"'][[:space:]]*\]' "$_f" 2>/dev/null
  done | sed -E 's/^(\$\{?|env\.|env\[[[:space:]]*.)//; s/[^A-Za-z0-9_].*$//' | sort -u | while IFS= read -r _v; do
    case " $HIMMEL_OVERRIDE_ENV_OK_VARS $HIMMEL_OVERRIDE_ENV_MARKERS $HIMMEL_OVERRIDE_ENV_INTERNAL " in
      *[[:space:]]"$_v"[[:space:]]*) ;;
      *) printf '%s\n' "$_v" ;;
    esac
  done
  return 0
}
