#!/usr/bin/env bash
# resolve-user-home.sh — cross-platform user-home + default-vault resolution
# (HIMMEL-645/642/458), extracted verbatim from scripts/luna/pipeline-cadence.sh
# (HIMMEL-2176 Stage 1) so other cadence scripts can share it instead of
# carrying their own copy.
#
# CANONICAL copy of the cross-platform home/vault resolution. HIMMEL-2176
# (spec A16) deliberately converted scripts/luna/pipeline-cadence.sh ONLY;
# the remaining copies — including cadence-format.sh's byte-identical
# cadence_user_home() — are converted by HIMMEL-2253.
#
# Sourced, not executed. bash 3.2-safe; no side effects.

# Cross-platform user-home resolution (HIMMEL-645, generalized from
# HIMMEL-642's default_vault). On Windows Git-Bash $HOME can be the MSYS home
# (/home/<user>) while Claude Code's config (~/.claude) and the luna vault live
# under the Windows user profile, so prefer USERPROFILE via cygpath BEFORE
# $HOME. POSIX hosts have USERPROFILE unset and fall straight through to $HOME,
# unchanged. /tmp is the last-resort floor when both are unset.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Default vault resolution (cross-platform; HIMMEL-642). Honors
# LUNA_VAULT_PATH first — the vault path adopt.sh persists into
# .claude/settings.json (HIMMEL-458) and himmel-doctor probes first — so an
# adopted setup needs no --vault. Otherwise fall back to <home>/Documents/luna
# via the shared cross-platform home resolver (HIMMEL-645). Explicit --vault
# always overrides (parsed by the caller).
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}
