#!/usr/bin/env bash
# New-machine setup for the himmel repo.
# Run once after cloning: bash scripts/setup.sh
set -e

# Surface Ctrl-C as a real failure rather than letting set -e silently
# fold it into the "Setup complete" branch. Without this, an interrupt
# during step 6 (which shells out to handover-link.sh) would print
# WARNING then continue to the success footer, fooling the operator.
trap 'echo "setup interrupted by signal" >&2; exit 130' INT TERM

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# shellcheck source=lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/qmd-bin.sh"

# --- arg parse (HIMMEL-151) ---
# Optional flags only. Unknown args land in setup_extra_args for now —
# no flag uses them yet, but reserve the pattern.
WITH_CS=0
WITH_JIRA=0
setup_extra_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --with-cs) WITH_CS=1 ;;
    --with-jira) WITH_JIRA=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: bash scripts/setup.sh [--with-cs] [--with-jira]

Optional flags:
  --with-cs    Install claude-squad (cs) at the end of setup.
               Without the flag, interactive shells prompt; non-interactive
               shells skip. See docs/setup/claude-squad.md.
  --with-jira  Require Jira configuration: abort setup if JIRA_PROJECT_KEY
               is unset. Without the flag the check downgrades to a skip
               notice and Jira-dependent next-steps are omitted.
USAGE
      exit 0
      ;;
    *) setup_extra_args+=("$1") ;;
  esac
  shift
done

# Single PATH hoist for the whole script — uv (pre-commit step) and `npm link`
# (jira step) both drop binaries into ~/.local/bin. Avoids per-step duplicate
# `export PATH=...` lines.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

echo "==> himmel setup"
echo ""

# --- prereq verify (HIMMEL-123) ---
# Fail fast with install hints rather than partial-install + cryptic
# downstream errors. Checks foundational tools that 5+ scripts depend
# on. Per-platform extras (at, schtasks, realpath -m) are documented
# in docs/setup/new-machine.md but NOT failed-on here because the
# scripts that use them already include fallbacks (python3 for
# realpath; arm-resume picks the available scheduler).
echo "[0/10] Verifying foundational tools on PATH..."
_missing=()
for _tool in bash git node npm bun python3 jq gh mktemp; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    _missing+=("$_tool")
  fi
done

# Bash version: 8 scripts use mapfile (bash 4+). Warn on bash 3.x rather
# than fail-hard — those scripts will error at invocation time with a
# clear "mapfile: command not found", and the foundational ones (e.g.
# Claude PreToolUse hooks) are all bash 3.2-compatible.
_bash_major=$(bash -c 'echo "${BASH_VERSION:0:1}"' 2>/dev/null || echo "?")
if [ "$_bash_major" != "?" ] && [ "$_bash_major" -lt 4 ] 2>/dev/null; then
  echo "  WARN bash $BASH_VERSION detected (system default on macOS is 3.2)." >&2
  echo "       Foundational scripts work; 8 hooks under scripts/hooks/check-* + scripts/luna/sweep-himmel.sh use mapfile (bash 4+)." >&2
  echo "       Fix: brew install bash  (then ensure /opt/homebrew/bin or /usr/local/bin is on PATH)." >&2
fi

if [ "${#_missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required tools: ${_missing[*]}" >&2
  echo "  Install hints (see docs/setup/new-machine.md for full per-platform table):" >&2
  for _tool in "${_missing[@]}"; do
    case "$_tool" in
      bash)    echo "    bash      — brew install bash (macOS) | already-default (Linux/GitBash)" >&2 ;;
      git)     echo "    git       — https://git-scm.com (includes Git Bash on Windows)" >&2 ;;
      node)    echo "    node      — https://nodejs.org (need v18+; nvm or fnm also works)" >&2 ;;
      npm)     echo "    npm       — bundled with node 18+; if missing, reinstall node" >&2 ;;
      bun)     echo "    bun       — https://bun.sh (runs handover armed-resume, qmd search, the Telegram bridge, obsidian-triage tools)" >&2 ;;
      python3) echo "    python3   — 3.10+; system python on most distros, brew install python on macOS" >&2 ;;
      jq)      echo "    jq        — apt install jq | brew install jq | choco install jq" >&2 ;;
      gh)      echo "    gh        — https://cli.github.com (GitHub CLI v2.x)" >&2 ;;
      mktemp)  echo "    mktemp    — usually bundled with coreutils; reinstall coreutils" >&2 ;;
    esac
  done
  exit 1
fi
echo "  All foundational tools present."
echo ""

