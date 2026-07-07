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
#   --fill-env          Interactively fill the himmel clone's .env (creates it
#                       from .env.example if absent). Enter to skip a var.
#
# Idempotent: re-running adds nothing already present.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HIMMEL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Shared wire helpers (the PreToolUse trio + SessionStart) — one implementation
# for adopt.sh and setup.sh (HIMMEL install/uninstall symmetry).
# shellcheck source=scripts/lib/wire-pretooluse-hooks.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/wire-pretooluse-hooks.sh"

# qmd resolver + install/register helpers (HIMMEL-752 qmd wiring). Provides
# has_qmd / qmd_cmd / qmd_install / qmd_register_collection, consumed by
# wire_qmd_core() and do_luna().
# shellcheck source=scripts/lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/qmd-bin.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
PROFILE="core"
SCOPE="project"
TARGET="$PWD"
LUNA_TARGET=""
LUNA_TARGET_SET=0
DRY_RUN=0
FILL_ENV=0

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="$2"; shift 2 ;;
    --scope)        SCOPE="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --luna-target)  LUNA_TARGET="$2"; LUNA_TARGET_SET=1; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --fill-env)     FILL_ENV=1; shift ;;
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
  # bash/git/jq/python3 are the harness-agnostic core deps — hard-required.
  for t in bash git jq python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    echo "  see $HIMMEL_ROOT/docs/setup/new-machine.md (Required environment)" >&2
    exit 1
  fi
  # `claude` is SOFT (HIMMEL-600): the portable core + git gates are
  # harness-agnostic, and only the Claude plugin-install step needs the CLI. A
  # Codex-only (or any non-Claude) adopter still gets the core — don't reject it.
  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_AVAILABLE=0
    echo "WARN: 'claude' not found — installing the harness-agnostic core only;" >&2
    echo "      skipping the Claude plugin-install step (Codex-only adopter is fine)." >&2
  fi
  # `bun` is SOFT (HIMMEL-752 G2): qmd search is the only do_core step that
  # needs it, and the harness-agnostic core + git gates run without it. Warn with the
  # install hint; wire_qmd_core consults BUN_AVAILABLE and skips qmd cleanly.
  if ! command -v bun >/dev/null 2>&1; then
    BUN_AVAILABLE=0
    echo "WARN: 'bun' not found — qmd search will be skipped;" >&2
    echo "      install: https://bun.sh (runs handover armed-resume, qmd search, the Telegram bridge, obsidian-triage tools)" >&2
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

