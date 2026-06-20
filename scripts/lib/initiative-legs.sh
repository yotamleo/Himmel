#!/usr/bin/env bash
# scripts/lib/initiative-legs.sh — pure leg resolver (HIMMEL-443).
#
# Single source of truth for the harness-autonomy "leg grammar". Maps the
# relevant env values (passed as NAMED ARGUMENTS, never ambient reads, so the
# same function is callable from the SessionStart hook AND from minerva's
# plugin-side transport wrapper) to a normalized, canonical-ordered, deduped
# active leg set.
#
# Profiles:
#   - interactive (default):        var = HIMMEL_INITIATIVE,           all = 4 legacy legs
#   - overnight (selector truthy):  var = HIMMEL_INITIATIVE_OVERNIGHT, all = 6 legs
#
# `plan` is a reserved vocabulary token (recognized, no behavior yet).
#
# Usage: resolve_legs <initiative_val> <overnight_val> <overnight_selector>
# Echoes the active legs space-separated in canonical order, or empty string.

# Canonical vocabulary order — every emitted set is filtered through this.
_IL_VOCAB="plan execute prcheck pr ticket merge public handover"
_IL_INTERACTIVE_ALL="prcheck pr ticket handover"
_IL_OVERNIGHT_ALL="execute prcheck pr ticket merge handover"

# _il_norm <value> → lowercased, whitespace-stripped
_il_norm() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }

# _il_truthy <value> → rc 0 if truthy (selector test)
_il_truthy() {
  case "$(_il_norm "${1:-}")" in
    ''|0|false|off|no) return 1;;
    *) return 0;;
  esac
}

# _il_filter <wanted=",tok,tok,"> → echo VOCAB ∩ wanted in canonical order
_il_filter() {
  local wanted="$1" out="" t
  for t in $_IL_VOCAB; do
    case "$wanted" in *",$t,"*) out="${out:+$out }$t";; esac
  done
  printf '%s' "$out"
}

# resolve_legs <initiative_val> <overnight_val> <overnight_selector>
resolve_legs() {
  local init_val="${1:-}" over_val="${2:-}" selector="${3:-}"
  local base all_set norm
  if _il_truthy "$selector"; then
    base="$over_val"; all_set="$_IL_OVERNIGHT_ALL"
  else
    base="$init_val"; all_set="$_IL_INTERACTIVE_ALL"
  fi
  norm="$(_il_norm "$base")"
  case "$norm" in
    ''|0|false|off|no) return 0;;                       # empty set
    1|true|on|yes|all) printf '%s' "$all_set"; return 0;;
  esac
  _il_filter ",$norm,"                                  # comma-subset (canonical, deduped)
}