# --- Claude Code CLI (the runtime himmel harnesses) — soft check ---
# Not a hard requirement of setup itself (the steps below configure the repo and
# never invoke claude), so a missing claude must not break repo-tooling setup
# (CI, or installing claude afterward). But himmel IS a Claude Code harness —
# you need claude to USE it — so warn loudly with an install hint.
if ! command -v claude >/dev/null 2>&1; then
  echo "  NOTE: 'claude' (Claude Code CLI) not found — himmel is a Claude Code harness;" >&2
  echo "        you need it to use himmel. Install: curl -fsSL https://claude.ai/install.sh | bash" >&2
  echo ""
fi

# --- Wire git to gh's credential helper (proactive auth) ---
# So git fetch/push over HTTPS use gh's token instead of a separate (and
# easily-stale) store like Windows Git Credential Manager. Prevents the
# unattended worktree-create auth failure that _new-worktree.sh now self-heals.
# Idempotent, but requires an authenticated gh host — if run before
# `gh auth login` it fails (handled by the else branch below), since setup-git
# only wires the helper for already-authenticated hosts.
if gh auth setup-git >/dev/null 2>&1; then
  echo "  git wired to gh credential helper (gh auth setup-git)."
else
  echo "  NOTE: 'gh auth setup-git' skipped (gh not ready) — run it after 'gh auth login'." >&2
fi
echo ""

# --- JIRA_PROJECT_KEY verify (HIMMEL-146; gated per HIMMEL-285) ---
# Hard-fail only with --with-jira; default is skip-with-notice so a
# no-Jira adopter completes setup. Logic lives in the sub-script so it
# is hermetic-testable (test-check-jira-key.sh).
echo "[0.4/10] Verifying JIRA_PROJECT_KEY..."
_jira_mode=optional
if [ "$WITH_JIRA" = "1" ]; then _jira_mode=required; fi
if ! bash "$REPO_ROOT/scripts/setup/check-jira-key.sh" "$_jira_mode"; then
  echo "setup: JIRA_PROJECT_KEY check failed (mode=$_jira_mode)" >&2
  exit 1
fi
echo ""

# --- USER_SLUG resolution (HIMMEL-145) ---
# Verify the operator's user slug resolves at setup time so paths in
# handover bucket layout, registry.json, and overnight artifacts line
# up. Fail loud rather than letting downstream scripts pick the wrong
# directory.
echo "[0.5/10] Resolving USER_SLUG..."
# shellcheck source=lib/user-slug.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/user-slug.sh"
if _resolved_slug=$(user_slug_verify); then
  export USER_SLUG="$_resolved_slug"
else
  exit 1
fi
echo ""

# --- pre-commit ---
# PEP 668 (externally-managed-environment, default on Ubuntu 24.04+ and most
# 2025+ distros) blocks `pip install` system-wide. Install via uv first, fall
# back to pipx — both manage isolated venvs, both put `pre-commit` on PATH.
echo "[1/10] Installing pre-commit..."
if command -v pre-commit &>/dev/null; then
  echo "  pre-commit already on PATH — skipping install"
elif command -v uv &>/dev/null; then
  uv tool install pre-commit --quiet
elif command -v pipx &>/dev/null; then
  pipx install pre-commit
else
  echo "ERROR: need uv or pipx to install pre-commit (PEP 668 blocks raw pip)." >&2
  echo "  Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

echo "[2/10] Installing git hooks (pre-commit, pre-push, commit-msg)..."
pre-commit install
pre-commit install --hook-type pre-push
pre-commit install --hook-type commit-msg

echo "[3/10] Installing Jira + Bitbucket CLIs..."
if command -v node &>/dev/null; then
  if [ -d "$REPO_ROOT/scripts/jira/node_modules" ] && [ -f "$REPO_ROOT/scripts/jira/dist/index.js" ]; then
    echo "  jira CLI already built (node_modules + dist present) -- skipping install + build"
    echo "  (force rebuild: rm -rf scripts/jira/node_modules scripts/jira/dist && bash scripts/setup.sh)"
  else
    # `npm link` writes a symlink under the global prefix, which defaults to
    # `/usr/lib/node_modules` on Debian/Ubuntu Node packages and requires root.
    # NPM_CONFIG_PREFIX redirects this single invocation to ~/.local so the
    # symlink lands at ~/.local/bin/jira (PATH already hoisted at top).
    # No persistent ~/.npmrc mutation; one-off env var. `npm install` /
    # `npm run build` are repo-local and don't need the prefix override.
    (cd "$REPO_ROOT/scripts/jira" \
      && npm install --silent \
      && npm run build --silent \
      && NPM_CONFIG_PREFIX="$HOME/.local" npm link)
    echo "  jira CLI installed. Run: jira --help"
  fi
else
  echo "  node not found -- skipping Jira CLI. Install Node 18+ then run:"
  echo "  cd scripts/jira && npm install && npm run build && NPM_CONFIG_PREFIX=\"\$HOME/.local\" npm link"
fi

