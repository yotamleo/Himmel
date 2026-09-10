#!/usr/bin/env bash
# wire-pretooluse-hooks.sh -- merge himmel's UNIVERSAL hooks into a Claude Code
# settings.json idempotently (HIMMEL install/uninstall symmetry). Extracted from
# adopt.sh's wire_settings so setup.sh and adopt.sh share ONE implementation.
#
# Two functions:
#   wire_pretooluse_hooks <settings> <prefix> [<dry_run>]
#       Wire the PreToolUse trio (auto-approve-safe-bash, block-edit-on-main,
#       block-read-secrets), each as its own matcher stanza.
#   wire_sessionstart_hook <settings> <prefix> <hook-basename> [<dry_run>]
#       Wire ONE SessionStart hook object (e.g. inject-initiative.sh) into the
#       shared SessionStart hooks[] array.
#
# $prefix = command path prefix (literal, e.g. '$CLAUDE_PROJECT_DIR' for project
# scope or the himmel abs path for user scope). The hook path is FORWARD-SLASHED
# and QUOTED in the command: an unquoted Windows backslash path
# (`bash C:\Users\...\X.sh`) collapses when the hook command is parsed by a shell
# (`\U`->`U`), so the hook silently never fires.
#
# Dedup is by hook BASENAME with REPLACE semantics: re-running overwrites a
# previously-wired (incl. broken backslash, or moved-clone) himmel hook rather
# than appending a duplicate -- so a re-run repairs a bad install and never
# double-wires, even when the clone path changed (SC8).
#
# The PreToolUse block MERGES; it is never regenerated (HIMMEL-2892). himmel
# owns exactly ONE field of an entry it installed -- that entry's `command`
# string, which is what makes the moved-clone/backslash repair above possible.
# Everything else belongs to the adopter and survives byte-for-byte: the
# stanza's `matcher` (never collapsed to the canonical string), the stanza's
# POSITION in the array, the entry's `timeout` and any other key it carries,
# and every foreign stanza or co-located foreign entry. A canonical stanza is
# APPENDED only for a himmel hook the target carries no entry for at all.
# Before this, the trio was deleted and three canonical stanzas re-appended --
# which silently rewrote a hand-curated hook block on any adopter who had one
# (the 2026-09-09 dogfood incident: matchers dropped, timeouts 60 -> 15).
#
# Reads NO script globals (the dry-run flag is an explicit param). Requires jq.
# Source it to call the functions directly, or invoke via bash (the BASH_SOURCE
# guard below dispatches `wire-pretooluse-hooks.sh <settings> <prefix>`).
set -euo pipefail

# The merge program, shared verbatim with the PowerShell twin
# (wire-pretooluse-hooks.ps1) so the two can never drift. For each spec, walk
# the PreToolUse array in order: the FIRST entry whose command matches the
# spec's `pat` has its `command` rewritten IN PLACE (its object, its stanza and
# their key order untouched); any LATER duplicate is dropped (dedup), and a
# stanza left with no entries goes with it. If no entry matched at all, the
# spec's canonical stanza is appended.
# shellcheck disable=SC2016  # a jq program: $spec/$st/$h/$r/$acc/$specs are jq bindings, not shell expansions
WIRE_PRETOOLUSE_MERGE_JQ='
  def wire($spec):
    (reduce .[] as $st ({seen: false, out: []};
       (reduce ($st.hooks // [])[] as $h ({seen: .seen, hooks: []};
          if (($h.command // "") | test($spec.pat))
          then (if .seen
                then .
                else {seen: true, hooks: (.hooks + [$h | .command = $spec.cmd])}
                end)
          else {seen: .seen, hooks: (.hooks + [$h])}
          end)) as $r
       | {seen: $r.seen,
          out: (.out + (if ($r.hooks | length) > 0 then [$st | .hooks = $r.hooks] else [] end))}
     )) as $acc
    | if $acc.seen then $acc.out else ($acc.out + [$spec.stanza]) end;
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (reduce $specs[] as $spec ((.hooks.PreToolUse // []); wire($spec)))
'

wire_pretooluse_hooks() {
  local settings="$1" prefix="$2" dry_run="${3:-0}"
  command -v jq >/dev/null 2>&1 || { echo "wire-pretooluse-hooks: jq required" >&2; return 1; }
  # shellcheck disable=SC1003  # '\' is a literal backslash to replace, not a quote escape
  local pfx="${prefix//'\'//}"   # forward-slash any backslashes in the prefix
  # One spec per himmel-owned hook. `pat` identifies an entry THIS installer
  # owns (by the hook path it installs); `cmd` is the command such an entry
  # must carry after the merge; `stanza` is the canonical stanza appended when
  # the target carries no such entry at all.
  local specs
  specs=$(cat <<JSON
[
  {"pat":"scripts/hooks/auto-approve-safe-bash[.]sh",
   "cmd":"bash \"${pfx}/scripts/hooks/auto-approve-safe-bash.sh\"",
   "stanza":{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${pfx}/scripts/hooks/auto-approve-safe-bash.sh\""}]}},
  {"pat":"scripts/hooks/block-edit-on-main[.]sh",
   "cmd":"bash \"${pfx}/scripts/hooks/block-edit-on-main.sh\"",
   "stanza":{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash \"${pfx}/scripts/hooks/block-edit-on-main.sh\""}]}},
  {"pat":"scripts/hooks/block-read-secrets[.]sh",
   "cmd":"bash \"${pfx}/scripts/hooks/block-read-secrets.sh\"",
   "stanza":{"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash \"${pfx}/scripts/hooks/block-read-secrets.sh\""}]}}
]
JSON
)
  if [[ "$dry_run" -eq 1 ]]; then
    echo "DRY: merge 3 PreToolUse hook stanzas into $settings (prefix: $prefix)"
    return
  fi
  mkdir -p "$(dirname "$settings")"
  local base="{}"
  [[ -f "$settings" ]] && base=$(cat "$settings")
  if [ -n "$(printf '%s' "$base" | tr -d '[:space:]')" ] && ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "wire-pretooluse-hooks: $settings is not valid JSON -- refusing to overwrite" >&2
    return 1
  fi
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && base="{}"
  printf '%s' "$base" | jq --argjson specs "$specs" "$WIRE_PRETOOLUSE_MERGE_JQ" \
    > "$settings.wirehooks.tmp" && mv "$settings.wirehooks.tmp" "$settings"
  echo "  wired PreToolUse hooks -> $settings"
}

