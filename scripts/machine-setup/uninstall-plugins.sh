#!/usr/bin/env bash
# uninstall-plugins — remove installed Claude plugins named by
# docs/setup/settings-template.json (HIMMEL-2694/2754).
#
# Queries `claude plugin list --json` for each plugin's own scope, limiting
# project and local rows to the current directory. When enumeration is unavailable,
# falls back to the template's enabledPlugins true + onDemandPlugins keys at --scope.
# Repairs missing marketplaces transiently so a partial teardown can retry;
# removes registered marketplaces only when no installed plugin needs them.
#
# Usage:
#   bash uninstall-plugins.sh [--dry-run] [--scope SCOPE] [--template PATH]
#        [--plugins-only | --marketplaces-only] [--scope-map PATH]
#
# Flags:
#   --dry-run            Print commands instead of running them.
#   --scope SCOPE        Fallback scope: user (default), project, or local.
#                        Installed plugins supply their own scope normally.
#   --template PATH      Override default template path.
#   --plugins-only       Run only the plugin phase (including repair cleanup).
#   --marketplaces-only  Run only the marketplace phase.
#   --scope-map PATH     INTERNAL scope handoff: <marketplace>\t<scope>, plus a
#                        third <project path> field for project and local rows.
#                        --dry-run writes this file too: use an ephemeral path,
#                        never a persisted retry cache.
#
# Exit codes: 0 = clean; 1 = failed call or blocked removal; 2 = bad usage.
set -euo pipefail

# ── Resolve script + repo paths ─────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
DRY_RUN=0
PLUGINS_ONLY=0
MARKETPLACES_ONLY=0
SCOPE="user"
SCOPE_MAP=""
TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugins-only)  PLUGINS_ONLY=1; shift ;;
    --marketplaces-only) MARKETPLACES_ONLY=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --scope)         [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }; SCOPE="$2"; shift 2 ;;
    --template)      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }; TEMPLATE="$2"; shift 2 ;;
    # WHY (HIMMEL-2754): dry-run deliberately writes this map so the second
    # phase knows which scopes the first would use. uninstall.sh supplies an
    # ephemeral mktemp handoff and removes it on EXIT; callers must give a
    # dry run an ephemeral map, never the wet cache path.
    --scope-map)     [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }; SCOPE_MAP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ $PLUGINS_ONLY -eq 1 && $MARKETPLACES_ONLY -eq 1 ]]; then
  echo "ERROR: --plugins-only and --marketplaces-only are mutually exclusive" >&2
  exit 2
fi

# ── Validate scope ───────────────────────────────────────────────────────────
case "$SCOPE" in
  user|project|local) ;;
  *) echo "ERROR: invalid --scope: $SCOPE (expected user|project|local)" >&2; exit 2 ;;
