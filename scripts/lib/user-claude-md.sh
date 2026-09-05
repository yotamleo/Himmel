# shellcheck shell=bash
# scripts/lib/user-claude-md.sh
#
# wire_user_claude_md — append himmel's "working principles" block to a
# user-scope rule file (HIMMEL-2038). Those four defaults (think before coding
# / simplicity first / surgical changes / goal-driven execution) used to live
# in himmel's always-on project CLAUDE.md; they are general engineering
# defaults, not himmel invariants, so adopters get them once at user scope
# instead of paying for them in every himmel session.
#
# One TARGET per call, by design: the function is agent-agnostic, so the
# caller invokes it once per harness whose user-scope rule file it wants
# populated -- adopt.sh/adopt.ps1's do_core() call it twice, once for Claude
# Code's ~/.claude/CLAUDE.md and once for Codex's ~/.codex/AGENTS.md. Hermes
# is not a target: its himmel_agent profile SOUL already states the same four.
#
# The payload is extracted at RUN TIME from the marker range in
# docs/setup/user-scope-claude-md-template.md (the single source of truth),
# never duplicated into this file.
#
# Idempotent / never destructive:
#   - target exists AND already has the marker  -> skip, unchanged.
#   - target exists, no marker, but looks like it already states the
#     principles by hand (heuristic phrase match) -> skip, unchanged.
#   - target exists, no marker, no heuristic match -> APPEND (blank line +
#     payload), never truncate/overwrite.
#   - target absent -> create it with just the payload.
#
# Usage: wire_user_claude_md <template-md-path> <target-claude-md-path>
# Honors $DRY_RUN (0/1, default 0), matching adopt.sh's run()/DRY_RUN
# convention, without depending on adopt.sh's own run() helper (this file is
# also sourced standalone by its test).

# Marker + heuristic phrase are shared between the extractor and the skip
# checks below, so keep them declared once.
_HIMMEL_USER_CLAUDE_MD_MARKER="HIMMEL:working-principles"
# ponytail: distinctive-phrase heuristic, not a real "did the operator already
# say this" detector -- a hand-written CLAUDE.md that phrases the same idea
# without ever using these two words together would still get appended to.
# Upgrade path: none planned, the cost of a rare double-append (operator just
# deletes the duplicate block) is lower than the cost of a stricter matcher.
_HIMMEL_USER_CLAUDE_MD_HEURISTIC="simplicity first"

wire_user_claude_md() {
  local template="$1" target="$2"

  if [ ! -f "$template" ]; then
    echo "  user CLAUDE.md: template not found at $template — skipping." >&2
    return 0
  fi

  local payload
  payload="$(sed -n "/<!-- BEGIN ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->/,/<!-- END ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->/p" "$template")"
  if [ -z "$payload" ]; then
    echo "  user CLAUDE.md: markers not found in $template — skipping." >&2
    return 0
  fi
  # A sed range whose END address never matches prints through EOF, so a
  # template with BEGIN but no END yields a "payload" of the whole rest of the
  # file — which would then be appended to the user's CLAUDE.md. Refuse unless
  # the extract actually ends on the END marker.
  case "$payload" in
    *"<!-- END ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->") ;;
    *)
      echo "  user CLAUDE.md: $template has a BEGIN marker with no END marker — skipping (refusing to append an unbounded extract)." >&2
      return 0
      ;;
  esac

  if [ -f "$target" ]; then
    # Exact BEGIN line, not the bare marker substring — prose that merely
    # mentions HIMMEL:working-principles must not suppress the install.
    if grep -qF "<!-- BEGIN ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->" "$target"; then
      echo "  user CLAUDE.md: working-principles block already present — skipping ($target)"
      return 0
    fi
    if grep -qi "$_HIMMEL_USER_CLAUDE_MD_HEURISTIC" "$target"; then
      echo "  user CLAUDE.md: no marker, but looks like working principles are already stated by hand (heuristic match on '$_HIMMEL_USER_CLAUDE_MD_HEURISTIC') — skipping, not appending ($target)"
      return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "DRY: append working-principles block → $target"
      return 0
    fi
    { printf '\n'; printf '%s\n' "$payload"; } >> "$target" || return 1
    echo "  user CLAUDE.md: appended working-principles block → $target"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY: create $target with working-principles block"
    return 0
  fi
  mkdir -p "$(dirname "$target")" || return 1
  printf '%s\n' "$payload" > "$target" || return 1
  echo "  user CLAUDE.md: created $target with working-principles block"
}