install_plugins() {
  if [[ "${CLAUDE_AVAILABLE:-1}" -eq 0 ]]; then
    echo "──── Skipping plugin install ('claude' not found — non-Claude adopter) ────"
    return 0
  fi
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

# statusLine — part of the core harness (HIMMEL-359). Wired into the
# scope-appropriate settings.json. Both scopes reference THIS himmel clone's
# vendored statusline (it is never copied per-repo), so a project-scope
# settings.json carries this machine's clone path by design.
wire_statusline_core() {
  local settings
  if [[ "$SCOPE" == "project" ]]; then
    settings="$TARGET/.claude/settings.json"
  else
    settings="$HOME/.claude/settings.json"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: wire statusLine → $settings (himmel: $HIMMEL_ROOT)"
    return
  fi
  bash "$HIMMEL_ROOT/scripts/lib/wire-statusline.sh" "$settings" "$HIMMEL_ROOT"
}

# env.HIMMEL_REPO — default-by-install (HIMMEL-453). Sibling of
# wire_statusline_core: write THIS himmel clone's path into the scope-appropriate
# settings.json so the leg resolver + minerva anchor get it without a manual set.
wire_himmel_repo_core() {
  local settings
  if [[ "$SCOPE" == "project" ]]; then
    settings="$TARGET/.claude/settings.json"
  else
    settings="$HOME/.claude/settings.json"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: wire env.HIMMEL_REPO → $settings (himmel: $HIMMEL_ROOT)"
    return
  fi
  bash "$HIMMEL_ROOT/scripts/lib/wire-himmel-repo.sh" "$settings" "$HIMMEL_ROOT"
}

# env.LUNA_VAULT_PATH — persist the scaffolded vault path (HIMMEL-458) so the
# end-session-wiki resolver (vault-resolve.sh step 3) finds the vault the
# operator scaffolded without a manual export. Sibling of wire_himmel_repo_core;
# written to the scope-appropriate settings.json. $1 = the scaffolded vault dir.
wire_luna_vault_path() {
  local dest="$1" settings
  if [[ "$SCOPE" == "project" ]]; then
    settings="$TARGET/.claude/settings.json"
  else
    settings="$HOME/.claude/settings.json"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: wire env.LUNA_VAULT_PATH → $settings (vault: $dest)"
    return
  fi
  bash "$HIMMEL_ROOT/scripts/lib/wire-luna-vault.sh" "$settings" "$dest"
}

# --fill-env (HIMMEL-453): fill the himmel clone's .env. We target
# $HIMMEL_ROOT/.env (NOT $TARGET/.env) for BOTH scopes because adopt copies only
# portable hooks — never the Jira CLI — so an adopted repo always invokes
# `node $HIMMEL_ROOT/scripts/jira/...`, whose repoRoot() reads $HIMMEL_ROOT/.env.
fill_env_core() {
  [[ $DRY_RUN -eq 1 ]] && { echo "DRY: fill $HIMMEL_ROOT/.env"; return; }
  if [[ ! -f "$HIMMEL_ROOT/.env" ]] && [[ -f "$HIMMEL_ROOT/.env.example" ]]; then
    cp "$HIMMEL_ROOT/.env.example" "$HIMMEL_ROOT/.env"
  fi
  if [[ -f "$HIMMEL_ROOT/.env" ]]; then
    bash "$HIMMEL_ROOT/scripts/setup/fill-env.sh" "$HIMMEL_ROOT/.env" "$HIMMEL_ROOT/.env.example" \
      || echo "  WARNING: fill-env failed; continuing." >&2
  fi
}

# wire_qmd_core — wire the qmd search stack end-to-end (HIMMEL-752 G1/G3/G4):
# fix the broken plugin-cache stub, install the qmd CLI if missing (qmd_install
# verifies the binary and heals a missing better-sqlite3 native build), pull the
# embedding/rerank models, and register the himmel clone as a collection.
# Best-effort throughout: every failure WARNs and returns 0 so a missing or
# broken qmd never aborts an adopt. Called from do_core() after install_plugins
# (the qmd Claude plugin lands there; this makes the qmd CLI + models work).
# Honors --dry-run (DRY: lines) and the BUN_AVAILABLE soft-check flag.
wire_qmd_core() {
  if [[ "${BUN_AVAILABLE:-1}" -eq 0 ]]; then
    echo "──── Skipping qmd wiring (bun not found) ────"
    echo "  Install bun to enable qmd search: https://bun.sh"
    return 0
  fi
  echo "──── Wiring qmd search ────"
  # G1: neutralize the broken qmd plugin-cache stub so plain `qmd` works inside
  # Claude's Bash tool too (HIMMEL-163). WARN-not-fail.
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: bash $HIMMEL_ROOT/scripts/lib/fix-qmd-stub.sh"
  else
    bash "$HIMMEL_ROOT/scripts/lib/fix-qmd-stub.sh" \
      || echo "  WARNING: fix-qmd-stub failed — continuing." >&2
  fi
  # Install the qmd CLI if missing. qmd_install verifies + heals (HIMMEL-752 G3).
  if [[ $DRY_RUN -eq 1 ]]; then
    has_qmd || echo "DRY: qmd_install"
  elif ! has_qmd; then
    qmd_install || echo "  WARNING: qmd install failed — continuing without qmd." >&2
  fi
  # G4: pull the embedding/rerank models. Size caveat FIRST so the operator can
  # Ctrl-C before the ~2.1 GB download, then best-effort pull (never abort adopt).
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: qmd pull (downloads ~2.1 GB of embedding/rerank models)"
  elif has_qmd; then
    echo "  Pulling qmd models (downloads ~2.1 GB of embedding/rerank models)..."
    if ! qmd_cmd pull; then
      echo "  WARNING: qmd pull failed — semantic search needs the models." >&2
      echo "  Pull manually: qmd pull" >&2
    fi
  fi
  # Register the himmel clone itself as a collection.
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: qmd_register_collection $HIMMEL_ROOT himmel"
  elif has_qmd; then
    qmd_register_collection "$HIMMEL_ROOT" himmel || true
  fi
}

do_core() {
  require_tools
  if [[ "$SCOPE" == "project" ]]; then
    copy_portable
    # Literal $CLAUDE_PROJECT_DIR — Claude Code expands it at hook-fire time.
    # shellcheck disable=SC2016
    wire_pretooluse_hooks "$TARGET/.claude/settings.json" '$CLAUDE_PROJECT_DIR' "$DRY_RUN"
    echo "  worktree commands: bash $TARGET/scripts/worktree.sh feat/slug"
  else
    # user scope: reference this himmel clone, don't copy per-repo. Wire the full
    # UNIVERSAL set — the PreToolUse trio AND the SessionStart leg-injector — so a
    # session launched anywhere gets the legs (parity with setup.sh / R3).
    wire_pretooluse_hooks "$HOME/.claude/settings.json" "$HIMMEL_ROOT" "$DRY_RUN"
    wire_sessionstart_hook "$HOME/.claude/settings.json" "$HIMMEL_ROOT" "inject-initiative.sh" "$DRY_RUN"
    echo "  worktree commands run from the himmel clone: bash $HIMMEL_ROOT/scripts/worktree.sh feat/slug"
  fi
  install_plugins
  wire_qmd_core
  wire_statusline_core
  wire_himmel_repo_core
  [[ $FILL_ENV -eq 1 ]] && fill_env_core
  echo "  (optional) pre-commit gates: see $HIMMEL_ROOT/docs/setup/use-on-your-project.md (Pre-commit hooks)"
}

do_luna() {
  local dest="$1"
  echo "──── Scaffolding luna vault → $dest ────"
  if [[ -e "$dest" && $DRY_RUN -ne 1 ]]; then
    echo "  $dest already exists — skipping copy (re-run the vault's own setup to update)"
  else
    run mkdir -p "$(dirname "$dest")"
    run cp -r "$HIMMEL_ROOT/templates/luna-second-brain" "$dest"
  fi
  # Persist the vault path UNCONDITIONALLY — a re-run over an existing scaffold
  # (skipped copy above) must still wire a previously-unwired install (HIMMEL-458).
  wire_luna_vault_path "$dest"
  # G5 (HIMMEL-752): register the scaffolded vault as a qmd collection so it is
  # queryable immediately. Skip + note when qmd/bun unavailable; WARN-not-fail.
  # For --profile all, do_core (→ wire_qmd_core) has already installed qmd; for
  # --profile luna alone it may be absent, in which case has_qmd skips cleanly.
  if [[ "${BUN_AVAILABLE:-1}" -eq 0 ]]; then
    echo "  qmd: skipping luna collection registration (bun not found)"
  elif [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: qmd_register_collection $dest luna"
  elif has_qmd; then
    qmd_register_collection "$dest" luna || true
  else
    echo "  qmd: skipping luna collection registration (qmd not installed)"
  fi
  echo "  next: cd \"$dest\" && bash scripts/setup.sh   (idempotent; prints the plugin-install commands)"
}

_dry_note=""; [[ $DRY_RUN -eq 1 ]] && _dry_note=" (dry-run)"
echo "==> himmel adopt — profile=$PROFILE scope=$SCOPE${_dry_note}"
case "$PROFILE" in
  core) do_core ;;
  # `luna` historically used --target; also honor an explicit --luna-target so
  # the intuitive `--profile luna --luna-target` is no longer a silent no-op
  # (HIMMEL-458 critic #3). --target still wins when --luna-target is absent.
  luna) if [[ $LUNA_TARGET_SET -eq 1 ]]; then do_luna "$LUNA_TARGET"; else do_luna "$TARGET"; fi ;;
  all)  do_core; do_luna "$LUNA_TARGET" ;;
esac
echo "──── Done ────"
