#!/usr/bin/env bash
# plugin-profile — move a plugin between the ALWAYS and ON-DEMAND tiers of the
# himmel lean profile (HIMMEL-2733).
#
# WHY this exists: docs/setup/settings-template.json declares two tiers. The
# ALWAYS tier (`enabledPlugins` entries flagged `true`) is installed AND enabled
# on every machine. The ON-DEMAND tier (keys of `onDemandPlugins`, each also
# present in `enabledPlugins` as `false`) is INSTALLED but left DISABLED, so a
# session starts lean and the capability is still one command away. Reaching an
# on-demand plugin used to mean a manual `/plugin` toggle or — worse — a hand
# edit of a live settings.json, which is hook-blocked (block-edit-live-settings)
# precisely because a hand edit drifts from the template silently.
#
# This script is the ONLY sanctioned writer for that flip, and it writes solely
# through `claude plugin enable|disable <spec> --scope user`. It never opens a
# settings.json.
#
# Cadences do NOT use this script: an unattended leg that needs an on-demand
# plugin force-enables it per run via a settings fragment
# (scripts/luna/pipeline-cadence.sh, HIMMEL-1036) so the machine's own profile
# stays lean between runs.
#
# Usage:
#   bash plugin-profile.sh list [--json]
#   bash plugin-profile.sh lean
#   bash plugin-profile.sh full
#   bash plugin-profile.sh enable  <spec>
#   bash plugin-profile.sh disable <spec>
#
# Verbs:
#   list              Print both tiers with each plugin's LIVE enabled/disabled
#                     state, and the `neededBy` line for every on-demand entry.
#   lean              Disable every on-demand plugin that is currently enabled.
#   full              Enable every installed on-demand plugin at user scope.
#   enable  <spec>    Enable one plugin at user scope.
#   disable <spec>    Disable one plugin at user scope.
#
# <spec> takes the full `plugin@marketplace` form, or a bare plugin name when
# that name is unambiguous across the template's two tiers.
#
# Flags:
#   --dry-run         Print the `claude plugin …` commands instead of running.
#   --json            `list` only: emit the tier table as JSON.
#   --template PATH   Override the template (default: repo settings-template.json).
#
# Exit codes:
#   0  the requested state was reached (including a no-op — already there)
#   1  a `claude plugin` call failed, or the live state could not be read
#   2  usage error (unknown verb/flag, unknown or ambiguous <spec>, refused spec)
#
# Cross-platform: pure bash + jq, bash 3.2-safe (no associative arrays, no
# mapfile) — Git-Bash on Windows runs it as-is. plugin-profile.ps1 is the
# PowerShell twin; keep the resolution + refusal rules in lockstep.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"
DRY_RUN=0
JSON=0
VERB=""
SPEC=""

# The harness-operational floor. Disabling any of these breaks the session that
# is running the command (dispatch, retrieval, handover state), so `disable`
# refuses them outright rather than leaving the operator to discover it the hard
# way. Mirrors the `floor` list in scripts/lanes/plugin-profiles.json, which is
# inviolable for the same reason.
FLOOR="handover@himmel himmel-ops@himmel qmd@himmel"

usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    list|lean|full|enable|disable)
      if [ -n "$VERB" ]; then
        echo "plugin-profile: one verb at a time — saw '$VERB' and '$1'" >&2; exit 2
      fi
      VERB="$1"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --json)     JSON=1; shift ;;
    --template) TEMPLATE="${2:-}"; [ -n "$TEMPLATE" ] || { echo "plugin-profile: --template needs a path" >&2; exit 2; }; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "plugin-profile: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$VERB" ]; then echo "plugin-profile: unknown verb: $1" >&2; exit 2; fi
      if [ -n "$SPEC" ]; then echo "plugin-profile: one <spec> at a time — saw '$SPEC' and '$1'" >&2; exit 2; fi
      SPEC="$1"; shift ;;
  esac
done

[ -n "$VERB" ] || { usage; exit 2; }

case "$VERB" in
  enable|disable) [ -n "$SPEC" ] || { echo "plugin-profile: $VERB needs a <spec>" >&2; exit 2; } ;;
  *)              [ -z "$SPEC" ] || { echo "plugin-profile: $VERB takes no <spec> (got '$SPEC')" >&2; exit 2; } ;;
esac
[ "$JSON" -eq 1 ] && [ "$VERB" != "list" ] && { echo "plugin-profile: --json is only valid for 'list'" >&2; exit 2; }

