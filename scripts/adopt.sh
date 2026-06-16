#!/usr/bin/env bash
# adopt.sh — one-click installer: bring the himmel harness and/or the luna
# vault scaffold into your own repo (project scope) or user scope, in one
# command. Consolidates the three à-la-carte paths (setup.sh base,
# install-plugins.sh, manual use-on-your-project copy, luna template) behind a
# single profile + scope choice. The à-la-carte paths stay available for
# partial installs.
#
# Usage:
#   bash adopt.sh --profile <core|luna|all> --scope <project|user> \
#                 [--target PATH] [--luna-target PATH] [--dry-run]
#
# Profiles (logical blocks):
#   core   Portable hooks (block-edit-on-main, block-read-secrets,
#          auto-approve-safe-bash) + guardrails lib + worktree commands
#          (worktree/clean/clean-garden) + the marketplace plugins/skills +
#          a requirements check. (NOT jira/qmd/telegram/handover — à-la-carte.)
#   luna   The luna second-brain vault scaffold (templates/luna-second-brain).
#   all    core + luna.
#
# Scope (applies to the `core` profile):
#   project  Copy the portable scripts into <target>, wire the PreToolUse hooks
#            into <target>/.claude/settings.json, install plugins --scope project.
#   user     Install plugins --scope user and wire ~/.claude/settings.json hooks
#            to reference THIS himmel clone (scripts are not copied per-repo).
#
# Flags:
#   --target PATH       Where core lands (project scope) / vault dir for
#                       `--profile luna`. Default: current directory.
#   --luna-target PATH  Vault dir when `--profile all`. Default: ~/Documents/luna.
#   --dry-run           Print actions instead of doing them.
#
# Idempotent: re-running adds nothing already present.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HIMMEL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
PROFILE="core"
SCOPE="project"
TARGET="$PWD"
LUNA_TARGET=""
DRY_RUN=0

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="$2"; shift 2 ;;
    --scope)        SCOPE="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --luna-target)  LUNA_TARGET="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$PROFILE" in core|luna|all) ;; *) echo "ERROR: invalid --profile: $PROFILE (expected core|luna|all)" >&2; exit 2 ;; esac
case "$SCOPE"   in project|user)  ;; *) echo "ERROR: invalid --scope: $SCOPE (expected project|user)" >&2; exit 2 ;; esac
[ -n "$LUNA_TARGET" ] || LUNA_TARGET="$HOME/Documents/luna"

run() { if [[ $DRY_RUN -eq 1 ]]; then echo "DRY: $*"; else "$@"; fi; }

# Portable files copied into a project-scope target (relative paths preserved).
PORTABLE_FILES=(
  scripts/hooks/auto-approve-safe-bash.sh
  scripts/hooks/block-edit-on-main.sh
  scripts/hooks/block-read-secrets.sh
  scripts/guardrails/lib.sh
  scripts/guardrails/guard-gh.sh
  scripts/lib/py-armor.sh
  scripts/clean-garden.sh
  scripts/worktree.sh
  scripts/clean.sh
  scripts/_new-worktree.sh
)

require_tools() {
  local missing=() t
  for t in bash git jq python3 claude; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    echo "  see $HIMMEL_ROOT/docs/setup/new-machine.md (Required environment)" >&2
    exit 1
  fi
}

copy_portable() {
  echo "──── Copying portable core into $TARGET ────"
  local f
  for f in "${PORTABLE_FILES[@]}"; do
    run mkdir -p "$TARGET/$(dirname "$f")"
    run cp "$HIMMEL_ROOT/$f" "$TARGET/$f"
    run chmod +x "$TARGET/$f"
    echo "  $f"
  done
}

# Merge the three PreToolUse hook stanzas into a settings.json, idempotently.
# $1 = settings.json path, $2 = command path prefix (literal, e.g.
# '$CLAUDE_PROJECT_DIR' for project scope or the himmel abs path for user scope).
wire_settings() {
  local settings="$1" prefix="$2"
  local desired
  desired=$(cat <<JSON
[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash ${prefix}/scripts/hooks/auto-approve-safe-bash.sh"}]},
  {"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash ${prefix}/scripts/hooks/block-edit-on-main.sh"}]},
  {"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash ${prefix}/scripts/hooks/block-read-secrets.sh"}]}
]
JSON
)
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: merge 3 PreToolUse hook stanzas into $settings (prefix: $prefix)"
    return
  fi
  mkdir -p "$(dirname "$settings")"
  local base="{}"
  [[ -f "$settings" ]] && base=$(cat "$settings")
  printf '%s' "$base" | jq --argjson add "$desired" '
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = (
        (.hooks.PreToolUse // []) as $ex
        | $ex + [ $add[]
                  | select( (.hooks[0].command) as $c
                            | ($ex | map(.hooks[]?.command) | index($c)) | not ) ]
      )
  ' > "$settings.adopt.tmp" && mv "$settings.adopt.tmp" "$settings"
  echo "  wired PreToolUse hooks → $settings"
}

install_plugins() {
  echo "──── Installing plugins (--scope $SCOPE) ────"
  local args=(--scope "$SCOPE")
  [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
  if [[ "$SCOPE" == "project" ]]; then
    # project scope writes to the CWD's .claude/settings.json — run from $TARGET
    # so plugins land in the adopted repo, not wherever adopt was invoked.
    ( cd "$TARGET" && bash "$HIMMEL_ROOT/scripts/machine-setup/install-plugins.sh" "${args[@]}" )
  else
    bash "$HIMMEL_ROOT/scripts/machine-setup/install-plugins.sh" "${args[@]}"
  fi
}

do_core() {
  require_tools
  if [[ "$SCOPE" == "project" ]]; then
    copy_portable
    # Literal $CLAUDE_PROJECT_DIR — Claude Code expands it at hook-fire time.
    # shellcheck disable=SC2016
    wire_settings "$TARGET/.claude/settings.json" '$CLAUDE_PROJECT_DIR'
    echo "  worktree commands: bash $TARGET/scripts/worktree.sh feat/slug"
  else
    # user scope: reference this himmel clone, don't copy per-repo.
    wire_settings "$HOME/.claude/settings.json" "$HIMMEL_ROOT"
    echo "  worktree commands run from the himmel clone: bash $HIMMEL_ROOT/scripts/worktree.sh feat/slug"
  fi
  install_plugins
  echo "  (optional) pre-commit gates: see $HIMMEL_ROOT/docs/setup/use-on-your-project.md (Pre-commit hooks)"
}

do_luna() {
  local dest="$1"
  echo "──── Scaffolding luna vault → $dest ────"
  if [[ -e "$dest" && $DRY_RUN -ne 1 ]]; then
    echo "  $dest already exists — skipping copy (re-run the vault's own setup to update)"
  else
    run cp -r "$HIMMEL_ROOT/templates/luna-second-brain" "$dest"
  fi
  echo "  next: cd \"$dest\" && bash scripts/setup.sh   (idempotent; prints the plugin-install commands)"
}

_dry_note=""; [[ $DRY_RUN -eq 1 ]] && _dry_note=" (dry-run)"
echo "==> himmel adopt — profile=$PROFILE scope=$SCOPE${_dry_note}"
case "$PROFILE" in
  core) do_core ;;
  luna) do_luna "$TARGET" ;;
  all)  do_core; do_luna "$LUNA_TARGET" ;;
esac
echo "──── Done ────"
