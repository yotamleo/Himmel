#!/usr/bin/env bash
# Pure vault-root resolver for the end-session-wiki hook (HIMMEL-403).
# bash 3.2-safe. No eval. Source it, then call resolve_vault_root.
#
#   resolve_vault_root <config_json> <registry_json> [<dry_run>]
#     echoes the resolved vault root (a leading "~/" is left LITERAL for the
#     caller to expand once) OR an empty string => the caller must skip (log,
#     no write). Always returns 0; emptiness is the skip signal.
#
# Resolution order (first match wins):
#   1. config.vault_path (existing absolute key)
#   2. config.vault NAME (validated) -> registry[name] -> else ~/Documents/<name>
#      (the convention path is used only if it exists with an .obsidian/ marker,
#       or in dry-run); an invalid name or no real vault => empty (skip).
#   3. LUNA_VAULT_PATH env
#   4. default: registry["luna"] -> else ~/Documents/luna

# Emit a file's text with a leading UTF-8 BOM (EF BB BF) stripped, if present.
# A BOM makes jq treat the file as invalid JSON, so the resolver would skip and
# the hook would silently stop capturing (HIMMEL-408). bash 3.2-safe (ANSI-C
# quoting + prefix removal); no GNU-only sed.
_vault_debom() { # <file>
  local c
  c="$(cat "$1" 2>/dev/null)" || return 1
  printf '%s' "${c#$'\xef\xbb\xbf'}"
}

# Read a string from a jq filter (no --arg); empty on any error or json null.
_vault_jq() { # <file> <filter>
  [ -r "$1" ] || { printf ''; return; }
  local v
  v="$(_vault_debom "$1" | jq -r "$2" 2>/dev/null)"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

# Validate an untrusted vault name (it travels in a tracked, cloned file).
_vault_name_valid() { # <name>  -> 0 valid / 1 invalid
  [ "${#1}" -le 64 ] || return 1     # length cap (mirrors the PS twin's {0,63})
  case "$1" in
    '' | . | ..) return 1 ;;
    *..*) return 1 ;;                 # no ".." substring
    [!A-Za-z0-9]*) return 1 ;;        # must start alphanumeric (blocks -, ., ~)
    *[!A-Za-z0-9._-]*) return 1 ;;    # charset allowlist
  esac
  return 0
}

resolve_vault_root() { # <config_json> <registry_json> [<dry_run>]
  local config="$1" registry="$2" dry_run="${3:-false}"
  local cfg_vault_path has_vault cfg_vault reg conv def

  # Fail-closed: skip if the config exists but is not a valid JSON OBJECT —
  # invalid JSON, an empty file, or a non-object (null/false/[]/"str"/42). A
  # config the hook can't read as the expected object must not silently leak a
  # (possibly sensitive) repo's transcript into the default vault. `type` here
  # is true only for an object, so this also rejects jq's falsy null/false
  # (which `jq -e .` would have mis-handled and which the PS twin parses cleanly).
  if [ -r "$config" ] && ! _vault_debom "$config" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf ''
    return 0
  fi

  # 1. explicit absolute vault_path (existing key) wins.
  cfg_vault_path="$(_vault_jq "$config" 'if has("vault_path") then .vault_path else "" end | tostring')"
  if [ -n "$cfg_vault_path" ]; then
    printf '%s\n' "$cfg_vault_path"
    return 0
  fi

  # 2. per-repo vault NAME (validated, fail-closed). A PRESENT key (even empty)
  #    enters this branch; only an absent key falls through to steps 3-4.
  has_vault="$(_vault_jq "$config" 'has("vault") | tostring')"
  cfg_vault="$(_vault_jq "$config" 'if has("vault") then .vault else "" end | tostring')"
  if [ "$has_vault" = "true" ]; then
    _vault_name_valid "$cfg_vault" || { printf ''; return 0; }   # invalid/empty => skip
    # 2a. operator registry name -> path
    if [ -r "$registry" ]; then
      # String values only — an array/object value must not be flattened into a
      # multi-line garbage path (mirrors the PS twin's `-is [string]` guard).
      reg="$(_vault_debom "$registry" | jq -r --arg n "$cfg_vault" '(.vaults[$n]?) as $v | if ($v | type) == "string" then $v else "" end' 2>/dev/null)"
    else
      reg=""
    fi
    if [ -n "$reg" ]; then
      case "$reg" in *..*) printf ''; return 0 ;; esac          # reject traversal
      # shellcheck disable=SC2088  # the "~/" is a literal case-pattern, not an expansion
      case "$reg" in /* | "~/"*) ;; *) printf ''; return 0 ;; esac  # require absolute (or ~/)
      printf '%s\n' "$reg"
      return 0
    fi
    # 2b. convention ~/Documents/<name>, require an .obsidian/ marker (unless dry-run).
    conv="$HOME/Documents/$cfg_vault"
    if [ "$dry_run" = "true" ] || [ -d "$conv/.obsidian" ]; then
      printf '%s\n' "$conv"
      return 0
    fi
    printf ''                                                    # declared but no real vault => skip
    return 0
  fi

  # 3. LUNA_VAULT_PATH env.
  if [ -n "${LUNA_VAULT_PATH:-}" ]; then
    printf '%s\n' "$LUNA_VAULT_PATH"
    return 0
  fi

  # 4. default: registry["luna"] else ~/Documents/luna.
  def="$(_vault_jq "$registry" '.vaults.luna // ""')"
  if [ -n "$def" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  printf '%s\n' "$HOME/Documents/luna"
  return 0
}
