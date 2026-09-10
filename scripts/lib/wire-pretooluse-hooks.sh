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
# The command is a SHELL string, so the path is also SHELL-ESCAPED for the
# double-quoted context it lands in -- see WIRE_HOOK_CMD_JQ below (HIMMEL-2905).
#
# Dedup is by hook BASENAME with REPLACE semantics: re-running overwrites a
# previously-wired (incl. broken backslash, or moved-clone) himmel hook rather
# than appending a duplicate -- so a re-run repairs a bad install and never
# double-wires, even when the clone path changed (SC8).
#
# The PreToolUse block MERGES; it is never regenerated (HIMMEL-2892). himmel
# owns exactly ONE field of an entry it installed -- that entry's `command`
# string, which is what makes the moved-clone/backslash repair above possible.
# A hook registered under two DISTINCT matchers keeps BOTH registrations (dedup
# is per matcher, not per hook -- CR round 1, [codex-1]); only a repeat under a
# matcher that already carries it is dropped as a double-wire.
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

# The hook-command composer, shared verbatim with the PowerShell twin
# (wire-pretooluse-hooks.ps1) -- BOTH the PreToolUse specs and the SessionStart
# hook object are built through it, so the two composers can never drift.
#
# HIMMEL-2892 round 6 / HIMMEL-2905: the JSON layer is escaped by jq, but the
# `command` it carries is a SHELL string that Claude Code hands to a shell. It
# lands inside DOUBLE quotes, where exactly four characters keep their meaning
# -- `\`, `"`, `$` and a backtick -- so shesc() backslash-escapes those four
# and nothing else. Before this, a checkout at e.g. `/opt/we"ird/clone` yielded
# `bash "/opt/we"ird/clone/.../X.sh"`, whose unmatched quote is a syntax error:
# the hook never ran and every installed guard was silently inert there.
# (Backslashes are already forward-slashed by the callers; escaping them keeps
# the rule complete for the double-quoted context rather than relying on that.)
#
# The ONE exemption is the project-scope prefix, which is the literal,
# UNEXPANDED `$CLAUDE_PROJECT_DIR` -- Claude Code expands it at hook-fire time,
# so escaping its `$` (or single-quoting the whole path) would point every
# project-scope hook at a path that does not exist. That literal is a fixed,
# metacharacter-free string by construction, so passing it through untouched is
# safe. $rel — the hook BASENAME — carries no such exemption and is escaped
# unconditionally: it is an ARGUMENT of the public wire_sessionstart_hook (and
# of the `--sessionstart` CLI), not a hardcoded literal like the trio's names,
# so the rule has to cover it or it is only half a rule (CodeRabbit, PR #612).
# Every real basename is metacharacter-free, so this changes no emitted command.
#
# Escaping-in-double-quotes rather than switching to single quotes also
# keeps the emitted command byte-identical for every ordinary path, so the
# consumers that pattern-match it (unwire, detect-hook-dup, setup-wire) and
# every already-installed settings.json are unaffected.
# shellcheck disable=SC2016  # a jq program: $p/$pfx/$rel are jq bindings, not shell expansions
WIRE_HOOK_CMD_JQ='
  def shesc($p):
    $p | split("\\") | join("\\\\")
       | split("\"") | join("\\\"")
       | split("$")  | join("\\$")
       | split("`")  | join("\\`");
  def hookcmd($pfx; $rel):
    "bash \"" + (if $pfx == "$CLAUDE_PROJECT_DIR" then $pfx else shesc($pfx) end)
    + "/scripts/hooks/" + shesc($rel) + "\"";
'

