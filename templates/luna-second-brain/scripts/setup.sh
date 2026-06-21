#!/usr/bin/env bash
# New-machine setup for the luna-brain repo.
# Run once after cloning: bash scripts/setup.sh
set -e

trap 'echo "setup interrupted by signal" >&2; exit 130' INT TERM

# --- [0/6] git state ---
# A vault downloaded as a zip (or copied without its .git) is not a repo, yet
# the guardrails (worktree-isolation, secret hooks) and the optional autosync
# all need one. Bootstrap here, and set REPO_ROOT ourselves — a bare
# `git rev-parse --show-toplevel` `set -e`-exits in a non-repo dir.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "$REPO_ROOT"
  if [ -n "$(git remote)" ]; then
    : # repo + remote → a clone/shared repo; leave its branch policy as-is.
  elif [ ! -f "$REPO_ROOT/.single-writer" ]; then
    # repo + no remote → a local-only vault; commits land on main by design.
    touch "$REPO_ROOT/.single-writer"
    echo "[0/6] Local-only vault: created .single-writer (commits/pushes go to main by design)."
  fi
else
  # Not a repo → init one rooted at the script's parent and commit the scaffold.
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$REPO_ROOT"
  git init -b main >/dev/null 2>&1 || { git init >/dev/null 2>&1 && git symbolic-ref HEAD refs/heads/main; }
  # Path-scoped initial commit — NEVER `git add -A`. The protection is the
  # explicit allow-list below (an untracked .env / secret is simply never in the
  # loop), NOT index ordering; `git add .gitignore` is staged first only so the
  # repo's first tracked state already carries the ignore rules.
  git add .gitignore 2>/dev/null || true
  for _p in .env.example .gitattributes .pre-commit-config.yaml .vault-template.json \
            README.md _CLAUDE.md index.md log.md scripts marketplace docs _Templates \
            00-Inbox 10-Projects 20-Areas 30-Resources 40-Archive 50-Journal 60-Maps; do
    [ -e "$REPO_ROOT/$_p" ] && git add "$_p"
  done
  touch "$REPO_ROOT/.single-writer"
  # Report the scaffold commit honestly — on a fresh machine git identity may be
  # unset, which aborts the commit. Don't claim "committed" when HEAD is unborn.
  if git commit -q -m "chore: initial luna-brain scaffold" >/dev/null 2>&1; then
    echo "[0/6] Initialized git repo (main) + committed scaffold; created .single-writer marker."
  else
    echo "[0/6] Initialized git repo (main) + created .single-writer, but the scaffold commit did NOT land" >&2
    echo "      (git user.name/email unset, or a hook blocked it). Set a git identity and run" >&2
    echo "      'git add -A && git commit -m \"initial scaffold\"' before enabling autosync." >&2
  fi
fi

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

echo "==> luna-brain setup"
echo ""

# --- [1/6] foundational tools ---
echo "[1/6] Verifying foundational tools on PATH..."
_missing=()
for _tool in bash git python3; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    _missing+=("$_tool")
  fi
done

if [ "${#_missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required tools: ${_missing[*]}" >&2
  echo "  Install hints:" >&2
  for _tool in "${_missing[@]}"; do
    case "$_tool" in
      bash)    echo "    bash      — brew install bash (macOS) | already-default (Linux/GitBash)" >&2 ;;
      git)     echo "    git       — https://git-scm.com (includes Git Bash on Windows)" >&2 ;;
      python3) echo "    python3   — 3.10+; system python on most distros, brew install python on macOS" >&2 ;;
    esac
  done
  exit 1
fi
echo "  All foundational tools present."
echo ""

# --- [2/6] USER_SLUG resolution ---
echo "[2/6] Resolving USER_SLUG..."
# shellcheck source=lib/user-slug.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/user-slug.sh"
if _resolved_slug=$(user_slug_verify); then
  export USER_SLUG="$_resolved_slug"
else
  exit 1