# Wire ONE SessionStart hook object (by basename) into the shared
# .hooks.SessionStart[].hooks[] array. SessionStart hooks co-reside under a single
# matcher-less stanza (in himmel's project settings inject-initiative.sh sits
# beside check-update-available.sh), so we operate at the hook-OBJECT level:
# strip any existing object whose command basename matches (REPLACE), then append
# a fresh one into the first matcher-less stanza, or create a standalone stanza if
# none exists. Dedup-by-basename keeps a moved clone from double-wiring (SC8).
wire_sessionstart_hook() {
  local settings="$1" prefix="$2" basename="$3" dry_run="${4:-0}"
  command -v jq >/dev/null 2>&1 || { echo "wire-pretooluse-hooks: jq required" >&2; return 1; }
  # shellcheck disable=SC1003
  local pfx="${prefix//'\'//}"
  local cmd="bash \"${pfx}/scripts/hooks/${basename}\""
  local basepat="scripts/hooks/${basename//./[.]}"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "DRY: merge SessionStart hook $basename into $settings (prefix: $prefix)"
    return
  fi
  mkdir -p "$(dirname "$settings")"
  local base="{}"
  [[ -f "$settings" ]] && base=$(cat "$settings")
  if [ -n "$(printf '%s' "$base" | tr -d '[:space:]')" ] && ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "wire-pretooluse-hooks: $settings is not valid JSON -- refusing to overwrite" >&2
    return 1
  fi
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && base="{}"
  printf '%s' "$base" | jq --arg cmd "$cmd" --arg basepat "$basepat" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = ((.hooks.SessionStart // [])
        | map(.hooks = ((.hooks // [])
            | map(select((.command // "") | test($basepat) | not))))
        | map(select((.hooks | length) > 0)))
    | (.hooks.SessionStart | map(has("matcher") | not) | index(true)) as $idx
    | if $idx == null
      then .hooks.SessionStart += [{"hooks":[{"type":"command","command":$cmd}]}]
      else .hooks.SessionStart[$idx].hooks += [{"type":"command","command":$cmd}]
      end
  ' > "$settings.wirehooks.tmp" && mv "$settings.wirehooks.tmp" "$settings"
  echo "  wired SessionStart $basename -> $settings"
}

# Allow both `source wire-pretooluse-hooks.sh` (to call the functions directly,
# e.g. from adopt.sh which is already `set -euo pipefail`) and direct invocation.
# Callers that DON'T want this lib's `set -euo pipefail` to leak into their shell
# (e.g. setup.sh, which runs `set -e` only) invoke it as a subprocess:
#   bash wire-pretooluse-hooks.sh <settings> <prefix> [<dry>]            # PreToolUse trio
#   bash wire-pretooluse-hooks.sh --sessionstart <settings> <prefix> <basename> [<dry>]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--sessionstart" ]; then
    shift
    if [ "$#" -lt 3 ]; then
      echo "usage: wire-pretooluse-hooks.sh --sessionstart <settings> <prefix> <hook-basename> [<dry_run>]" >&2
      exit 2
    fi
    wire_sessionstart_hook "$1" "$2" "$3" "${4:-0}"
  else
    if [ "$#" -lt 2 ]; then
      echo "usage: wire-pretooluse-hooks.sh <settings-json-path> <command-prefix> [<dry_run>]" >&2
      exit 2
    fi
    wire_pretooluse_hooks "$1" "$2" "${3:-0}"
  fi
fi
