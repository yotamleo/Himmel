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
#   --with-graphify     Opt in to installing the graphify knowledge-graph CLI
#                       (himmel fork) during a `core`/`all` adopt. Off by
#                       default — the adoption verdict stays open (HIMMEL-621);
#                       this flag only installs the CLI (never over an
#                       existing foreign install — see scripts/lib/graphify-bin.sh).
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
# has_qmd / qmd_cmd / qmd_install / qmd_fork_served / qmd_register_collection,
# consumed by wire_qmd_core() and do_luna().
# shellcheck source=scripts/lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/qmd-bin.sh"

# graphify resolver (HIMMEL-891). Provides has_graphify / graphify_install /
# graphify_source / graphify_install_hint, consumed by wire_graphify_core()
# (opt-in via --with-graphify — unlike qmd, graphify is NOT wired by default;
# the adoption verdict stays open, HIMMEL-621).
# shellcheck source=scripts/lib/graphify-bin.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/graphify-bin.sh"

# Adopter preflight checks (HIMMEL-842). Provides the shared WARN-not-fail
# checks (uv/pipx, npm-less-node, jira-dist) consumed by require_tools() below.
# The standalone scripts/preflight-adopter.sh runner sources the same lib, so the
# two entry points report identically and can't drift (operator answer Q4).
# shellcheck source=scripts/lib/preflight-adopter.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/preflight-adopter.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
PROFILE="core"
SCOPE="project"
TARGET="$PWD"
LUNA_TARGET=""
LUNA_TARGET_SET=0
DRY_RUN=0
FILL_ENV=0
WITH_GRAPHIFY=0

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        PROFILE="$2"; shift 2 ;;
    --scope)          SCOPE="$2"; shift 2 ;;
    --target)         TARGET="$2"; shift 2 ;;
    --luna-target)    LUNA_TARGET="$2"; LUNA_TARGET_SET=1; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --fill-env)       FILL_ENV=1; shift ;;
    --with-graphify)  WITH_GRAPHIFY=1; shift ;;
    -h|--help)        sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
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
  # HIMMEL-842 adopter preflight: the shared advisory checks (uv/pipx,
  # npm-less-node, jira-dist) live in scripts/lib/preflight-adopter.sh and are
  # also run by the standalone scripts/preflight-adopter.sh runner. Each returns
  # 1 (after WARNing) when its gap is present; the `||` capture keeps a non-zero
  # return from aborting under set -e. The npm-less-node case escalates to a
  # HARD fail below when there is no JS package manager at all (npm AND bun both
  # absent): adopt is about to build dist/ artifacts (build_jira_cli) and cannot
  # proceed without one. When bun is present it covers every himmel JS build, so
  # the shared WARN stays advisory and adopt proceeds.
  local npm_gap=0
  preflight_check_uv_pipx       || true
  preflight_check_npm_invocable || npm_gap=1
  preflight_check_jira_dist     || true
  if [[ "$npm_gap" -eq 1 && "${BUN_AVAILABLE:-1}" -eq 0 ]]; then
    echo "ERROR: 'node' found but 'npm' is missing (Ubuntu's nodejs ships without npm) and 'bun' is absent — no JS package manager." >&2
    echo "  Install bun (works for all himmel builds): https://bun.sh" >&2
    echo "  OR Node + npm via NodeSource: https://github.com/nodesource/distributions" >&2
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
# clones the himmel qmd fork, builds it with bun, and junctions/symlinks it
# onto the bun-global @tobilu/qmd path -- HIMMEL-877), pull the embedding/rerank
# models, and register the himmel clone as a collection.
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
  # Install the qmd CLI unless the FORK is already the served install
  # (clone the fork + build + link -- HIMMEL-877). The gate is
  # qmd_fork_served, NOT has_qmd: a machine carrying the old upstream
  # bun-global install is qmd-present but must still MIGRATE to the fork
  # (CR codex-adv-1); qmd_install itself re-checks as the second line of
  # defense and backs the upstream directory up before linking.
  if [[ $DRY_RUN -eq 1 ]]; then
    qmd_fork_served || echo "DRY: qmd_install"
  elif ! qmd_fork_served; then
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