esac

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ -f "$TEMPLATE" ]] || { echo "ERROR: template missing: $TEMPLATE" >&2; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
command -v claude  >/dev/null || { echo "ERROR: claude CLI required on PATH" >&2; exit 1; }

# ── Helper: run-or-print ────────────────────────────────────────────────────
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# WHY (HIMMEL-2754): the scope handoff must survive an interruption mid-loop,
# not only a clean end of the loop.
persist_scope_map() {
  if [[ -n "$SCOPE_MAP" && -n "$REMOVED_SCOPES" ]]; then
    _scope_records="$REMOVED_SCOPES"
    if [[ -f "$SCOPE_MAP" ]]; then
      _prior_scopes=""
      if [[ -r "$SCOPE_MAP" ]] && _prior_scopes="$(cat -- "$SCOPE_MAP" 2>/dev/null)"; then
        if [[ -n "$_prior_scopes" ]]; then
          _scope_records="${_prior_scopes}"$'\n'"${REMOVED_SCOPES}"
        fi
      else
        if [[ $SCOPE_MAP_PERSIST_FAILED -eq 0 ]]; then
          SCOPE_MAP_PERSIST_FAILED=1
          FAILURES=$((FAILURES + 1))
        fi
        echo "WARN: could not read prior scopes from $SCOPE_MAP — prior scopes are lost from the handoff; recording this run's scopes only" >&2
      fi
    fi
    # WHY (HIMMEL-2754): atomic replacement keeps prior scopes intact if a write fails.
    _scope_tmp=""
    if ! _scope_tmp="$(mktemp "${SCOPE_MAP}.XXXXXX")"; then
      echo "WARN: could not create temporary scope map for $SCOPE_MAP" >&2
      [[ -z "$_scope_tmp" ]] || rm -f -- "$_scope_tmp" || true
    else
      if printf '%s' "$_scope_records" | awk '!seen[$0]++' > "$_scope_tmp" &&
          mv -f -- "$_scope_tmp" "$SCOPE_MAP"; then
        return 0
      fi
      echo "WARN: could not replace scope map $SCOPE_MAP" >&2
      rm -f -- "$_scope_tmp" || true
    fi
    # WHY (HIMMEL-2754): keep uninstalling after a failed handoff, but count
    # repeated per-plugin persistence failures only once for the final status.
    if [[ $SCOPE_MAP_PERSIST_FAILED -eq 0 ]]; then
      SCOPE_MAP_PERSIST_FAILED=1
      FAILURES=$((FAILURES + 1))
    fi
    echo "WARN: writing these rows to $SCOPE_MAP by hand restores the handoff:" >&2
    printf '%s' "$_scope_records" >&2
  fi
}

# WHY (HIMMEL-2694): the template names ownership, not the installed set.
# Capture keys before the loops so counters stay in this shell.
OWNED_MARKETPLACES="$(jq -r '.extraKnownMarketplaces | keys[]' "$TEMPLATE")"
# WHY (HIMMEL-2733): fallback mirrors install's ALWAYS + ON-DEMAND union.
TEMPLATE_SPECS="$(jq -r '
  ((.enabledPlugins | to_entries[] | select(.value == true) | .key)),
  ((.onDemandPlugins // {}) | keys[])
' "$TEMPLATE" | sort -u)"
# WHY (HIMMEL-2694 r4): every template KEY is owned, including plugins an
# older himmel enabled that are now disabled in the template.
# On-demand-only keys are also owned (HIMMEL-2733).
OWNED_SPECS="$(jq -r '
  (.enabledPlugins | keys[]), ((.onDemandPlugins // {}) | keys[])
' "$TEMPLATE" | sort -u)"
# WHY (HIMMEL-2694 r4): a `directory` marketplace rooted in this repo is
# ours whatever the template's enabledPlugins currently say — an older
# himmel may have installed from it. A `github` marketplace is SHARED
# (claude-plugins-official is Anthropic's), so there only the plugin IDs
# our template names are ours to remove.
# WHY (HIMMEL-2694): a textual prefix admits `..`; enforce the bound on segments.
EXCLUSIVE_MARKETPLACES="$(jq -r --arg root "$REPO_ROOT" '
  .extraKnownMarketplaces | to_entries[]
  | select(.value.source.source == "directory")
  | (.value.source.path | split("<himmel-path>") | join($root)) as $path
  | select($path == $root or ($path | startswith($root + "/")))
  | select(($path | split("/") | index("..")) == null)
  | .key' "$TEMPLATE")"

# WHY (HIMMEL-2694 r4): selection, foreign notes and remaining dependencies
# must agree on ownership, including the outer template-marketplace bound.
ownership_jq() {
  local filter="$1"
  shift
  jq --arg owned "$OWNED_MARKETPLACES" --arg specs "$OWNED_SPECS" \
    --arg exclusive "$EXCLUSIVE_MARKETPLACES" "$@" '
    def owned_row:
      .id as $id | (.id | split("@") | last) as $m
      | (($owned | split("\n") | index($m)) != null
        and (($specs | split("\n") | index($id)) != null
          or ($exclusive | split("\n") | index($m)) != null));
    '"$filter"
}
FAILURES=0
BLOCKED=0
TRANSIENT_MARKETPLACES=""
REMOVED_SCOPES=""
SCOPE_MAP_PERSIST_FAILED=0

# WHY (HIMMEL-2754): repairs restore only what this run borrowed. Even a
# failed plugin uninstall must not strand a transient registration on EXIT.
# The trap reports its own cleanup failures through the exit status too.
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap (HIMMEL-2754)
cleanup_transient() {
  local rc=$? name scope
  trap - EXIT
  while IFS=$'\t' read -r name scope; do
    [[ -n "$name" ]] || continue
    if run claude plugin marketplace remove "$name" --scope "$scope"; then
      echo "  repair: removed transient marketplace $name"
    else
      echo "WARN: could not remove transient marketplace $name" >&2
      if [[ $rc -eq 0 ]]; then rc=1; fi
    fi
  done <<EOF_TRANSIENT
$TRANSIENT_MARKETPLACES
EOF_TRANSIENT
  exit "$rc"
}
trap cleanup_transient EXIT

# WHY (HIMMEL-2694): plugin removal and dry-run subtraction share selection.
# Owned project and local rows resolve physically against the current project
# (including symlinks), so previews cannot discount another project's plugins.
CURRENT_PROJECT="$(pwd -P)"
select_targets() {
  local ROWS ID PLUGIN_SCOPE PROJECT_PATH RESOLVED_PROJECT ROW_INDEX
  # WHY (HIMMEL-2754): jq can fail after emitting partial or empty output;
  # check its status so an unresolved selection cannot look like nothing owned.
  # shellcheck disable=SC2016  # ownership_jq takes a jq filter, not shell expansion.
  if ! ROWS="$(printf '%s\n' "$1" | ownership_jq '
    to_entries[] | .key as $i | .value
    | select(owned_row)
    | [.id, .scope, $i, (.projectPath // "")] | @tsv' -r)"; then
    return 1
  fi
  while IFS=$'\t' read -r ID PLUGIN_SCOPE ROW_INDEX PROJECT_PATH; do
    [[ -n "$ID" ]] || continue
    if [[ "$PLUGIN_SCOPE" == "project" || "$PLUGIN_SCOPE" == "local" ]]; then
      # WHY (HIMMEL-2694): an absent projectPath leaves the row's project
      # identity unresolved; unresolved is not ours to remove.
      [[ -n "$PROJECT_PATH" ]] || continue
      # WHY (HIMMEL-2754): jq's @tsv escapes every backslash (and tab, newline,
      # carriage return); read -r keeps them literal, so a path with a backslash
      # would fail to resolve and be silently dropped from the selection.
      PROJECT_PATH="$(printf '%b' "$PROJECT_PATH")"
      RESOLVED_PROJECT="$(cd -- "$PROJECT_PATH" 2>/dev/null && pwd -P)" || continue
      [[ "$RESOLVED_PROJECT" == "$CURRENT_PROJECT" ]] || continue
    fi
    if [[ ${2:-pairs} == indices ]]; then
      printf '%s\n' "$ROW_INDEX"
    else
      printf '%s\t%s\n' "$ID" "$PLUGIN_SCOPE"
    fi
  done <<EOF_ROWS
$ROWS
EOF_ROWS
}

if [[ $MARKETPLACES_ONLY -eq 0 ]]; then
  echo "──── Uninstalling installed plugins (fallback: $SCOPE scope) ────"
  INSTALLED_JSON="$(claude plugin list --json 2>/dev/null)" || INSTALLED_JSON=""
  TARGETS=""
  if ! printf '%s\n' "$INSTALLED_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "WARN: \`claude plugin list --json\` unavailable — falling back to the template set at scope $SCOPE (HIMMEL-2694)" >&2
    while IFS= read -r SPEC; do
      [[ -n "$SPEC" ]] || continue
      TARGETS="${TARGETS}${SPEC}"$'\t'"${SCOPE}"$'\n'
    done <<EOF_SPECS
$TEMPLATE_SPECS
EOF_SPECS
  else
    if ! TARGETS="$(select_targets "$INSTALLED_JSON")"; then
      echo "ERROR: could not determine which installed plugins are ours — halting before anything is removed or unwired (HIMMEL-2754)" >&2
      exit 1
    fi
    TARGETS="$(printf '%s\n' "$TARGETS" | sort -u)"
    TARGET_COUNT=0
    while IFS=$'\t' read -r ID PLUGIN_SCOPE; do
      [[ -n "$ID" ]] || continue
      TARGET_COUNT=$((TARGET_COUNT + 1))
    done <<EOF_TARGETS
$TARGETS
EOF_TARGETS
    NOT_INSTALLED=0
    while IFS= read -r SPEC; do
      [[ -n "$SPEC" ]] || continue
      if ! printf '%s\n' "$INSTALLED_JSON" | jq -e --arg id "$SPEC" 'any(.[]; .id == $id)' >/dev/null; then
        echo "  note: $SPEC — not installed, nothing to remove"
        NOT_INSTALLED=$((NOT_INSTALLED + 1))
      fi
    done <<EOF_SPECS
$TEMPLATE_SPECS
EOF_SPECS
    echo "──── $TARGET_COUNT installed plugin(s) targeted; $NOT_INSTALLED template entry(ies) not installed (noted, not failures) ────"
    # shellcheck disable=SC2016  # ownership_jq takes a jq filter, not shell expansion.
    FOREIGN_ROWS="$(printf '%s\n' "$INSTALLED_JSON" | ownership_jq '
      .[] | .id as $id | (.id | split("@") | last) as $m
      | select(($owned | split("\n") | index($m)) != null)
      | select(owned_row | not)
      | [$id, $m] | @tsv' -r)"
    while IFS=$'\t' read -r ID M; do
      [[ -n "$ID" ]] || continue
      echo "  note: $ID — installed from $M but not named by himmel's template; left installed"
    done <<EOF_FOREIGN
$FOREIGN_ROWS
EOF_FOREIGN

    # WHY (HIMMEL-2754): a previous partial teardown may have removed the
    # source registration while leaving its installed plugins enabled.
    MKT_JSON="$(claude plugin marketplace list --json 2>/dev/null)" || MKT_JSON=""
    if ! printf '%s\n' "$MKT_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "WARN: \`claude plugin marketplace list --json\` unavailable — skipping marketplace repair (HIMMEL-2754)" >&2
    else
      while IFS= read -r M; do
        [[ -n "$M" ]] || continue
        if printf '%s\n' "$MKT_JSON" | jq -e --arg m "$M" 'any(.[]; .name == $m)' >/dev/null; then
          continue
        fi
        # WHY (HIMMEL-2754): repair every scope a marketplace's plugins span,
        # or uninstalls at the un-repaired scopes fail.
        REPAIR_SCOPES=""
        while IFS=$'\t' read -r ID PLUGIN_SCOPE; do
          if [[ "${ID##*@}" == "$M" ]]; then
            case $'\n'"$REPAIR_SCOPES" in
              *$'\n'"$PLUGIN_SCOPE"$'\n'*) ;;
              *) REPAIR_SCOPES="${REPAIR_SCOPES}${PLUGIN_SCOPE}"$'\n' ;;
            esac
          fi
        done <<EOF_TARGETS
$TARGETS
EOF_TARGETS
        [[ -n "$REPAIR_SCOPES" ]] || continue
        SOURCE_TYPE="$(jq -r --arg m "$M" '.extraKnownMarketplaces[$m].source.source' "$TEMPLATE")"
        case "$SOURCE_TYPE" in
          github) SOURCE="$(jq -r --arg m "$M" '.extraKnownMarketplaces[$m].source.repo' "$TEMPLATE")" ;;
          directory)
            SOURCE="$(jq -r --arg m "$M" '.extraKnownMarketplaces[$m].source.path' "$TEMPLATE")"
            SOURCE="${SOURCE//<himmel-path>/$REPO_ROOT}"
            ;;
          *)
            echo "WARN: cannot repair marketplace $M (unsupported source type \"$SOURCE_TYPE\")" >&2
            continue
            ;;
        esac
        echo "  repair: re-adding marketplace $M (installed plugins still reference it)"
        while IFS= read -r REPAIR_SCOPE; do
          [[ -n "$REPAIR_SCOPE" ]] || continue
          if run claude plugin marketplace add "$SOURCE" --scope "$REPAIR_SCOPE"; then
            TRANSIENT_MARKETPLACES="${TRANSIENT_MARKETPLACES}${M}"$'\t'"${REPAIR_SCOPE}"$'\n'
          else
            echo "WARN: could not repair marketplace $M" >&2
            FAILURES=$((FAILURES + 1))
          fi
        done <<EOF_REPAIR_SCOPES
$REPAIR_SCOPES
EOF_REPAIR_SCOPES
      done <<EOF_MARKETPLACES
$OWNED_MARKETPLACES
EOF_MARKETPLACES
    fi
  fi

  while IFS=$'\t' read -r ID PLUGIN_SCOPE; do
    [[ -n "$ID" ]] || continue
    echo "  uninstall: $ID"
    _rc=0
    run claude plugin uninstall "$ID" --scope "$PLUGIN_SCOPE" || _rc=$?
    if [[ $_rc -ne 0 ]]; then
      echo "    WARN: uninstall failed (rc=$_rc) — not installed at scope $PLUGIN_SCOPE, or a transient failure" >&2
      FAILURES=$((FAILURES + 1))
    else
      # WHY (HIMMEL-2754): project/local scopes only belong to this project;
      # user rows retain the two-field handoff format.
      REMOVED_SCOPES="${REMOVED_SCOPES}${ID##*@}"$'\t'"${PLUGIN_SCOPE}"
      if [[ "$PLUGIN_SCOPE" == "project" || "$PLUGIN_SCOPE" == "local" ]]; then
        REMOVED_SCOPES="${REMOVED_SCOPES}"$'\t'"$CURRENT_PROJECT"
      fi
      REMOVED_SCOPES="${REMOVED_SCOPES}"$'\n'
      persist_scope_map
    fi
  done <<EOF_TARGETS
$TARGETS
EOF_TARGETS
fi

# WHY (HIMMEL-2754): any scope/project can still depend on a marketplace.
# Re-query after the plugin phase. Without enumeration, successful template
# removals cannot rule out dependencies at other scopes or in other projects.
if [[ $PLUGINS_ONLY -eq 0 ]]; then
  echo "──── Removing marketplaces (fallback: $SCOPE scope) ────"
  REMAINING_JSON="$(claude plugin list --json 2>/dev/null)" || REMAINING_JSON=""
  VERIFIED=1
  if ! printf '%s\n' "$REMAINING_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "WARN: remaining-plugin enumeration failed — dependent plugins cannot be ruled out; removing marketplaces could strand them (HIMMEL-2754)" >&2
    VERIFIED=0
  fi
  # WHY (HIMMEL-2754): the caller runs phases in separate processes; recover
  # successful plugin scopes before falling back to the install profile.
  # The map is authoritative because the plugin phase already merged prior
  # rows into it. After a failed persist, retain both its prior rows and this
  # run's in-memory rows instead of letting the stale map replace them.
  if [[ -n "$SCOPE_MAP" ]]; then
    _map_scopes=""
    if [[ -f "$SCOPE_MAP" && -r "$SCOPE_MAP" ]] && _map_scopes="$(cat "$SCOPE_MAP" 2>/dev/null)"; then
      if [[ -n "$_map_scopes" ]]; then
        if [[ $SCOPE_MAP_PERSIST_FAILED -eq 1 ]]; then
          _scope_records="${_map_scopes}"$'\n'"${REMOVED_SCOPES}"
          _merged_scopes=""
          if _merged_scopes="$(printf '%s' "$_scope_records" | awk '!seen[$0]++')"; then
            REMOVED_SCOPES="$_merged_scopes"
          else
            # WHY (HIMMEL-2754): keep the non-lossy concatenation if
            # deduplication fails; the marketplace scope loop deduplicates too.
            REMOVED_SCOPES="$_scope_records"
          fi
        else
          REMOVED_SCOPES="$_map_scopes"
        fi
      fi
    else
      echo "WARN: could not read scope map $SCOPE_MAP — using this run's scopes and fallback scope $SCOPE" >&2
    fi
  fi
  # WHY (HIMMEL-2754): both dry-run children leave installed state intact;
  # subtract only selected rows, retaining other-project copies of the same id.
  PREVIEW_TARGETS=""
  if [[ $DRY_RUN -eq 1 && $VERIFIED -eq 1 && ( $MARKETPLACES_ONLY -eq 0 || -n "$REMOVED_SCOPES" ) ]]; then
    if ! PREVIEW_TARGETS="$(select_targets "$REMAINING_JSON" indices)"; then
      echo "ERROR: could not compute the dry-run plugin subtraction — halting rather than previewing a marketplace removal against an unresolved plugin set (HIMMEL-2754)" >&2
      exit 1
    fi
    REMAINING_JSON="$(printf '%s\n' "$REMAINING_JSON" | jq --arg targets "$PREVIEW_TARGETS" '
      ($targets | split("\n") | map(select(length > 0) | tonumber)) as $targets
      | to_entries | map(select(.key as $i | ($targets | index($i)) == null) | .value)')"
  fi
  MKT_JSON="$(claude plugin marketplace list --json 2>/dev/null)" || MKT_JSON=""
  MKT_VERIFIED=1
  if ! printf '%s\n' "$MKT_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "WARN: cannot verify registered marketplaces — attempting removal subject to the remaining-plugin safety check (HIMMEL-2754)" >&2
    MKT_VERIFIED=0
  fi
  while IFS= read -r M; do
    [[ -n "$M" ]] || continue
    TRANSIENT=0
    while IFS=$'\t' read -r NAME MKT_SCOPE; do
      if [[ "$NAME" == "$M" ]]; then
        TRANSIENT=1
      fi
    done <<EOF_TRANSIENT
$TRANSIENT_MARKETPLACES
EOF_TRANSIENT
    [[ $TRANSIENT -eq 0 ]] || continue
    if [[ $VERIFIED -eq 0 ]]; then
      echo "  SKIP: marketplace $M — cannot verify remaining plugins (enumeration unavailable); removing it could strand plugins (HIMMEL-2754)"
      BLOCKED=$((BLOCKED + 1))
      continue
    else
      REMAINING="$(printf '%s\n' "$REMAINING_JSON" | jq --arg m "$M" '[.[] | select((.id | split("@") | last) == $m)] | length')"
      # shellcheck disable=SC2016  # ownership_jq takes a jq filter, not shell expansion.
      REMAINING_OWNED="$(printf '%s\n' "$REMAINING_JSON" | ownership_jq '
        [.[] | select((.id | split("@") | last) == $m)
          | select(owned_row)] | length' --arg m "$M")"
      if [[ $REMAINING_OWNED -gt 0 ]]; then
        echo "  SKIP: marketplace $M — $REMAINING plugin(s) sourced from it are still installed; removing it would strand them (HIMMEL-2754)"
        BLOCKED=$((BLOCKED + 1))
        continue
      elif [[ $REMAINING -gt 0 ]]; then
        echo "  keep: marketplace $M — $REMAINING plugin(s) not managed by himmel are still installed from it; leaving the registration in place (HIMMEL-2754)"
        continue
      fi
    fi
    if [[ $MKT_VERIFIED -eq 1 ]] && ! printf '%s\n' "$MKT_JSON" | jq -e --arg m "$M" 'any(.[]; .name == $m)' >/dev/null; then
      echo "  note: marketplace $M — not registered, nothing to remove"
      continue
    fi
    MKT_SCOPES=""
    while IFS=$'\t' read -r NAME REMOVED_SCOPE ROW_PROJECT; do
      [[ "$NAME" == "$M" ]] || continue
      # WHY (HIMMEL-2754): a persisted map can survive a retry in another
      # project; replay project/local scopes only in their recorded project.
      if [[ "$REMOVED_SCOPE" == "project" || "$REMOVED_SCOPE" == "local" ]] && [[ "$ROW_PROJECT" != "$CURRENT_PROJECT" ]]; then
        if [[ -z "$ROW_PROJECT" ]]; then
          echo "  note: marketplace $M — a persisted $REMOVED_SCOPE scope carries no recorded project (written before HIMMEL-2754); not replaying it"
        else
          echo "  note: marketplace $M — a persisted $REMOVED_SCOPE scope belongs to <$ROW_PROJECT> and this run is in <$CURRENT_PROJECT>; not replaying it (HIMMEL-2754)"
        fi
        continue
      fi
      case $'\n'"$MKT_SCOPES" in
        *$'\n'"$REMOVED_SCOPE"$'\n'*) ;;
        *) MKT_SCOPES="${MKT_SCOPES}${REMOVED_SCOPE}"$'\n' ;;
      esac
    done <<EOF_SCOPES
$REMOVED_SCOPES
EOF_SCOPES
    MKT_SCOPES="${MKT_SCOPES:-$SCOPE}"
    echo "  marketplace remove: $M"
    while IFS= read -r MKT_SCOPE; do
      [[ -n "$MKT_SCOPE" ]] || continue
      _rc=0
      run claude plugin marketplace remove "$M" --scope "$MKT_SCOPE" || _rc=$?
      if [[ $_rc -ne 0 ]]; then
        echo "    WARN: marketplace remove failed (rc=$_rc) — not registered at scope $MKT_SCOPE, or a transient failure" >&2
        FAILURES=$((FAILURES + 1))
      fi
    done <<EOF_MKT_SCOPES
$MKT_SCOPES
EOF_MKT_SCOPES
  done <<EOF_MARKETPLACES
$OWNED_MARKETPLACES
EOF_MARKETPLACES
fi

echo "──── Done: $FAILURES failed call(s); $BLOCKED blocked marketplace removal(s) (HIMMEL-2754) ────"
if [[ $FAILURES -gt 0 || $BLOCKED -gt 0 ]]; then
  exit 1
fi
exit 0
