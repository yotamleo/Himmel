#!/usr/bin/env bash
# scripts/lanes/lib/leg-cost-row.sh - one leg's cost ledger row (HIMMEL-4217).
#
# Source this file; it defines functions and runs nothing. close-wrapped-leg.sh
# appends the row at wrap; the ledger lives at
# <handover root>/.ledger/leg-cost.jsonl (override: LEG_COST_LEDGER).
#
#   leg_cost_ledger_path             prints the ledger path
#   leg_cost_row <transcript> <leg doc path | leg stem>
#                                    prints ONE compact JSON row, rc 1 + stderr
#                                    on a meter failure. PR and the `class:` /
#                                    `profile:` front-matter lines are read only
#                                    when the second arg is a readable file.
#
# The meter is leg-burn.sh --raw (override: LEG_BURN_BIN, for tests). cost_eq is
# recomputed from its exact integers with lib/burn-weights.sh, because --raw
# keeps cost-eq itself in the rounded 560.0k form.
# Leg class: shepherd | impl | investigation | judge. Derived from the stem
# (`-cloud-shepherd`), else the doc's `class:` front matter, else `unknown`.
# Bash 3.2-compatible; needs jq.

_LCR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lanes/lib/burn-weights.sh
. "$_LCR_HERE/burn-weights.sh"
# shellcheck source=scripts/lib/leg-identity.sh
. "$_LCR_HERE/../../lib/leg-identity.sh"

leg_cost_ledger_path() {
    if [ -n "${LEG_COST_LEDGER:-}" ]; then printf '%s\n' "$LEG_COST_LEDGER"; return 0; fi
    # shellcheck source=scripts/lib/handover-path.sh
    . "$_LCR_HERE/../../lib/handover-path.sh" || return 1
    local root
    root=$(handover_root) || return 1
    printf '%s/.ledger/leg-cost.jsonl\n' "$root"
}

# _lcr_front <doc> <key> - a front-matter value (first --- block only).
_lcr_front() {
    awk -v k="$2" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && index($0, k ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
    ' "$1"
}

leg_cost_row() {
    local transcript="$1" ref="$2" stem raw calls comp out cr cc inp cost model
    local label ticket pr="" class="" profile="" burn
    burn="${LEG_BURN_BIN:-$_LCR_HERE/../leg-burn.sh}"
    raw=$(bash "$burn" --raw "$transcript") || { echo "leg-burn failed on $transcript" >&2; return 1; }
    _lcr_field() { printf '%s' "$raw" | sed -nE "s/.* $1=([0-9]+).*/\\1/p"; }
    calls=$(_lcr_field calls); comp=$(_lcr_field compactions); out=$(_lcr_field out)
    cr=$(_lcr_field cache-read); cc=$(_lcr_field cache-create); inp=$(_lcr_field input)
    local v
    for v in "$calls" "$comp" "$out" "$cr" "$cc" "$inp"; do
        case "$v" in ''|*[!0-9]*) echo "leg-burn output unparseable: $raw" >&2; return 1 ;; esac
    done
    cost=$(awk -v i="$inp" -v cr="$cr" -v cc="$cc" -v o="$out" \
        -v wi="$LEG_BURN_W_INPUT" -v wcr="$LEG_BURN_W_CACHE_READ" -v wcc="$LEG_BURN_W_CACHE_CREATE" -v wo="$LEG_BURN_W_OUTPUT" \
        'BEGIN { printf "%.10g", i*wi + cr*wcr + cc*wcc + o*wo }')
    model=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$transcript" 2>/dev/null \
        | grep -v '^<' | tail -n 1)
    stem="${ref##*/}"; stem="${stem%.md}"
    label=$(leg_label "$stem")
    ticket=$(printf '%s' "$stem" | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p')
    if [ -f "$ref" ]; then
        pr=$(sed -nE 's/^- [0-9:]+ READY[^0-9]*#?([0-9]+).*/\1/p' "$ref" | tail -n 1)
        class=$(_lcr_front "$ref" class)
        profile=$(_lcr_front "$ref" profile)
    fi
    case "$stem" in *-cloud-shepherd*) class=shepherd ;; esac
    case "$class" in shepherd|impl|investigation|judge) ;; *) class=unknown ;; esac
    [ -n "$profile" ] || profile=unknown
    jq -nc --arg date "$(date +%F)" --arg leg "$label" --arg ticket "$ticket" --arg pr "$pr" \
        --arg model "${model:-unknown}" --arg profile "$profile" --arg class "$class" \
        --arg session "$(basename "$transcript" .jsonl)" \
        --argjson calls "$calls" --argjson out "$out" --argjson cr "$cr" --argjson cc "$cc" \
        --argjson inp "$inp" --argjson cost "$cost" --argjson comp "$comp" \
        '{date:$date, leg:$leg, ticket:$ticket, pr:(if $pr == "" then null else ($pr|tonumber) end),
          model:$model, profile:$profile, class:$class, calls:$calls, out:$out, cache_read:$cr,
          cache_create:$cc, input:$inp, cost_eq:$cost, compactions:$comp, session:$session}'
}
