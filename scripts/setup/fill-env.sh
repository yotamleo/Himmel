#!/usr/bin/env bash
# fill-env.sh -- interactive fill of the must-set .env values (HIMMEL-453).
# Prompts for each UNCOMMENTED `KEY=` line in .env.example (the must-set vars;
# commented lines are opt-in -- uncomment first) and writes the answer into .env.
# Press Enter at any prompt to SKIP that var (keep its current value).
# Non-interactive stdin -> no-op with a notice.
#
# Opt-in: only runs when setup.sh/adopt.sh are passed --fill-env / -FillEnv.
# bash-only (the PS installers shell out to it) so there is ONE implementation
# operating on a plain-text file.
#
# Source-safe: defines functions on `source`, runs fill_env only on direct
# invocation. NO top-level `set -e` (it would alter a sourcing caller's shell).
#   bash fill-env.sh <env-file> [example-file]

# Strip trailing CR + surrounding whitespace (CRLF-safe; mirrors
# scripts/lib/load-dotenv.sh::_load_dotenv_trim). Pure (stdout only).
_fe_trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"   # ltrim
  s="${s%"${s##*[![:space:]]}"}"   # rtrim
  printf '%s' "$s"
}

# dotenv_get <file> <key> -- value of the first uncommented `KEY=` line, trimmed
# (CR-stripped); empty if absent.
dotenv_get() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$key="*) _fe_trim "${line#*=}"; return 0 ;; esac
  done < "$file"
}

# dotenv_set <file> <key> <value> -- replace the FIRST uncommented `KEY=` line in
# place (CRLF on that line tolerated); append `KEY=value` if absent. Idempotent.
dotenv_set() {
  local file="$1" key="$2" val="$3" tmp
  if [ -f "$file" ] && grep -qE "^${key}=" "$file"; then
    tmp="$(mktemp)"
    # Pass key/value via ENVIRON, NOT `awk -v` -- `-v` escape-processes the value
    # (a backslash or \n in a Windows path would silently corrupt the .env).
    # ENVIRON[] values are taken literally. Replace the FIRST `KEY=` line.
    FE_K="$key" FE_V="$val" awk '
      !done && index($0, ENVIRON["FE_K"] "=") == 1 { print ENVIRON["FE_K"] "=" ENVIRON["FE_V"]; done=1; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    # Ensure the file ends in a newline before appending -- a final line with no
    # trailing \n would otherwise fuse with the new KEY=value.
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >> "$file"; fi
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# fillable_keys <example-file> -- names of every UNCOMMENTED `KEY=` line, in file
# order (whole file; no section logic). CR-tolerant.
fillable_keys() {
  local file="$1" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      [A-Za-z_]*=*) printf '%s\n' "${line%%=*}" ;;
    esac
  done < "$file"
}

# fill_env <env-file> [example-file] -- interactive prompt loop.
fill_env() {
  local envfile="$1" example="${2:-}" key cur ans
  [ -n "$envfile" ] || { echo "fill-env: usage: fill_env <env-file> [example-file]" >&2; return 2; }
  [ -f "$envfile" ] || { echo "fill-env: $envfile not found" >&2; return 1; }
  [ -n "$example" ] || example="$(dirname "$envfile")/.env.example"
  [ -f "$example" ] || { echo "fill-env: $example not found" >&2; return 1; }
  if [ ! -t 0 ]; then
    echo "fill-env: non-interactive shell -- skipping (.env left as-is)." >&2
    return 0
  fi
  echo "Fill .env values (press Enter to skip / keep current):"
  while IFS= read -r key; do
    cur="$(dotenv_get "$envfile" "$key")"
    printf '  %s [%s]: ' "$key" "$cur"
    IFS= read -r ans || ans=""
    if [ -n "$ans" ]; then
      dotenv_set "$envfile" "$key" "$ans" || echo "  WARNING: could not write $key" >&2
    fi
  done < <(fillable_keys "$example")
  echo "  done."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fill_env "$@"
fi
