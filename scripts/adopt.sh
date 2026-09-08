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
#            to reference THIS himmel clone (native Git gates are copied).
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
#   --skip-hooks        Opt out of placing the git gate hooks (pre-commit,
#                       commit-msg, pre-push) in --target. On by default
#                       (HIMMEL-2441) so a fresh adopt is gated from its first
#                       commit; mirrors uninstall.sh's own --skip-hooks.
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

# wire_user_claude_md (HIMMEL-2038): appends the "working principles" block
# from docs/setup/user-scope-claude-md-template.md into the user-scope rule
# files (~/.claude/CLAUDE.md + ~/.codex/AGENTS.md). Consumed by do_core() in
# BOTH scopes — the principles live at user scope whichever way core installs.
# shellcheck source=scripts/lib/user-claude-md.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/user-claude-md.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
PROFILE="core"
SCOPE="project"
TARGET="$PWD"
LUNA_TARGET=""
LUNA_TARGET_SET=0
DRY_RUN=0
FILL_ENV=0
WITH_GRAPHIFY=0
SKIP_HOOKS=0

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
    --skip-hooks)     SKIP_HOOKS=1; shift ;;
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
  scripts/hooks/check-commit-msg.sh
  scripts/hooks/check-worktree-isolation.sh
  scripts/hooks/check-push-target.sh
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
  # HIMMEL-2435: an adopter cloning himmel itself and running `adopt.sh
  # --scope project` (or the wizard deriving scope=project) from inside that
  # clone has TARGET == HIMMEL_ROOT — the portable core is already in place,
  # so `cp src dest` on the same file aborts with "are the same file". Compare
  # by inode (-ef), not string: a trailing slash, a symlinked path segment, or
  # drive-letter casing can make TARGET and HIMMEL_ROOT differ textually while
  # naming the same directory. Both are real directories by this point, so -ef
  # is safe. This is the single place BOTH the wizard-derived route and a
  # by-hand `adopt.sh --scope project --target <checkout>` invocation pass
  # through, so guarding here (not at the call site or in scope derivation)
  # covers both.
  if [ "$TARGET" -ef "$HIMMEL_ROOT" ]; then
    echo "──── Portable core already in place (target is the himmel clone) — skipping copy ────"
    return 0
  fi
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

