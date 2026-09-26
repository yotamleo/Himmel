#!/usr/bin/env bash
# usage-cache-identity.sh — HIMMEL-1712 shared account-identity helper.
#
# Single source for the sha256-hashed account identity stamped onto and
# compared against scripts/statusline/usage-cache-producer.sh's cache. Never
# writes or prints the raw accountUuid or email — hash only.
#
# current_account_hash [config_path]
#   Prints a 16-hex-char sha256 prefix of the CURRENT account identity, read
#   fresh from ~/.claude.json's .oauthAccount.accountUuid ($1, else
#   $CLAUDE_ACCOUNT_CONFIG, else $HOME/.claude.json). Empty output means the
#   identity is undeterminable (missing file/jq/field/sha256 tool) — callers
#   must treat that the same as a mismatch.
#
# usage_cache_account_mismatch <cache_file>
#   Returns 0 (mismatch/UNKNOWN — do not trust the cache) when the cache's
#   .account is missing/empty, the current identity is undeterminable, or the
#   two differ. Returns 1 (trusted match) only when both are present and equal.

_usage_cache_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# shellcheck disable=SC2120 # optional $1 override; every in-repo caller wants the default
current_account_hash() {
  local config="${1:-${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude.json}}" uuid hash
  command -v jq >/dev/null 2>&1 || return 0
  [ -r "$config" ] || return 0
  uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$config" 2>/dev/null)
  [ -n "$uuid" ] || return 0
  hash=$(_usage_cache_sha256 "$uuid") || return 0
  printf '%s' "$hash" | cut -c1-16
}

usage_cache_account_mismatch() {
  local cache="$1" cached current
  command -v jq >/dev/null 2>&1 || return 0
  cached=$(jq -r '.account // empty' "$cache" 2>/dev/null)
  [ -n "$cached" ] || return 0
  # shellcheck disable=SC2119 # default $1 (no override) is intended here
  current=$(current_account_hash)
  [ -n "$current" ] || return 0
  [ "$cached" = "$current" ] && return 1
  return 0
}