# Bitbucket Cloud CLI — the forge-bitbucket transport (HIMMEL-326). No `npm
# link`: it's invoked as `node scripts/bitbucket/dist/index.js` (the
# BITBUCKET_CMD default in scripts/lib/forge-bitbucket.sh), so it only needs
# dist/ built. Best-effort — a build failure must not abort setup, since only a
# Bitbucket-forge repo ever invokes it (github operators never do).
if command -v node &>/dev/null && [ -f "$REPO_ROOT/scripts/bitbucket/package.json" ]; then
  if [ -d "$REPO_ROOT/scripts/bitbucket/node_modules" ] && [ -f "$REPO_ROOT/scripts/bitbucket/dist/index.js" ]; then
    echo "  Bitbucket CLI already built (node_modules + dist present) -- skipping."
  elif (cd "$REPO_ROOT/scripts/bitbucket" && npm install --silent && npm run build --silent); then
    echo "  Bitbucket CLI built (used only when the repo origin is a Bitbucket Cloud remote)."
  else
    echo "  WARNING: Bitbucket CLI build failed -- continuing (only needed for a Bitbucket forge)." >&2
  fi
fi

# --- qmd collection ---
echo "[4/10] Registering qmd collection 'himmel'..."
# Neutralize the broken qmd plugin-cache stub first so plain `qmd` works
# inside Claude's Bash tool too (HIMMEL-163). No-op when the plugin is
# absent, already patched, or upstream has shipped a fixed stub.
bash "$REPO_ROOT/scripts/lib/fix-qmd-stub.sh" || echo "  WARNING: fix-qmd-stub failed — continuing." >&2
if has_qmd; then
  # Capture rc from `list` separately. Piping through grep would mask
  # a `list` failure (DB corruption, schema mismatch) as "no match".
  _qmd_list_out=$(qmd_cmd collection list 2>&1)
  _qmd_list_rc=$?
  if [ "$_qmd_list_rc" -ne 0 ]; then
    echo "  WARNING: qmd collection list failed (rc=$_qmd_list_rc) — skipping registration." >&2
    # shellcheck disable=SC2001
    # Per-line indent — parameter expansion doesn't replicate sed's per-line anchor cleanly.
    echo "$_qmd_list_out" | sed 's/^/    /' >&2
  elif echo "$_qmd_list_out" | grep -q '^himmel\b'; then
    echo "  Collection 'himmel' already registered — skipping."
  else
    # Capture rc *before* the `if`: `if ! cmd; then $?` evaluates to 0
    # (the negated-test exit), not cmd's actual rc.
    qmd_cmd collection add "$REPO_ROOT" --name himmel
    _qmd_add_rc=$?
    if [ "$_qmd_add_rc" -ne 0 ]; then
      echo "  WARNING: qmd collection add failed (rc=$_qmd_add_rc) — continuing." >&2
      if [ "$_qmd_add_rc" -eq 127 ]; then
        echo "  (rc=127 means scripts/lib/qmd-bin.sh resolver could not find qmd — install: $(qmd_install_hint))" >&2
      fi
    fi
  fi
  unset _qmd_list_out _qmd_list_rc _qmd_add_rc
else
  echo "  qmd not available — skipping. Install: $(qmd_install_hint)"
fi

# --- .env ---
echo "[5/10] Checking .env..."
if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo "  Created .env from .env.example -- fill in JIRA_API_TOKEN before running: jira list"
  else
    echo "  No .env.example found -- skipping"
  fi
else
  echo "  .env already exists -- skipping"
fi

# --- handover root ---
# Reports where Claude will read/write handover state (per HIMMEL-118
# resolver). For a fresh clone: prints inline path <repo>/handovers
# and the resolver auto-creates the dir on first use. For an external
# HANDOVER_DIR: validates the path exists; warns + continues gate-clean
# if misconfigured so the operator can fix without re-running setup.
#
# Use `doctor` (not `status`) so misconfig exits non-zero and we take
# the WARNING branch — `status` always rc=0 even when HANDOVER_DIR is
# unresolvable.
echo "[6/10] Handover root check..."
if handover_output=$(bash "$REPO_ROOT/scripts/handover-link.sh" doctor 2>&1); then
  while IFS= read -r _line; do echo "  $_line"; done <<< "$handover_output"
else
  echo "  WARNING: handover-link doctor reported misconfiguration:" >&2
  while IFS= read -r _line; do echo "    $_line" >&2; done <<< "$handover_output"
  echo "  Fix by either unsetting HANDOVER_DIR (falls back to <repo>/handovers)" >&2
  echo "  or pointing it at an existing directory before launching Claude Code." >&2
  echo "  Setup continues — re-run handover-link doctor at any time to verify." >&2
fi

echo ""