command -v jq     >/dev/null 2>&1 || { echo "plugin-profile: jq required" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "plugin-profile: claude CLI required on PATH" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "plugin-profile: template missing: $TEMPLATE" >&2; exit 1; }
jq -e . "$TEMPLATE" >/dev/null 2>&1 || { echo "plugin-profile: template is not valid JSON: $TEMPLATE" >&2; exit 1; }

# ── Tier tables from the template ────────────────────────────────────────────
# tr -d '\r': jq emits CRLF on Windows; a trailing \r corrupts every later
# spec comparison (the live-state table below is \r-free).
ALWAYS_SPECS="$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$TEMPLATE" | tr -d '\r')"
ONDEMAND_SPECS="$(jq -r '(.onDemandPlugins // {}) | keys[]' "$TEMPLATE" | tr -d '\r')"

# ── Live state: <spec>\t<enabled|disabled>, user scope ───────────────────────
# `claude plugin list` prints one stanza per (spec, scope) pair; we key on the
# USER scope because that is the only scope this script writes. A spec that is
# installed at project scope only is reported as "not installed (user)" rather
# than silently reading as disabled — the two are different states and the
# recipe to fix them differs.
#
# Fail closed: a `plugin list` we could not run has told us NOTHING about the
# live state, so every read below would be a guess. The pre-flight already
# proved `claude` is on PATH, so a failure here is a real anomaly.
if ! LIVE_RAW="$(claude plugin list 2>&1)"; then
  echo "plugin-profile: 'claude plugin list' failed — cannot read live plugin state:" >&2
  printf '%s\n' "$LIVE_RAW" | sed 's/^/    /' >&2
  exit 1
fi
# Validate the observed CLI protocol before trusting an empty parse. Exit 0 with
# garbage, a partial stanza, or an unknown status has proved no live state and
# must not make lean/full report a false no-op. The supported empty response is
# the real CLI's exact sentence; non-empty output is the observed header plus
# complete Version/Scope/Status stanzas. tr removes native-Windows CRLF first.
LIVE_NORMALIZED="$(printf '%s\n' "$LIVE_RAW" | tr -d '\r')"
EMPTY_LIST_RESPONSE="No plugins installed. Use \`claude plugin install\` to install a plugin."
if [ "$LIVE_NORMALIZED" = "$EMPTY_LIST_RESPONSE" ]; then
  LIVE=""
