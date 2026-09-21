#!/usr/bin/env bash
# wire-himmel-repo.sh -- set env.HIMMEL_REPO in a Claude Code settings.json to
# the himmel clone path (HIMMEL-453). The leg resolver + minerva transport anchor
# to HIMMEL_REPO (marketplace/plugins/himmel-ops/scripts/legs.sh); setup.sh and
# adopt.sh call this so it is set without a manual export. Sibling of
# wire-statusline.sh -- same shape, different key.
#
# Usage:
#   bash wire-himmel-repo.sh <settings-json-path> <himmel-path>
#
# Sets:
#   .env.HIMMEL_REPO = "<himmel-path forward-slashed>"   (all other .env keys
#   preserved -- HIMMEL_INITIATIVE etc. are never clobbered).
#
# Idempotent (re-setting the same value is a no-op), atomic (temp file + mv),
# non-destructive (other keys preserved; file + parent dir created if absent).
# Requires jq. Invoked via bash, never sourced.
set -euo pipefail

# HIMMEL-3332: record the settings write in the install-provenance ledger
# (docs/internals/install-provenance.md). Runs after the mv with the PRE-write
# JSON in $2: a new key is `create`, the same value is `noop`, a different one
# is `replace` with the prior value backed up. A wire that had to create `.env`
# also records `/env`, so uninstall may drop the emptied parent.
# shellcheck source=scripts/lib/provenance.sh
. "$(dirname "${BASH_SOURCE[0]}")/provenance.sh"

# user when the settings file sits in the Claude config dir, else project.
_wire_himmel_repo_scope() {
  local d c
  d="$(cd "$(dirname "$1")" && pwd -P)"
  for c in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    if [ -n "$c" ] && [ "$d" = "$(cd "$c" 2>/dev/null && pwd -P)" ]; then echo user; return 0; fi
  done
  echo project
}

# _wire_himmel_repo_record <settings> <pre-write settings JSON> <env key> <value>
_wire_himmel_repo_record() {
  local settings="$1" base="$2" key="$3" val="$4" scope new old op had_env
  local -a pre
  scope="$(_wire_himmel_repo_scope "$settings")" || return 1
  new="$(jq -nc --arg v "$val" '$v')"
  had_env="$(printf '%s' "$base" | jq -r 'if .env == null then "0" else "1" end')"
  old="$(printf '%s' "$base" | jq -c --arg k "$key" 'select((.env | type == "object") and (.env | has($k))) | .env[$k]')"
  if [ -z "$old" ]; then op=create; pre=(--pre-absent)
  elif [ "$(printf '%s' "$old" | jq -cS .)" = "$new" ]; then op=noop; pre=(--pre-json "$old")
  else op=replace; pre=(--pre-json "$old" --backup); fi
  if [ "$had_env" = 0 ]; then
    prov_record create json-key "$settings" --unit /env --scope "$scope" --class code \
      --row "$scope-settings" --writer wire-himmel-repo.sh --pre-absent \
      --post-json "$(jq -c .env "$settings")" || return 1
  fi
  prov_record "$op" json-key "$settings" --unit "/env/$key" --scope "$scope" --class code \
    --row "$scope-settings" --writer wire-himmel-repo.sh "${pre[@]}" --post-json "$new"
}

wire_himmel_repo() {
  local settings="$1" himmel="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-himmel-repo: jq required" >&2; return 1; }

  # Forward-slash the himmel path so the stored value is a valid Git-Bash path
  # even when a caller passes a Windows backslash path.
  local himmel_fwd="${himmel//\\//}"

  mkdir -p "$(dirname "$settings")"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file -> treat as {} (jq would choke on it).
    # A non-empty but INVALID file -> refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-himmel-repo: $settings is not valid JSON -- refusing to overwrite" >&2
      return 1
    fi
  fi

  if printf '%s' "$base" | jq --arg repo "$himmel_fwd" \
    '.env = ((.env // {}) + { HIMMEL_REPO: $repo })' \
    > "$settings.himmelrepo.tmp" && mv "$settings.himmelrepo.tmp" "$settings"; then
    _wire_himmel_repo_record "$settings" "$base" HIMMEL_REPO "$himmel_fwd" \
      || echo "wire-himmel-repo: warning: provenance record failed (env.HIMMEL_REPO is wired; uninstall will keep it)" >&2
  else
    return 1   # the write failed: never echo success (matches the pre-record `&&` under set -e)
  fi
  echo "  set env.HIMMEL_REPO -> $settings"
}

# Allow both `source wire-himmel-repo.sh` (to call wire_himmel_repo directly) and
# direct invocation `bash wire-himmel-repo.sh <settings> <himmel>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-himmel-repo.sh <settings-json-path> <himmel-path>" >&2
    exit 2
  fi
  wire_himmel_repo "$1" "$2"
fi
