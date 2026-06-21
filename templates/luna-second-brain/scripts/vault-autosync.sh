#!/usr/bin/env bash
# vault-autosync.sh — OPT-IN auto-commit + push for a luna-brain vault.
#
# OFF by default. A vault's content IS the product, so when enabled this stages
# everything (`git add -A`) and commits THROUGH pre-commit — NEVER `--no-verify`
# — so the vault's gitleaks + secret hooks BLOCK any commit containing an API
# key BEFORE it can be committed or pushed. `.gitignore` (.env, .single-writer,
# …) is the second layer. Push targets the configured remote only.
#
# Enable explicitly (the operator sets the flag; it is never defaulted on):
#   LUNA_VAULT_AUTOSYNC=1 bash scripts/vault-autosync.sh
#
# Behaviour:
#   OFF                  → no commit, no push, no network.
#   ON  + no remote      → logged no-op (autosync = push; nothing to push to).
#   ON  + remote         → git add -A; commit (through pre-commit); push.
set -uo pipefail

log() { echo "[vault-autosync] $*"; }

# --- flag gate (default OFF) -------------------------------------------------
_flag="$(printf '%s' "${LUNA_VAULT_AUTOSYNC:-}" | tr '[:upper:]' '[:lower:]')"
case "$_flag" in
  1 | true | on | yes) ;;
  *)
    log "LUNA_VAULT_AUTOSYNC is off — no commit, no push, no network. (set LUNA_VAULT_AUTOSYNC=1 to enable)"
    exit 0
    ;;
esac

# Resolve repo root (works from anywhere in the vault).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  log "not inside a git repo — nothing to sync."
  exit 0
}
cd "$REPO_ROOT" || exit 1

# ON requires a remote — autosync's whole job is to push. No remote → no-op.
if [ -z "$(git remote)" ]; then
  log "enabled but no remote is configured — nothing to push (no-op)."
  exit 0
fi

# Nothing staged/unstaged/untracked → nothing to do.
if [ -z "$(git status --porcelain)" ]; then
  log "working tree clean — nothing to commit."
  exit 0
fi

# The commit lands on `main` (a vault is single-writer by design); the
# worktree-isolation guard requires the `.single-writer` marker for that.
# Enabling LUNA_VAULT_AUTOSYNC is the operator's explicit opt-in to autosync,
# so ensure the marker exists — a clone WITH a remote won't have one (setup
# leaves clones as-is), and without it this commit would be hard-blocked.
if [ ! -f "$REPO_ROOT/.single-writer" ]; then
  touch "$REPO_ROOT/.single-writer"
  log "created .single-writer (autosync commits to main; the flag is your opt-in)."
fi

# Stage the whole vault — its content is the product.
if ! git add -A; then
  log "git add -A failed — NOT committing or pushing." >&2
  exit 1
fi

# Commit THROUGH pre-commit (NEVER --no-verify): the gitleaks/secret hooks are
# the egress guard. A blocked commit (e.g. an API key slipped in) exits non-zero
# here, and because the push below is gated on this success, nothing leaves.
#
# A pre-commit AUTO-FIXER (e.g. end-of-file-fixer on a stray non-.md file) may
# modify a staged file, which aborts the commit and leaves the tree dirty — at a
# glance indistinguishable from a real block. So retry ONCE: re-stage the fixer's
# changes and commit again. A genuine gitleaks/secret rejection survives both
# passes (gitleaks never auto-fixes, so the second commit fails too) and still
# aborts the push — the egress guard is fully preserved.
_commit() { git commit -q -m "chore: vault autosync"; }
if ! _commit; then
  if [ -z "$(git status --porcelain)" ]; then
    log "nothing to commit after hooks ran — no-op."
    exit 0
  fi
  # A hook auto-fixed files — re-stage and retry once.
  git add -A
  if ! _commit; then
    if [ -z "$(git status --porcelain)" ]; then
      log "nothing to commit after retry — no-op."
      exit 0
    fi
    log "commit BLOCKED by pre-commit (secret detected, or a hook keeps modifying files) — NOT pushing." >&2
    exit 1
  fi
fi
log "committed."

_remote="$(git remote | head -n1)"
_branch="$(git rev-parse --abbrev-ref HEAD)"
if git push "$_remote" "$_branch"; then
  log "pushed to $_remote/$_branch."
else
  log "push to $_remote/$_branch failed." >&2
  exit 1
fi