# env.HANDOVER_DIR — seed the handover state root at the scaffolded luna vault
# (HIMMEL-839). Without this, a fresh adopter's handover state silently
# defaults to the inline <repo-root>/handovers/ stub and the operator has to
# discover + set HANDOVER_DIR by hand (observed on a fresh ubuntu_new install
# with no prior state). Creates <dest>/handovers/ so Mode B resolves cleanly
# out of the box (handover_root's pure resolver fails closed on a missing
# dir — scripts/lib/handover-path.sh). Sibling of wire_luna_vault_path; $1 =
# the scaffolded vault dir.
wire_handover_dir_luna() {
  local dest="$1" hdir settings envfile existing
  hdir="$dest/handovers"
  if [[ "$SCOPE" == "project" ]]; then
    settings="$TARGET/.claude/settings.json"
  else
    settings="$HOME/.claude/settings.json"
  fi
  # PRESERVE an operator-selected HANDOVER_DIR (HIMMEL-839 CR round-2): a
  # routine re-adopt must reproduce state, never silently reset it.
  # /handover-setup is documented as "the only place the state-root location
  # is chosen interactively" (handover-setup.md) — adopt.sh must not become a
  # second, silent place that overrides that choice. Two places it could
  # already live:
  #   1. This settings.json's own env.HANDOVER_DIR (a prior adopt run).
  #   2. The primary checkout's .env (set-handover-dir.sh / Mode B — the
  #      actual file /handover-setup writes to). settings.json env takes
  #      PROCESS-ENV precedence over .env (scripts/lib/load-dotenv.sh only
  #      fills currently-unset vars), so writing here would silently SHADOW
  #      that choice even though the .env file itself stayed untouched.
  if [[ -f "$settings" ]] && command -v jq >/dev/null 2>&1; then
    existing="$(jq -r '.env.HANDOVER_DIR // empty' "$settings" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
      echo "  env.HANDOVER_DIR already set in $settings ($existing) — leaving it (re-adopt reproduces, never resets; HIMMEL-839)"
      return
    fi
  fi
  envfile="$HIMMEL_ROOT/.env"
  if [[ -f "$envfile" ]] && grep -qE '^[[:space:]]*HANDOVER_DIR=' "$envfile"; then
    echo "  HANDOVER_DIR already set in $envfile (via /handover-setup) — leaving it, not wiring env.HANDOVER_DIR into $settings (HIMMEL-839)"
    return
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: mkdir -p $hdir"
    echo "DRY: wire env.HANDOVER_DIR → $settings (handover dir: $hdir)"
    return
  fi
  mkdir -p "$hdir"
  # Canonicalize to an absolute path (HIMMEL-839 CR round-2): a relative
  # --luna-target would otherwise persist a CWD-dependent relative path into
  # settings.json, resolving against whatever CWD a later session happens to
  # launch from. Same idiom scripts/handover/set-handover-dir.sh already uses.
  # shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not a quote escape
  hdir="$(cd "$hdir" && pwd | tr '\\' '/')"
  bash "$HIMMEL_ROOT/scripts/lib/wire-handover-dir.sh" "$settings" "$hdir"
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
    echo "DRY: claude mcp add -s $SCOPE graphify -- <graphify-mcp: absolute path for user/local, bare name for project>"
    echo "DRY: graphify_price_hooks \"$TARGET\""
    return 0
  fi
  # Install the CLI first; a failed install returns before we try to register
  # the MCP server (there'd be no graphify-mcp entrypoint to register). MCP
  # registration is the shared graphify-bin.sh impl — adopt's SCOPE (project|
  # user) is a valid `claude mcp add -s` scope (HIMMEL-1047).
  graphify_install || { echo "  WARNING: graphify install failed — continuing without graphify." >&2; return 0; }
  if [[ "$SCOPE" == "project" ]]; then
    # project scope writes the committed .mcp.json relative to CWD (mirrors
    # install_plugins) — run from $TARGET so it lands in the adopted repo.
    ( cd "$TARGET" && graphify_register_mcp "$SCOPE" )
  else
    graphify_register_mcp "$SCOPE"
  fi
  # HIMMEL-2480: price the hooks in the ADOPTED repo, not himmel's own — adopt
  # targets $TARGET, so the root must be passed explicitly.
  graphify_price_hooks "$TARGET"
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

# _native_hooks_canon <path> — print <path> resolved to an absolute,
# PHYSICAL (symlink-free) form, tolerating a path that does not exist yet:
# bash 3.2 / macOS ship no `realpath`, so this resolves component-by-component
# from the root -- exactly what `realpath`/the kernel does, which is why it
# has no unemulated corner: a ".." is applied to a path that has ALREADY been
# physically resolved up to that point (so it pops the REAL parent, as the
# kernel does), and every component that exists is resolved to its physical
# form the MOMENT it is appended -- including one that only becomes reachable
# after an earlier ".." fold. A component that does not exist yet cannot be a
# symlink, so leaving it as the literal string and continuing is exact for
# that component, not an approximation -- it is what makes the trailing
# not-yet-created tail safe.
#
# Prior versions each hand-emulated one piece of this and left a different
# piece unemulated -- that pattern is why this is a full rewrite rather than
# a fourth patch (HIMMEL-2771 CR):
#   - round-2: resolved only the deepest existing ancestor, via LOGICAL
#     cd+pwd. A core.hooksPath symlink INSIDE the target pointing OUTSIDE it
#     preserved the symlink instead of resolving it, passing containment.
#   - round-3: switched that single resolution to PHYSICAL cd -P/pwd -P, but
#     reattached the not-yet-created tail UNCHANGED, so an unfolded ".." in
#     the tail (e.g. "new/../../outside" with "new" absent) was compared as a
#     literal string that still held "..", passing containment even though
#     `mkdir -p` resolves it and escapes $TARGET.
#   - round-4: folded "." and ".." out of that tail lexically, but the fold
#     could RE-EXPOSE a symlink the walk-up never looked at: with
#     "new/../hookslink" ("new" absent, "hookslink" a symlink out of the
#     target), the walk-up strips the whole tail back to the target without
#     ever seeing "hookslink", then the fold reattaches it as a plain string
#     that nothing ever resolves.
# Component-wise resolution has no walk-up and no reattached tail, so none of
# these three holes exist here: every component is resolved (or provably
# cannot be a symlink) at the moment it becomes part of the accumulated path,
# regardless of whether a ".." fold is what made it reachable.
#
# Used by install_native_hooks() to check a resolved core.hooksPath against
# $TARGET.
_native_hooks_canon() {
  local p="$1" acc comp remaining resolved
  # Anchor a relative input to $PWD before resolving -- resolution below
  # walks component-by-component from "/", so an unanchored relative path
  # would otherwise resolve against the wrong base entirely.
  [[ "$p" == /* ]] || p="$PWD/$p"
  acc="/"
  remaining="$p"
  while [[ -n "$remaining" ]]; do
    remaining="${remaining#/}"
    case "$remaining" in
      */*) comp="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) comp="$remaining"; remaining="" ;;
    esac
    case "$comp" in
      ""|.) : ;;
      ..)
        # Pop one component off $acc. $acc is already physically resolved up
        # to this point (below), so this pops the REAL parent -- exactly what
        # the kernel does for "..", including a ".." that only became
        # meaningful after an earlier "new/.." was folded away. Already at
        # "/" (or popping a single-component path) collapses back to "/",
        # never "".
        acc="${acc%/*}"
        [[ -n "$acc" ]] || acc="/"
        ;;
      *)
        if [[ "$acc" == "/" ]]; then
          acc="/$comp"
        else
          acc="$acc/$comp"
        fi
        # Resolve $acc to its physical form the MOMENT it exists as a
        # directory (or a symlink to one) -- this is what catches a symlink
        # that only becomes reachable after an earlier ".." fold (HIMMEL-2771
        # CR round-4): there is no separate walk-up pass that could run
        # before this component exists and so never look at it. A component
        # that does not exist yet cannot be a symlink, so leaving it as the
        # literal string and continuing is exact, not an approximation.
        if [[ -d "$acc" ]]; then
          if resolved="$(cd -P "$acc" 2>/dev/null && pwd -P)"; then
            acc="$resolved"
          fi
          # cd -P can fail here despite `-d` succeeding -- a search-permission
          # denial on the directory, or (rarer) a symlink loop. Do not accept
          # the unresolved literal AS IF it were physically resolved; leave
          # $acc as the literal string and keep going, same as the
          # does-not-exist-yet case. This cannot be leveraged to escape
          # containment: whatever defeated `cd -P` here (no search
          # permission, a loop) equally defeats the `mkdir -p`/hook-file write
          # install_native_hooks() performs through this same component
          # afterward, so nothing is ever actually written past it even if
          # the string comparison downstream happened to read as "inside".
        fi
        ;;
    esac
  done
  printf '%s\n' "$acc"
}

