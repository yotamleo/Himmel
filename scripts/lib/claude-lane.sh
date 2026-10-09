#!/usr/bin/env bash
# claude-lane.sh — HIMMEL-4082 lane seam for headless `claude` spawn sites.
# Source it, then: claude_lane_resolve <repo-root>
# Sets CLAUDE_LANE_CMD (array) to the command a site execs in place of `claude`:
#   HIMMEL_CLAUDE_LANE unset / empty / native -> claude            (today's argv, unchanged)
#   openrouter                                -> <repo>/scripts/claude-openrouter
#   claudex                                   -> <repo>/scripts/claude-codex
# Anything else refuses (rc 2) — never a silent fallback to native. The lane
# launchers exec `claude "$@"`, so a site keeps its own flags, permission mode
# and --output-format json parsing. claude_lane_resolve does NO egress check:
# claude-codex runs only cwd-based guards (.salus walk, phi-roots, egress-denylist)
# and claude-openrouter classifies the corpus by cwd, while the wired sites run
# claude from a TMPDIR scratch cwd, so neither launcher sees the reviewed repo.
# A site that reviews a repo therefore calls claude_lane_egress <reviewed-repo>
# after it (HIMMEL-4111): it classifies that repo and asks the egress matrix.
# bash 3.2-safe.
# shellcheck disable=SC2034  # CLAUDE_LANE_CMD is read by the sourcing site
claude_lane_resolve() {
  local root="${1:?claude_lane_resolve: repo root required}"
  case "${HIMMEL_CLAUDE_LANE:-native}" in
    native)     CLAUDE_LANE_CMD=(claude) ;;
    openrouter) CLAUDE_LANE_CMD=("$root/scripts/claude-openrouter") ;;
    claudex)    CLAUDE_LANE_CMD=("$root/scripts/claude-codex") ;;
    *)
      echo "claude-lane: unknown HIMMEL_CLAUDE_LANE='${HIMMEL_CLAUDE_LANE}' (valid: native, openrouter, claudex) - refusing, no fallback" >&2
      return 2 ;;
  esac
}

_CLAUDE_LANE_DIR="${BASH_SOURCE[0]%/*}"

# claude_lane_egress <reviewed-repo-dir> -> rc 0 permitted (native; the matrix
# allows the lane's provider for the repo's corpus; or the repo is in no gated
# corpus), rc 3 refused with the reason on stderr. Corpus, most restrictive
# first: a .salus/.salus-profile marker or a phi-roots/egress-denylist root ->
# salus; the luna vault root or an .obsidian marker -> luna-personal
# (luna-clippings under Clippings/); the handover root -> handover-state.
# `conditional` counts as refused: no condition can be verified for a whole
# review pack. For openrouter it also exports CLAUDE_OPENROUTER_CWD=<reviewed
# repo> so the launcher classifies the repo, not the scratch cwd.
# ponytail: a repo in none of those corpora is not gated here (as in
# scripts/hermes/egress-gate.sh); claude-openrouter still refuses it as unknown.
claude_lane_egress() {
  local dir="${1:?claude_lane_egress: reviewed repo required}" lane="${HIMMEL_CLAUDE_LANE:-native}"
  local prov corpus="" d prev list line v lroot="" hroot hd out verdict
  case "$lane" in
    native) return 0 ;;
    openrouter) prov=openrouter ;;
    claudex) prov=openai-codex ;;
    *) echo "claude-lane: unknown HIMMEL_CLAUDE_LANE='$lane' - refusing" >&2; return 2 ;;
  esac
  dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || {
    echo "claude-lane: REFUSED - cannot resolve the reviewed repo for the $lane lane (fail closed)" >&2; return 3; }
  d="$dir"; prev=""
  while [ "$d" != "$prev" ]; do
    if [ -e "$d/.salus" ] || [ -e "$d/.salus-profile" ]; then corpus=salus; break; fi
    [ -d "$d/.obsidian" ] && corpus=luna-personal
    prev="$d"; d="${d%/*}"; [ -n "$d" ] || d=/
  done
  if [ "$corpus" != salus ]; then
    for list in phi-roots egress-denylist; do
      list="${CLAUDE_GLM_CONFIG_DIR:-$HOME/.config/claude-glm}/$list"
      [ -e "$list" ] || continue
      if ! { [ -f "$list" ] && [ -r "$list" ]; }; then
        echo "claude-lane: REFUSED - guard config $list is unreadable (fail closed)" >&2; return 3
      fi
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"; line="${line%/}"
        [ -n "$line" ] || continue
        case "$dir/" in "$line"/*) corpus=salus ;; esac
      done < "$list"
    done
  fi
  if [ "$corpus" != salus ]; then
    for v in "${LUNA_VAULT:-}" "${LUNA_VAULT_PATH:-}"; do
      if [ -n "$v" ]; then lroot="$(cd -P "$v" 2>/dev/null && pwd -P)" || lroot=""; break; fi
    done
    if [ -n "$lroot" ]; then
      case "$dir/" in
        "$lroot/Clippings/"*) corpus=luna-clippings ;;
        "$lroot/"*) corpus=luna-personal ;;
      esac
    fi
    # HIMMEL-4420: handover_root reads only the live env, so a .env-only HANDOVER_DIR
    # is loaded from himmel's own primary checkout (cwd = this lib, never the reviewed repo).
    hd="${HANDOVER_DIR:-}"
    if [ -z "$hd" ] && [ -f "$_CLAUDE_LANE_DIR/load-dotenv.sh" ]; then
      hd="$(cd "$_CLAUDE_LANE_DIR" && . ./load-dotenv.sh && load_dotenv HANDOVER_DIR >/dev/null 2>&1; printf '%s' "${HANDOVER_DIR:-}")"
    fi
    hroot="$(cd -P "${hd:-/nonexistent}" 2>/dev/null && pwd -P)" || hroot=""
    if [ -n "$hroot" ] && [ "${corpus#luna-}" = "$corpus" ]; then
      case "$dir/" in "$hroot/"*) corpus=handover-state ;; esac
    fi
  fi
  if [ -n "$corpus" ]; then
    out="$(node "$_CLAUDE_LANE_DIR/../guardrails/egress-matrix-eval.mjs" "$corpus" "$prov" inference 2>/dev/null)" || out=""
    verdict="${out%%$'\t'*}"
    case "$verdict" in
      allow|allow+log) ;;
      *) echo "claude-lane: REFUSED - the reviewed repo is corpus \"$corpus\" and the egress matrix says \"${verdict:-unevaluable}\" for provider \"$prov\" at purpose inference (${out#*$'\t'}) - the $lane lane would send the review pack there" >&2
         return 3 ;;
    esac
  fi
  [ "$lane" != openrouter ] || export CLAUDE_OPENROUTER_CWD="$dir"
  return 0
}