# The merge program, shared verbatim with the PowerShell twin
# (wire-pretooluse-hooks.ps1) so the two can never drift. For each spec, walk
# the PreToolUse array in order and rewrite the `command` of every entry that
# matches the spec's `pat` IN PLACE (its object, its stanza and their key order
# untouched). If no entry matched at all, the spec's canonical stanza is
# appended.
#
# Dedup is per (spec, MATCHER), not per spec (HIMMEL-2892 CR round 1,
# [codex-1]). A hook registered under two DISTINCT matchers -- e.g.
# block-edit-on-main under a bare `Edit` stanza AND a bare `Write` one -- is two
# genuinely different registrations, and keeping only the first silently drops
# the second's tool coverage (the pre-merge code never had this failure mode: it
# deleted both and appended one canonical stanza covering every tool). So a
# matcher is recorded the first time it carries the spec, and only a REPEAT
# under a matcher already carrying it is dropped as a true double-wire. A stanza
# left with no entries goes with them.
# shellcheck disable=SC2016  # a jq program: $spec/$st/$h/$r/$acc/$m/$specs are jq bindings, not shell expansions
WIRE_PRETOOLUSE_MERGE_JQ='
  def wire($spec):
    (reduce .[] as $st ({seen: [], out: []};
       ($st.matcher) as $m
       | (reduce ($st.hooks // [])[] as $h ({seen: .seen, hooks: []};
            if (($h.command // "") | test($spec.pat))
            then (if (.seen | any(. == $m))
                  then .
                  else {seen: (.seen + [$m]), hooks: (.hooks + [$h | .command = $spec.cmd])}
                  end)
            else {seen: .seen, hooks: (.hooks + [$h])}
            end)) as $r
       | {seen: $r.seen,
          out: (.out + (if ($r.hooks | length) > 0 then [$st | .hooks = $r.hooks] else [] end))}
     )) as $acc
    | if ($acc.seen | length) > 0 then $acc.out else ($acc.out + [$spec.stanza]) end;
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
  #
  # Built with `jq -n --arg pfx`, never by interpolating $pfx into JSON TEXT
  # (CodeRabbit round 1): a POSIX path may legally contain a `"`, which makes
  # hand-written JSON malformed, and `jq --argjson specs` then rejects the
  # argument outright — the settings file goes unwired. Passing the prefix as a
  # jq --arg lets jq do the escaping, for quotes, backslashes and newlines
  # alike. Shared verbatim with the PowerShell twin.
  local specs
  # shellcheck disable=SC2016  # a jq program: $pfx/$cmd/$name/$matcher are jq bindings, not shell expansions
  specs=$(jq -n --arg pfx "$pfx" "$WIRE_HOOK_CMD_JQ"'
    def spec($name; $matcher):
      hookcmd($pfx; $name + ".sh") as $cmd
      | { pat: ("scripts/hooks/" + $name + "[.]sh"),
          cmd: $cmd,
          stanza: { matcher: $matcher, hooks: [ { type: "command", command: $cmd } ] } };
    [ spec("auto-approve-safe-bash"; "Bash"),
      spec("block-edit-on-main"; "Edit|Write|MultiEdit|NotebookEdit"),
      spec("block-read-secrets"; "Bash|PowerShell|Read|Grep") ]
  ') || return 1
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
  # The command is composed by jq (hookcmd), not by bash string interpolation,
  # so the SessionStart hook carries exactly the same shell escaping as the
  # PreToolUse trio and the PowerShell twin (HIMMEL-2905). The dedup test is
  # built from the SAME escaped string, inside the same jq program, so the two
  # can never disagree — see the filter below.
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
  # Dedup is a LITERAL substring test on the ESCAPED basename, not a regex on
  # the raw one (CR round 3, [codex-1]). Escaping the basename in the command
  # (the CodeRabbit fix above) left the old `test("scripts/hooks/<raw>[.]sh")`
  # pattern unable to match its own output, so a re-run APPENDED a duplicate
  # instead of replacing — measured: 2 hook objects after two wires. Deriving
  # the needle from the same shesc() the command uses makes disagreement
  # impossible, and `contains` needs no regex-escaping at all, which the old
  # `${basename//./[.]}` only ever did for `.` anyway.
  # shellcheck disable=SC2016  # a jq program: $pfx/$hook/$cmd are jq bindings
  printf '%s' "$base" | jq --arg pfx "$pfx" --arg hook "$basename" \
    "$WIRE_HOOK_CMD_JQ"'
    hookcmd($pfx; $hook) as $cmd
    | ("scripts/hooks/" + shesc($hook)) as $needle
    | .hooks = (.hooks // {})
    | .hooks.SessionStart = ((.hooks.SessionStart // [])
        | map(.hooks = ((.hooks // [])
            | map(select((.command // "") | contains($needle) | not))))
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