install_native_hooks() {
  # HIMMEL-2771: resolve Git's effective hook directory (including worktrees
  # and core.hooksPath), but keep hook payloads independent of this clone.
  local hooks_dir hook script hooks_dir_canon target_canon backup marker
  local common_dir common_dir_canon payload_dir payload_file
  marker='# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.'
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: place executable native commit-msg, pre-commit, pre-push hooks in $TARGET (fallback if pre-commit is unavailable or fails)"
    echo "DRY: copy native gate scripts and guardrails/lib.sh into $TARGET if needed"
    return 0
  fi
  if ! hooks_dir=$(git -C "$TARGET" rev-parse --git-path hooks); then
    echo "  git gate hooks — FAILED (native: cannot resolve hooks directory in $TARGET)" >&2
    return 1
  fi
  [[ "$hooks_dir" == /* ]] || hooks_dir="$TARGET/$hooks_dir"
  # CR: a SHARED/absolute core.hooksPath (e.g. a global ~/.githooks used by
  # many repos) must be refused outright, not written into -- our dispatcher
  # hooks resolve `git rev-parse --show-toplevel` at FIRE time, so placing
  # them in a hooksPath outside $TARGET would break every OTHER repo sharing
  # it (script path would not exist there -> bash exits 127 on every commit).
  # A repo-relative hooksPath that resolves inside $TARGET (the existing
  # `user-hooks-path` control) must keep working, so this is a boundary
  # check, not a "must be under .git" check. Compared with trailing slashes
  # so "/target-evil" cannot pass as inside "/target" via a naive prefix match.
  hooks_dir_canon="$(_native_hooks_canon "$hooks_dir")"
  target_canon="$(_native_hooks_canon "$TARGET")"
  # HIMMEL-2771 CR round-5 (codex-1, confirmed): the boundary check above
  # applies uniformly, but an ORDINARY linked worktree has no configured
  # core.hooksPath at all -- its default hooks dir is Git's own per-repository
  # `<common-git-dir>/hooks`, which lives in the PRIMARY checkout's .git, not
  # under this worktree's $TARGET. Refusing that as "outside the target" is
  # wrong on two counts: it blocks a Git-managed layout the boundary check was
  # never meant to catch (shared only among worktrees OF THIS REPO, every one
  # of which carries the same scripts/hooks/... in its tree -- accepting it
  # does not weaken the shared-hooksPath property this check defends), and the
  # resulting message names `core.hooksPath` as the culprit when it is unset,
  # prescribing a remedy ("unset it") the adopter cannot perform. Branch on
  # whether core.hooksPath is actually configured: `git config --get` exits
  # non-zero when the key is absent, so treat that as "unset" rather than
  # letting `set -e` kill the run.
  if git -C "$TARGET" config --get core.hooksPath >/dev/null 2>&1; then
    case "$hooks_dir_canon/" in
      "$target_canon"/*) ;;
      *)
        echo "  git gate hooks — FAILED (native: core.hooksPath $hooks_dir_canon is outside $target_canon — unset it or set it to a path inside the target, then re-run)" >&2
        return 1
        ;;
    esac
  else
    # Unset: accept the default hooks dir when it sits inside $TARGET (the
    # common case) OR inside the git COMMON directory Git itself names via
    # `rev-parse --git-common-dir` (the linked-worktree case). This is still a
    # positive containment check against a path Git named, not "unset =>
    # accept anything" -- a hooks dir that lands somewhere else with
    # core.hooksPath unset is not a shape Git produces and must still be
    # refused. `--git-common-dir` can be relative (e.g. plain ".git" in a
    # non-worktree repo); anchor it to $TARGET exactly as $hooks_dir is
    # anchored above.
    common_dir="$(git -C "$TARGET" rev-parse --git-common-dir)"
    [[ "$common_dir" == /* ]] || common_dir="$TARGET/$common_dir"
    common_dir_canon="$(_native_hooks_canon "$common_dir")"
    case "$hooks_dir_canon/" in
      "$target_canon"/*|"$common_dir_canon"/*) ;;
      *)
        echo "  git gate hooks — FAILED (native: cannot resolve a safe hooks directory for $TARGET — default hooks dir $hooks_dir_canon is outside both the target ($target_canon) and its git common directory ($common_dir_canon); this is not a normal repository layout)" >&2
        return 1
        ;;
    esac
  fi
  if ! mkdir -p "$hooks_dir"; then
    echo "  git gate hooks — FAILED (native: cannot create hooks directory $hooks_dir)" >&2
    return 1
  fi
  # HIMMEL-2771 CR round-6 (codex-1, confirmed): round-5's fix above teaches
  # adopt to ACCEPT the shared common-dir hooks layout, but the payload
  # (scripts/hooks/*.sh + guardrails/lib.sh) was copied only into $TARGET (the
  # linked worktree). Git's hooks are per-repository, not per-worktree, so
  # that one directory serves the primary checkout and every linked worktree,
  # while the payload is copied only into $TARGET. The generated dispatchers
  # resolve `$root/scripts/hooks/<script>` at FIRE time via
  # `git rev-parse --show-toplevel`, so in the primary (and any sibling
  # worktree) $root is NOT $TARGET and the script is absent -> every commit
  # and push there starts failing with a bash "No such file" error. Do NOT
  # copy into those other checkouts -- writing into directories the adopter
  # never named is exactly the boundary this PR has spent five rounds
  # defending, and it would not cover worktrees created LATER anyway. Instead,
  # when the hooks dir is OUTSIDE $TARGET (the shared-common-dir case), stash
  # a payload copy beside the shared hooks dir itself -- a subdirectory of
  # .git/hooks/ is inert to Git (it only ever executes files named exactly
  # like a hook) -- and teach the dispatcher (below) to fall back to it when
  # $root/scripts/hooks/<script> is missing.
  case "$hooks_dir_canon/" in
    "$target_canon"/*) payload_dir="" ;;   # hooks live inside the target: $root always resolves
    *)                 payload_dir="$hooks_dir/himmel-payload" ;;
  esac
  if [[ -n "$payload_dir" ]]; then
    # Preserve the relative layout: check-worktree-isolation.sh and
    # check-push-target.sh both `source "$SCRIPT_DIR/../guardrails/lib.sh"`,
    # so a flat copy would break them.
    for payload_file in scripts/hooks/check-commit-msg.sh scripts/hooks/check-worktree-isolation.sh scripts/hooks/check-push-target.sh scripts/guardrails/lib.sh; do
      if ! mkdir -p "$payload_dir/$(dirname "$payload_file")" || ! cp "$HIMMEL_ROOT/$payload_file" "$payload_dir/$payload_file"; then
        echo "  git gate hooks — FAILED (native: cannot copy $payload_file into $payload_dir)" >&2
        return 1
      fi
    done
    if ! chmod +x "$payload_dir/scripts/hooks/check-commit-msg.sh" \
                  "$payload_dir/scripts/hooks/check-worktree-isolation.sh" \
                  "$payload_dir/scripts/hooks/check-push-target.sh"; then
      echo "  git gate hooks — FAILED (native: cannot chmod +x payload scripts in $payload_dir)" >&2
      return 1
    fi
    echo "  git gate hooks — payload copied to $payload_dir (shared hooks directory serves other checkouts too; dispatchers fall back to it when their own \$root lacks scripts/hooks)"
  fi
  # User scope normally references this clone; native Git gates must survive
  # its removal too. Project scope already copied these portable files.
  if [[ "$SCOPE" == "user" && ! "$TARGET" -ef "$HIMMEL_ROOT" ]]; then
    for script in scripts/hooks/check-commit-msg.sh scripts/hooks/check-worktree-isolation.sh scripts/hooks/check-push-target.sh scripts/guardrails/lib.sh; do
      if ! mkdir -p "$TARGET/$(dirname "$script")" || ! cp "$HIMMEL_ROOT/$script" "$TARGET/$script"; then
        echo "  git gate hooks — FAILED (native: cannot copy $script into $TARGET)" >&2
        return 1
      fi
    done
  fi
  for hook in commit-msg pre-commit pre-push; do
    case "$hook" in
      commit-msg) script=check-commit-msg.sh ;;
      pre-commit) script=check-worktree-isolation.sh ;;
      pre-push) script=check-push-target.sh ;;
    esac
    # CR: `cat >` truncates unconditionally, which would silently destroy an
    # adopter's own hand-written hook (pre-commit's own `install` migrates a
    # pre-existing hook to `<hook>.legacy` instead of destroying it -- mirror
    # that here). Skip the backup when the existing file is already OURS
    # (marker match): re-running adopt must not keep re-backing-up our own
    # generated hook, which would overwrite the adopter's REAL backup with a
    # copy of our own output on a second run.
    #
    # HIMMEL-2771 CR round-5 (codex-2, confirmed): the directory-level
    # containment check above cannot see a per-file SYMLINK escape --
    # $hooks_dir itself is legitimately inside the target; it is this one
    # directory ENTRY that escapes. A DANGLING symlink is not `-e`, so it
    # skipped the backup branch entirely; a symlink to an outside file that
    # happens to already carry our marker made `grep -qF` (which follows the
    # link) look like "already ours" and skipped it too -- either way the
    # `cat >` below then followed the link and created/truncated a file
    # OUTSIDE $TARGET. Test for a symlink FIRST, before the `-e`/marker logic
    # ever runs: our own generated hook is always a plain regular file we
    # wrote with `cat >`, never a symlink, so a symlink here is never ours and
    # must always be backed up, unconditionally.
    if [[ -L "$hooks_dir/$hook" ]]; then
      backup="$hooks_dir/$hook.himmel-backup"
      # Same blind spot on the backup side: a DANGLING symlink at $backup is
      # not `-e` either. Widen this guard to refuse a symlink at $backup too,
      # whatever it points at (or fails to).
      if [[ -e "$backup" || -L "$backup" ]]; then
        echo "  git gate hooks — FAILED (native: $backup already exists — move it aside and re-run)" >&2
        return 1
      fi
      # `mv` renames the LINK ITSELF -- it never follows it -- so this step
      # reads/writes nothing outside $TARGET regardless of what the link
      # points at (or whether it resolves at all).
      if ! mv "$hooks_dir/$hook" "$backup"; then
        echo "  git gate hooks — FAILED (native: cannot back up existing $hooks_dir/$hook)" >&2
        return 1
      fi
      # The backup is now a symlink (possibly dangling) at
      # <hook>.himmel-backup. The generated dispatcher below chains to it via
      # `[ -x "$backup" ]`, which FOLLOWS the link: a dangling link is never
      # -x, so it silently never runs (equivalent to "no prior hook", not a
      # failure); a link still resolving to something executable runs exactly
      # as before. So "still runs" is NOT an unconditional promise for a
      # symlinked hook -- say so instead of the plain claim used below.
      echo "  git gate hooks — existing $hook (a symlink) backed up to $hook.himmel-backup (chained after the himmel gate only if the link still resolves to something executable; a dangling link will not run)"
    elif [[ -e "$hooks_dir/$hook" ]] && ! grep -qF "$marker" "$hooks_dir/$hook" 2>/dev/null; then
      backup="$hooks_dir/$hook.himmel-backup"
      if [[ -e "$backup" || -L "$backup" ]]; then
        echo "  git gate hooks — FAILED (native: $backup already exists — move it aside and re-run)" >&2
        return 1
      fi
      if ! mv "$hooks_dir/$hook" "$backup"; then
        echo "  git gate hooks — FAILED (native: cannot back up existing $hooks_dir/$hook)" >&2
        return 1
      fi
      echo "  git gate hooks — existing $hook backed up to $hook.himmel-backup (still runs: chained after the himmel gate)"
    fi
    # CR round-2: `exec` replaces the shell, so the adopter's backed-up hook
    # (above) would never run again -- its bytes survive but nothing ever
    # invokes it, silently switching off the adopter's own gate. Run the
    # himmel gate first, then the backup if present, and fail the operation
    # if EITHER exits non-zero -- neither may mask the other. Resolve the
    # backup from the hook's OWN directory via $0, not the repo root: a
    # core.hooksPath inside $TARGET means the hooks don't live in
    # .git/hooks. `${0%/*}` returns $0 unchanged when it has no "/" (a bare
    # basename), so compare against $0 to detect that case instead of
    # trusting the result blindly (the same "unchanged means no-op happened"
    # trap that _native_hooks_canon avoids above by keeping its accumulator
    # rooted at "/", so its own `${acc%/*}` pop always has a "/" to strip).
    if [[ "$hook" == pre-push ]]; then
      # CR round-2: git feeds pre-push its ref list on STDIN, and
      # check-push-target.sh drains it once (its own header says stdin
      # cannot be re-read). Running the gate then the backup straight would
      # leave the backup reading an already-drained, EOF stdin -- it would
      # see zero ref lines and fall through to exit 0 no matter what it was
      # meant to refuse (the exact "silently ungated" class HIMMEL-2771
      # exists to close). Snapshot stdin ONCE into a temp file via `cat`
      # (byte-for-byte, no command-substitution newline stripping) and feed
      # BOTH the gate and the backup that same file. A terminal stdin (a
      # manual invocation, never git's real shape) is treated as
      # connected-but-empty rather than read, to avoid hanging on a TTY with
      # no piped input; check-push-target.sh treats "empty" the same way
      # whether or not it was actually read, so this is not a behaviour
      # change for the real-push shape.
      if ! cat > "$hooks_dir/$hook" <<HOOK
#!/usr/bin/env bash
$marker
root=\$(git rev-parse --show-toplevel) || exit 1
hook_dir=\${0%/*}
[ "\$hook_dir" != "\$0" ] || hook_dir=.
gate="\$root/scripts/hooks/$script"
[ -f "\$gate" ] || gate="\$hook_dir/himmel-payload/scripts/hooks/$script"
if [ ! -f "\$gate" ]; then
  echo "himmel gate: $script not found in \$root/scripts/hooks or \$hook_dir/himmel-payload — re-run adopt.sh against this repository" >&2
  exit 1
fi
reffile=\$(mktemp "\${TMPDIR:-/tmp}/himmel-prepush.XXXXXX") || exit 1
trap 'rm -f "\$reffile"' EXIT
if [ -t 0 ]; then
  : > "\$reffile"
else
  cat > "\$reffile"
fi
bash "\$gate" "\$@" < "\$reffile"
gate_rc=\$?
backup="\$hook_dir/$hook.himmel-backup"
backup_rc=0
if [ -x "\$backup" ]; then
  "\$backup" "\$@" < "\$reffile"
  backup_rc=\$?
fi
[ "\$gate_rc" -eq 0 ] && [ "\$backup_rc" -eq 0 ]
HOOK
      then
        echo "  git gate hooks — FAILED (native: cannot write $hooks_dir/$hook)" >&2
        return 1
      fi
    else
      if ! cat > "$hooks_dir/$hook" <<HOOK
#!/usr/bin/env bash
$marker
root=\$(git rev-parse --show-toplevel) || exit 1
hook_dir=\${0%/*}
[ "\$hook_dir" != "\$0" ] || hook_dir=.
gate="\$root/scripts/hooks/$script"
[ -f "\$gate" ] || gate="\$hook_dir/himmel-payload/scripts/hooks/$script"
if [ ! -f "\$gate" ]; then
  echo "himmel gate: $script not found in \$root/scripts/hooks or \$hook_dir/himmel-payload — re-run adopt.sh against this repository" >&2
  exit 1
fi
bash "\$gate" "\$@"
gate_rc=\$?
backup="\$hook_dir/$hook.himmel-backup"
backup_rc=0
if [ -x "\$backup" ]; then
  "\$backup" "\$@"
  backup_rc=\$?
fi
[ "\$gate_rc" -eq 0 ] && [ "\$backup_rc" -eq 0 ]
HOOK
      then
        echo "  git gate hooks — FAILED (native: cannot write $hooks_dir/$hook)" >&2
        return 1
      fi
    fi
    if ! chmod +x "$hooks_dir/$hook"; then
      echo "  git gate hooks — FAILED (native: cannot make $hooks_dir/$hook executable)" >&2
      return 1
    fi
  done
  echo "  git gate hooks — placed (native, no pre-commit framework: lint hooks absent)"
}

install_precommit_hooks() {
  # HIMMEL-2441: place the git gate hooks by default so an adopter's FIRST
  # commit is actually gated -- mirrors setup.sh's own [1/9]/[2/9] steps
  # (install pre-commit if missing, then wire all three hook types), against
  # $TARGET. --allow-missing-config keeps this safe for a genuine external
  # adopt target with no .pre-commit-config.yaml of its own: the hook wires
  # in but no-ops on every commit until the adopter's own config exists,
  # rather than hard-failing every commit (measured: a bare `pre-commit
  # install` + commit with zero config exits 1; --allow-missing-config exits
  # 0 and starts gating the moment a config is added, no re-install needed).
  if [[ $SKIP_HOOKS -eq 1 ]]; then
    echo "  git hooks: skipped (--skip-hooks)"
    return 0
  fi
  if [[ ! -e "$TARGET/.git" ]]; then
    echo "  git hooks: skipping ($TARGET is not a git repo)"
    return 0
  fi
  local precommit_bin="pre-commit"
  if ! command -v pre-commit >/dev/null 2>&1; then
    # HIMMEL-2771: installer failure must fall back to native gates, never
    # report a successful adoption with no gates. Try each available installer.
    local installer install_output candidate
    precommit_bin=""
    for installer in uv pipx python3; do
      command -v "$installer" >/dev/null 2>&1 || continue
      case "$installer" in
        uv)
          if ! run uv tool install pre-commit --quiet; then
            echo "  WARNING: git hooks: 'uv tool install pre-commit' failed — trying remaining installers." >&2
          fi
          ;;
        pipx)
          if ! run pipx install pre-commit; then
            echo "  WARNING: git hooks: 'pipx install pre-commit' failed — trying remaining installers." >&2
          fi
          ;;
        python3)
          if [[ $DRY_RUN -eq 1 ]]; then
            echo "DRY: python3 -m pip install --user pre-commit"
          elif ! install_output=$(python3 -m pip install --user pre-commit 2>&1); then
            if grep -q 'externally-managed-environment' <<< "$install_output"; then
              echo "  WARNING: git hooks: pip refused (externally-managed-environment / PEP 668) — falling back to native gates." >&2
            else
              echo "  WARNING: git hooks: 'python3 -m pip install --user pre-commit' failed — falling back to native gates: $install_output" >&2
            fi
          fi
          ;;
      esac
      # Bootstrap can succeed with its bin directory absent from this PATH.
      precommit_bin="$(command -v pre-commit || true)"
      if [[ -z "$precommit_bin" ]]; then
        for candidate in \
          "${UV_TOOL_BIN_DIR:-$HOME/.local/bin}/pre-commit" \
          "${PIPX_BIN_DIR:-$HOME/.local/bin}/pre-commit" \
          "$HOME/.local/bin/pre-commit" \
          "$HOME/.local/pipx/venvs/pre-commit/bin/pre-commit"; do
          if [[ -x "$candidate" ]]; then
            precommit_bin="$candidate"
            break
          fi
        done
      fi
      [[ -z "$precommit_bin" ]] || break
    done
    if [[ $DRY_RUN -eq 1 ]]; then
      install_native_hooks
      precommit_bin="${precommit_bin:-pre-commit}"
    elif [[ -z "$precommit_bin" ]]; then
      echo "  WARNING: git hooks: pre-commit is unavailable after bootstrap — falling back to native gates." >&2
      install_native_hooks
      return $?
    fi
  fi
  echo "──── Installing git gate hooks ($TARGET) ────"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: (cd $TARGET && $precommit_bin install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push)"
    return 0
  fi
  if ( cd "$TARGET" && "$precommit_bin" install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push ); then
    echo "  git hooks installed (pre-commit, commit-msg, pre-push)."
  else
    echo "  WARNING: git hook install failed — falling back to native gates." >&2
    install_native_hooks
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
  # HIMMEL-2038: the "working principles" defaults were demoted out of himmel's
  # always-on project CLAUDE.md (general engineering defaults, not himmel
  # invariants) -- adopters get them via this user-scope append instead. Runs in
  # BOTH scopes on purpose: the principles live at user scope whichever way core
  # was installed, so a project-scope adopter would otherwise pull the shortened
  # CLAUDE.md and silently lose them. Idempotent, so re-running adopt is also the
  # migration path for an install that predates this. WARN-not-fail: never let
  # this abort the rest of adopt.
  #
  # TWO targets, same call, same semantics: Claude Code reads
  # ~/.claude/CLAUDE.md, Codex reads ~/.codex/AGENTS.md -- installing only into
  # the Claude-only file would leave a Codex adopter with the principles
  # nowhere. Hermes is not a target: its himmel_agent profile SOUL
  # (scripts/hermes/assets/himmel-agent.SOUL.md) already states the same four.
  wire_user_claude_md "$HIMMEL_ROOT/docs/setup/user-scope-claude-md-template.md" "$HOME/.claude/CLAUDE.md" || true
  wire_user_claude_md "$HIMMEL_ROOT/docs/setup/user-scope-claude-md-template.md" "$HOME/.codex/AGENTS.md" || true
  install_plugins
  build_jira_cli
  wire_qmd_core
  [[ $WITH_GRAPHIFY -eq 1 ]] && wire_graphify_core
  wire_statusline_core
  wire_himmel_repo_core
  [[ $FILL_ENV -eq 1 ]] && fill_env_core
  install_precommit_hooks || exit $?
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
  # Seed HANDOVER_DIR the same way, same reasoning (HIMMEL-839).
  wire_handover_dir_luna "$dest"
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