fi
echo ""

# --- [3/6] pre-commit install ---
echo "[3/6] Installing pre-commit..."
if command -v pre-commit >/dev/null 2>&1; then
  echo "  pre-commit already on PATH — skipping install"
elif command -v uv >/dev/null 2>&1; then
  uv tool install pre-commit --quiet
elif command -v pipx >/dev/null 2>&1; then
  pipx install pre-commit
else
  echo "ERROR: need uv or pipx to install pre-commit (PEP 668 blocks raw pip on most 2025+ distros)." >&2
  echo "  Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

echo "[4/6] Installing git hooks (pre-commit, pre-push, commit-msg)..."
pre-commit install
pre-commit install --hook-type pre-push
pre-commit install --hook-type commit-msg

# --- [5/6] env-template ---
echo "[5/6] Checking .env..."
if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo "  Created .env from .env.example — edit if you want to override defaults."
  else
    echo "  No .env.example found — skipping"
  fi
else
  echo "  .env already exists — skipping"
fi

# --- [6/6] handover root + vault sanity ---
echo "[6/6] Handover root + vault sanity..."
# shellcheck source=lib/handover-path.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/handover-path.sh"
_mode=$(handover_mode)
# Use _ensure so the Mode A inline dir is created on first run; the pure
# `handover_root` returns rc=2 if the dir doesn't exist, which would fire
# the WARNING branch on every fresh clone.
if _root=$(handover_root_ensure); then
  echo "  Handover mode: $_mode  root: $_root"
else
  echo "  WARNING: handover root unresolvable (HANDOVER_DIR set to a missing path?)." >&2
  echo "  Unset HANDOVER_DIR or point it at an existing directory." >&2
fi

_missing_dirs=()
for _d in 00-Inbox 10-Projects 20-Areas 30-Resources 40-Archive 50-Journal 60-Maps _Templates; do
  if [ ! -d "$REPO_ROOT/$_d" ]; then
    _missing_dirs+=("$_d")
  fi
done
if [ "${#_missing_dirs[@]}" -gt 0 ]; then
  echo "  WARNING: vault PARA dirs missing: ${_missing_dirs[*]}" >&2
  echo "  Re-clone or re-create the scaffold before using vault commands." >&2
else
  echo "  Vault PARA dirs present."
fi

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. (optional) Edit .env to override USER_SLUG / HANDOVER_DIR defaults."
echo "  2. Install the Obsidian markdown skill pack from inside Claude Code:"
echo ""
echo "       claude plugin marketplace add kepano/obsidian-skills"
echo "       claude plugin install obsidian@obsidian-skills"
echo ""
echo "     (obsidian is Steph Ango's skill pack, from its own upstream marketplace.)"
echo "     (claude-obsidian now ships via the himmel marketplace — install himmel to get it.)"
echo ""
echo "  3. (optional) Install obsidian-second-brain for PARA capture/daily/project skills."
echo "     This is a 3rd-party install.sh (review before piping to bash):"
echo "       https://github.com/eugeniughelbur/obsidian-second-brain#install"
echo ""
echo "  4. pre-commit run --all-files     # verify all hooks green"
echo ""
echo "Session capture (end-session-wiki):"
echo "  Claude Code can auto-capture each session into THIS vault. Configure it"
echo "  in each CODE repo whose sessions you want captured here — easiest via:"
echo ""
echo "       /end-session-wiki-setup        # run from the code repo; writes the config"
echo ""
echo "  Target precedence (first match wins): per-repo vault_path (abs path) >"
echo "  per-repo vault NAME (distributable; ~/.claude/luna-vaults.json or the"
echo "  ~/Documents/<name> convention) > LUNA_VAULT_PATH env > default ~/Documents/luna."
echo "  This vault's name for BY-NAME routing: $(basename "$REPO_ROOT")"
echo "  Full guide: docs/luna/end-session-wiki.md"
echo ""
echo "Open the vault folder in Obsidian to start using it."
