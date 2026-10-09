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
# allows the lane's provider for the repo's corpus), rc 3 refused with the reason on stderr. Corpus, most restrictive
# first: a .salus/.salus-profile marker or a phi-roots/egress-denylist root ->
# salus; the luna vault root or an .obsidian marker -> luna-personal
# (luna-clippings under Clippings/); the handover root -> handover-state.
# `conditional` counts as refused: no condition can be verified for a whole
# review pack. For openrouter it also exports CLAUDE_OPENROUTER_CWD=<reviewed
# repo> so the launcher classifies the repo, not the scratch cwd.
# A repo in none of those corpora is himmel-code only when its git common dir equals
# this checkout's (a worktree of it passes, a foreign repo nested inside it does not);
# any other repo is unclassified and refused, since the matrix default for an
# unclassified corpus is deny. A LUNA_VAULT/LUNA_VAULT_PATH/HANDOVER_DIR that is set
# but does not resolve refuses too.
# ponytail: only hermes-critic.sh and claude-floor-review.sh gate; the shared
# headless launcher scripts/lib/claude-headless.sh resolves the lane but does not,
# so a new caller of it would be ungated - move this call into it when a third
# review site appears.
claude_lane_egress() {
  local dir="${1:?claude_lane_egress: reviewed repo required}" lane="${HIMMEL_CLAUDE_LANE:-native}"
  local prov corpus="" d prev list line v lroot="" hroot hd out verdict root
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
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        # an entry of only slashes is the filesystem root: it covers every repo
        if [ "$line" = "${line%%[!/]*}" ]; then corpus=salus; continue; fi
        line="${line%/}"
        case "$dir/" in "$line"/*) corpus=salus ;; esac
        line="$(cd -P "$line" 2>/dev/null && pwd -P)" || continue
        case "$dir/" in "$line"/*) corpus=salus ;; esac
      done < "$list"
    done
  fi
  if [ "$corpus" != salus ]; then
    # HIMMEL-5099: every vault var that is set must resolve (a stale one would otherwise be
    # read as "no vault"), and a resolvable one never masks the other.
    for v in "${LUNA_VAULT:-}" "${LUNA_VAULT_PATH:-}"; do
      [ -n "$v" ] || continue
      lroot="$(cd -P "$v" 2>/dev/null && pwd -P)" || {
        echo "claude-lane: REFUSED - the luna vault \"$v\" cannot be resolved (LUNA_VAULT/LUNA_VAULT_PATH set but not a usable directory; fail closed)" >&2; return 3; }
      case "$dir/" in
        "$lroot/Clippings/"*) [ -n "$corpus" ] || corpus=luna-clippings ;;
        "$lroot/"*) corpus=luna-personal ;;
      esac
    done
    # HIMMEL-4420: handover_root reads only the live env, so a .env-only HANDOVER_DIR
    # is loaded from himmel's own primary checkout (cwd = this lib, never the reviewed repo).
    # A HANDOVER_DIR set from ANY source (live env or .env) that handover_root cannot
    # resolve exits 4 in the subshell: refuse, never read it as "no handover root".
    hd="$(cd "$_CLAUDE_LANE_DIR" 2>/dev/null || exit 1; { . ./load-dotenv.sh && load_dotenv HANDOVER_DIR; } >/dev/null 2>&1; . ./handover-path.sh 2>/dev/null || exit 1
      if [ -n "${HANDOVER_DIR:-}" ]; then handover_root 2>/dev/null || exit 4; else handover_root 2>/dev/null || true; fi)" || {
      echo "claude-lane: REFUSED - the handover root cannot be resolved (HANDOVER_DIR set but not a usable directory, or the lib is unreadable; fail closed)" >&2; return 3; }
    hroot=""
    if [ -n "$hd" ]; then
      hroot="$(cd -P "$hd" 2>/dev/null && pwd -P)" || {
        echo "claude-lane: REFUSED - the handover root \"$hd\" cannot be resolved (fail closed)" >&2; return 3; }
    fi
    if [ -n "$hroot" ] && [ "${corpus#luna-}" = "$corpus" ]; then
      case "$dir/" in "$hroot/"*) corpus=handover-state ;; esac
    fi
  fi
  if [ -z "$corpus" ]; then
    # positive himmel-code classification (as claude-openrouter does); anything else is
    # unclassified, and the matrix default for an unclassified corpus is deny
    root="$(cd -P "$_CLAUDE_LANE_DIR/../.." 2>/dev/null && pwd -P)" || root=""
    # HIMMEL-5099: bound to the git common dir, so a worktree of this checkout passes and a
    # foreign repo nested inside it does not.
    if [ -n "$root" ] && . "$_CLAUDE_LANE_DIR/git-clean.sh" 2>/dev/null; then
      lroot="$(git_clean -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || lroot=""
      hd="$(git_clean -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || hd=""
      if [ -n "$lroot" ] && [ "$lroot" = "$hd" ]; then corpus=himmel-code; fi
    fi
    if [ -z "$corpus" ]; then
      echo "claude-lane: REFUSED - the reviewed repo is in no known corpus (not in the git repository of ${root:-the himmel checkout}); the egress matrix denies an unclassified corpus, so the $lane lane would send the review pack somewhere unvetted" >&2
      return 3
    fi
  fi
  if [ -n "$corpus" ]; then
    out="$(node "$_CLAUDE_LANE_DIR/../guardrails/egress-matrix-eval.mjs" "$corpus" "$prov" inference 2>/dev/null)" || out=""
    verdict="${out%%$'\t'*}"
    case "$verdict" in
      allow) ;;  # allow+log needs a ledger line this seam does not write: fail closed
      *) echo "claude-lane: REFUSED - the reviewed repo is corpus \"$corpus\" and the egress matrix says \"${verdict:-unevaluable}\" for provider \"$prov\" at purpose inference (${out#*$'\t'}) - the $lane lane would send the review pack there" >&2
         return 3 ;;
    esac
  fi
  [ "$lane" != openrouter ] || export CLAUDE_OPENROUTER_CWD="$dir"
  return 0
}