# wire_graphify_core — opt-in install of the graphify knowledge-graph CLI
# (HIMMEL-891). Unlike wire_qmd_core, this is NOT called unconditionally —
# do_core() below only calls it when --with-graphify was passed. Detects +
# adopts a foreign or already-himmel-fork install (graphify_install's own
# contract); never installs over an existing install. WARN-not-fail: a
# missing uv or a network hiccup must not abort adopt. Honors --dry-run.
wire_graphify_core() {
  echo "──── Wiring graphify (opt-in, --with-graphify) ────"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: graphify_install"
    return 0
  fi
  graphify_install || echo "  WARNING: graphify install failed — continuing without graphify." >&2
}

# build_jira_cli — build scripts/jira/dist/index.js (HIMMEL-842 gap 3). dist/ is
# a gitignored build artifact, so a fresh clone bootstrapped via adopt.sh hits
# MODULE_NOT_FOUND without this (CLAUDE.md's "worktrees lack dist/" warning is
# scoped too narrowly — a fresh PRIMARY clone via adopt.sh hits the identical
# failure). Ports scripts/setup.sh step [3/10]'s build block, gated on
# npm-or-bun presence (bun covers the Ubuntu node-without-npm case), and
# WARN-not-fail: a build failure warns with the manual command and returns 0 —
# matches wire_qmd_core's contract so a broken build never aborts an adopt.
# Unlike setup.sh, NO `npm link`: adopted repos invoke the clone's dist/index.js
# directly (`node $HIMMEL_ROOT/scripts/jira/dist/index.js`), so a global symlink
# isn't needed. Honors --dry-run.
build_jira_cli() {
  local jira_dir="$HIMMEL_ROOT/scripts/jira"
  # fix-batch F3: skip only when BOTH halves are present — a stale dist/
  # without node_modules/ (gitignored, so a dist/ leftover from a prior build
  # can outlive a node_modules/ wipe) previously passed as "already built"
  # then failed at runtime. Mirrors setup.sh's invariant (checks both).
  if [[ -d "$jira_dir/node_modules" && -f "$jira_dir/dist/index.js" ]]; then
    echo "  jira CLI dist already built — skipping"
    return 0
  fi
  local pm=""
  if command -v npm >/dev/null 2>&1; then
    pm=npm
  elif command -v bun >/dev/null 2>&1; then
    pm=bun
  fi
  if [[ -z "$pm" ]]; then
    echo "  jira CLI: skipping build (no npm or bun — install one to build dist/)." >&2
    echo "  Manual: (cd scripts/jira && npm install && npm run build)" >&2
    return 0
  fi
  echo "──── Building jira CLI (scripts/jira/dist) ────"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: (cd scripts/jira && $pm install && $pm run build)"
    return 0
  fi
  # npm takes --silent (matches setup.sh step [3/10]); bun has no --silent flag,
  # so branch the invocation rather than pass an unknown flag.
  local ok=1
  if [[ "$pm" == "npm" ]]; then
    ( cd "$jira_dir" && npm install --silent && npm run build --silent ) || ok=0
  else
    ( cd "$jira_dir" && bun install && bun run build ) || ok=0
  fi
  if [[ $ok -eq 1 ]]; then
    echo "  jira CLI built. Invoke: node $HIMMEL_ROOT/scripts/jira/dist/index.js --help"
  else
    echo "  WARNING: jira CLI build failed — continuing (the preflight flagged this too)." >&2
    echo "  Manual: (cd scripts/jira && $pm install && $pm run build)" >&2
    # WARN-not-fail: return 0 so a broken build never aborts adopt.
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
  build_jira_cli
  wire_qmd_core
  [[ $WITH_GRAPHIFY -eq 1 ]] && wire_graphify_core
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