# --- telegram onboarding (HIMMEL-227) ---
# Scaffold-only: creates the channel dir + bot-token .env template, reports
# pairing/bridge status, prints the operator next-steps. It NEVER writes
# access.json and NEVER starts the bridge (operator-managed — injection
# surface + single-getUpdates-owner rule). Non-fatal: a fresh machine
# legitimately has none of this configured yet.
echo "[7/10] Telegram bridge onboarding..."
if ! bash "$REPO_ROOT/scripts/setup/onboard-telegram.sh"; then
  echo "  WARNING: onboard-telegram reported a problem; setup continues." >&2
fi
echo ""

# --- Claude plugins (HIMMEL-359) ---
# The standalone-himmel path (this script) is what README + getting-started
# point new users at, then tell them to run /handover — so it installs the
# marketplace plugins (handover, triage, obsidian, …), not just the repo
# tooling. User scope (~/.claude, every project); setup.sh has no scope/profile
# flag. Idempotent. Skipped with a notice when claude is not on PATH (the
# soft-check at the top already warned).
echo "[8/10] Installing Claude plugins (user scope)..."
if command -v claude >/dev/null 2>&1; then
  if ! bash "$REPO_ROOT/scripts/machine-setup/install-plugins.sh" --scope user; then
    echo "  WARNING: install-plugins reported a problem; setup continues." >&2
  fi
else
  echo "  Skipped: 'claude' not on PATH (install it, then re-run setup)."
fi
echo ""

# --- statusline (HIMMEL-359) ---
# Wire the himmel statusline into ~/.claude/settings.json via the shared helper.
# Independent of the plugin step (writes settings.json, needs no claude binary);
# idempotent.
echo "[9/10] Wiring statusline (user scope)..."
if ! bash "$REPO_ROOT/scripts/lib/wire-statusline.sh" "$HOME/.claude/settings.json" "$REPO_ROOT"; then
  echo "  WARNING: wire-statusline failed; setup continues." >&2
fi
echo ""

# --- claude-squad (cs) — OPTIONAL (HIMMEL-151) ---
# Opt-in only. Triggered by --with-cs OR interactive prompt (default N).
# Non-interactive shells without the flag skip silently — keeps unattended
# setup runs unchanged for existing operators.
#
# Failure here is non-fatal: cs is optional, so a network hiccup or missing
# brew/apt shouldn't abort the rest of setup. We WARN and continue.
echo "[10/10] OPTIONAL: claude-squad (cs)..."
_install_cs=0
if [ "$WITH_CS" = "1" ]; then
  _install_cs=1
elif [ -t 0 ] && [ -t 1 ]; then
  printf "  Install claude-squad (cs) now? [y/N] "
  read -r _ans
  case "$_ans" in
    [yY]|[yY][eE][sS]) _install_cs=1 ;;
  esac
else
  echo "  Skipped (non-interactive, no --with-cs flag)."
fi

if [ "$_install_cs" = "1" ]; then
  if ! bash "$REPO_ROOT/scripts/setup/install-cs.sh"; then
    echo "  WARNING: claude-squad install failed; setup continues." >&2
    echo "  See docs/setup/claude-squad.md for manual install." >&2
  fi
else
  if [ "$WITH_CS" != "1" ] && { [ -t 0 ] && [ -t 1 ]; }; then
    echo "  Skipped. See docs/setup/claude-squad.md to install later."
  fi
fi
echo ""

echo "Setup complete."
echo ""
echo "NEXT: read docs/getting-started.md (clone-to-first-loop in ~15 min),"
echo "      then start your first loop with /worktree."
echo ""
echo "Quick checks:"
echo "  - Ensure ~/.local/bin is on PATH (uv, jira, pre-commit land there)."
echo "    If 'jira'/'pre-commit' is not found in a fresh shell, add to ~/.bashrc:"
echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "  - pre-commit run --all-files   # all hooks green"
echo "  - qmd status                   # qmd index registered (Windows: scripts/lib/qmd-bin.sh)"
if [ "$WITH_JIRA" = "1" ] || [ -n "${JIRA_PROJECT_KEY:-}" ]; then
  echo "  - Edit .env (set JIRA_API_TOKEN), then: jira list"
else
  echo "  - Jira is optional: set JIRA_* in .env when ready, then: jira list"
fi
echo ""
echo "Everything beyond the core is opt-in (Jira, luna vault, Telegram, hermes) —"
echo "the harness runs without any of them. You stay in control: every guard has an"
echo "off-switch (see docs/getting-started.md and docs/internals/enforcement.md)."
echo ""
echo "Handover state: Mode A (default) lives in <repo>/handovers/, tracked in git."
echo "  Mode B: export HANDOVER_DIR=/path/to/external/handovers in the launching"
echo "  shell to keep it in a separate repo. The resolver fails closed on a bad path."