elif ! LIVE="$(printf '%s\n' "$LIVE_NORMALIZED" | awk '
  function invalid() { bad = 1; exit 1 }
  NR == 1 {
    if ($0 != "Installed plugins:") invalid()
    next
  }
  /^[[:space:]]*$/ {
    if (stage != 0) invalid()
    next
  }
  /^[[:space:]]*❯[[:space:]]+/ {
    if (stage != 0 || $0 !~ /^[[:space:]]*❯[[:space:]]+[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+[[:space:]]*$/) invalid()
    spec = $2
    scope = ""
    stage = 1
    count++
    next
  }
  /^[[:space:]]*Version:/ {
    if (stage != 1 || $0 !~ /^[[:space:]]*Version:[[:space:]]+[^[:space:]]+[[:space:]]*$/) invalid()
    stage = 2
    next
  }
  /^[[:space:]]*Scope:/ {
    if (stage != 2 || $0 !~ /^[[:space:]]*Scope:[[:space:]]+(user|project|local)[[:space:]]*$/) invalid()
    scope = $2
    stage = 3
    next
  }
  /^[[:space:]]*Status:/ {
    if (stage != 3 || $0 !~ /^[[:space:]]*Status:[[:space:]]+[^[:space:]]+[[:space:]]+(enabled|disabled)[[:space:]]*$/) invalid()
    if (scope == "user") print spec "\t" $3
    stage = 0
    next
  }
  { invalid() }
  END { if (!bad && (stage != 0 || count == 0)) exit 1 }
' | sort -u)"; then
  echo "plugin-profile: 'claude plugin list' returned an unrecognized response — cannot read live plugin state" >&2
  exit 1
fi

live_state() {  # <spec> -> enabled | disabled | absent
  _s="$(printf '%s\n' "$LIVE" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }')"
  [ -n "$_s" ] && printf '%s' "$_s" || printf 'absent'
}

in_list() {  # <needle> <space-separated haystack>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ── Resolve a bare plugin name to a full spec ────────────────────────────────
# Only the template's own two tiers are searchable: resolving against the LIVE
# machine would let a stray third-party plugin answer to a himmel name.
resolve_spec() {
  _want="$1"
  case "$_want" in
    *@*) printf '%s' "$_want"; return 0 ;;
  esac
  _hits="$(printf '%s\n%s\n' "$ALWAYS_SPECS" "$ONDEMAND_SPECS" \
    | grep -v '^$' | awk -F'@' -v n="$_want" '$1 == n' | sort -u)"
  _n="$(printf '%s' "$_hits" | grep -c . || true)"
  if [ "$_n" -eq 0 ]; then
    echo "plugin-profile: '$_want' is in neither tier of $TEMPLATE." >&2
    echo "  Run 'plugin-profile.sh list' to see both tiers, or pass the full plugin@marketplace spec." >&2
    return 2
  fi
  if [ "$_n" -gt 1 ]; then
    echo "plugin-profile: '$_want' is ambiguous — pass the full plugin@marketplace spec. Candidates:" >&2
    printf '%s\n' "$_hits" | sed 's/^/    /' >&2
    return 2
  fi
  printf '%s' "$_hits"
}

# ── The one writer ───────────────────────────────────────────────────────────
apply() {  # <enable|disable> <spec>
  # Enforce the floor HERE, not only at the single `disable <spec>` call site
  # below: the `lean`/`full` bulk loop calls apply() directly, so a floor
  # refusal that lived solely at the single-spec site would never fire for it
  # — a `--template` override that placed a floor plugin (e.g. qmd@himmel)
  # in onDemandPlugins would let a plain `lean` run disable it. Checking here
  # covers every caller in one place (HIMMEL-2733).
  if [ "$1" = "disable" ] && in_list "$2" "$FLOOR"; then
    echo "plugin-profile: refusing to disable $2 — it is harness-operational (floor)." >&2
    echo "  The floor is $FLOOR; disabling one breaks the session running this command." >&2
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY: claude plugin $1 $2 --scope user"
    return 0
  fi
  if ! _out="$(claude plugin "$1" "$2" --scope user 2>&1)"; then
    echo "plugin-profile: 'claude plugin $1 $2 --scope user' failed:" >&2
    printf '%s\n' "$_out" | sed 's/^/    /' >&2
    return 1
  fi
  echo "  user scope changed: $1 $2; project/local settings may override effective state"
}

# ── list ─────────────────────────────────────────────────────────────────────
if [ "$VERB" = "list" ]; then
  if [ "$JSON" -eq 1 ]; then
    # Build the live table as JSON on stdin so jq can join it against the
    # template rather than re-shelling per spec.
    printf '%s\n' "$LIVE" | jq -R -s --slurpfile t "$TEMPLATE" '
      ( split("\n") | map(select(length > 0) | split("\t")) | map({key: .[0], value: .[1]}) | from_entries ) as $live
      | $t[0] as $tmpl
      | {
          always: [ ($tmpl.enabledPlugins // {}) | to_entries[] | select(.value == true)
                    | { spec: .key, state: ($live[.key] // "absent") } ],
          onDemand: [ ($tmpl.onDemandPlugins // {}) | to_entries[]
                      | { spec: .key, state: ($live[.key] // "absent"), neededBy: (.value.neededBy // null) } ],
          connectors: [ ($tmpl.onDemandConnectors // {}) | to_entries[]
                        | { name: .key, neededBy: (.value.neededBy // null), enableVia: (.value.enableVia // null) } ]
        }'
    exit 0
  fi
  echo "──── ALWAYS tier (installed + enabled on every himmel machine) ────"
  # A plain `printf | grep -v '^$' | while read` pipeline fails empty-safety
  # under `set -euo pipefail`: an empty tier means grep matches nothing and
  # exits 1, and pipefail propagates that non-zero status to the whole
  # pipeline, which `set -e` then treats as a script-ending error — `list`
  # would abort mid-print on a template with an empty tier instead of just
  # printing nothing for it. Feed the loop from a here-string instead (same
  # fix as the lean/full loop below) and skip blanks inline.
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    printf '  [%s] %s\n' "$(live_state "$s")" "$s"
  done <<EOF
$ALWAYS_SPECS
EOF
  echo
  echo "──── ON-DEMAND tier (installed, disabled — enable when you need it) ────"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    printf '  [%s] %s\n' "$(live_state "$s")" "$s"
    printf '        needed by: %s\n' "$(jq -r --arg k "$s" '(.onDemandPlugins[$k].neededBy // "(unrecorded)")' "$TEMPLATE" | tr -d '\r')"
  done <<EOF
$ONDEMAND_SPECS
EOF
  echo
  echo "  enable one:  bash scripts/machine-setup/plugin-profile.sh enable <spec>"
  echo "  back to lean: bash scripts/machine-setup/plugin-profile.sh lean"
  CONNECTORS="$(jq -r '(.onDemandConnectors // {}) | keys[]' "$TEMPLATE" | tr -d '\r')"
  if [ -n "$CONNECTORS" ]; then
    echo
    echo "──── On-demand CONNECTORS (himmel does not install these) ────"
    printf '%s\n' "$CONNECTORS" | grep -v '^$' | while IFS= read -r c; do
      printf '  %s\n        needed by: %s\n        enable via: %s\n' "$c" \
        "$(jq -r --arg k "$c" '(.onDemandConnectors[$k].neededBy // "(unrecorded)")' "$TEMPLATE" | tr -d '\r')" \
        "$(jq -r --arg k "$c" '(.onDemandConnectors[$k].enableVia // "(unrecorded)")' "$TEMPLATE" | tr -d '\r')"
    done
  fi
  exit 0
fi

# ── lean / full ──────────────────────────────────────────────────────────────
if [ "$VERB" = "lean" ] || [ "$VERB" = "full" ]; then
  [ "$VERB" = "lean" ] && WANT="disabled" || WANT="enabled"
  [ "$VERB" = "lean" ] && ACT="disable"   || ACT="enable"
  echo "──── $VERB: bringing installed on-demand plugins to '$WANT' (user scope) ────"
  installed=0
  touched=0
  rc=0
  # A plain `while read` over a pipe runs in a subshell on bash 3.2, so the
  # counters would be lost; feed the loop from a here-string instead.
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    st="$(live_state "$s")"
    if [ "$st" = "absent" ]; then
      echo "  skip: $s (not installed at user scope — run install-plugins.sh)"
      continue
    fi
    installed=$((installed + 1))
    if [ "$st" = "$WANT" ]; then continue; fi
    apply "$ACT" "$s" || rc=1
    touched=$((touched + 1))
  done <<EOF
$ONDEMAND_SPECS
EOF
  if [ "$installed" -eq 0 ]; then
    echo "  (no on-demand plugins installed at user scope — nothing to change; project/local installs are outside this user-scope toggle)"
  elif [ "$touched" -eq 0 ]; then
    echo "  (installed on-demand plugins at user scope already $VERB — nothing to change; project/local settings may override effective state)"
  fi
  exit "$rc"
fi

# ── enable / disable one ─────────────────────────────────────────────────────
RESOLVED="$(resolve_spec "$SPEC")" || exit 2

if [ "$VERB" = "disable" ] && in_list "$RESOLVED" "$FLOOR"; then
  echo "plugin-profile: refusing to disable $RESOLVED — it is harness-operational (floor)." >&2
  echo "  The floor is $FLOOR; disabling one breaks the session running this command." >&2
  exit 2
fi

STATE="$(live_state "$RESOLVED")"
if [ "$STATE" = "absent" ]; then
  echo "plugin-profile: $RESOLVED is not installed at user scope." >&2
  echo "  Install it first: bash scripts/machine-setup/install-plugins.sh --scope user" >&2
  exit 1
fi

WANT="disabled"; [ "$VERB" = "enable" ] && WANT="enabled"
if [ "$STATE" = "$WANT" ]; then
  echo "  user scope already $WANT: $RESOLVED; project/local settings may override effective state"
  exit 0
fi

apply "$VERB" "$RESOLVED"

if [ "$VERB" = "enable" ] && in_list "$RESOLVED" "$(printf '%s' "$ONDEMAND_SPECS" | tr '\n' ' ')"; then
  echo "  note: this is an ON-DEMAND plugin. An opt-in reconcile"
  echo "        (HIMMEL_RECONCILE_PLUGINS=1, e.g. via /himmel-update) writes the template"
  echo "        map verbatim and will turn it back off. To keep it on permanently on THIS"
  echo "        machine, record \"$RESOLVED\": true in ~/.claude/settings.local.json as"
  echo "        reconciliation input. The next opt-in reconcile copies it into settings.json;"
  echo "        the user sibling is not a Claude Code runtime settings layer."
fi
