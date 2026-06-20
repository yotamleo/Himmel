#!/usr/bin/env bash
# Tests for C4 (HIMMEL-438): luna-brain single-writer git bootstrap (setup.sh
# git-state step) + opt-in vault autosync (vault-autosync.sh). Each phase builds
# a throwaway vault fixture under a temp dir and runs the real scripts against
# it. No real network — pushes target a LOCAL bare remote.
#
# Precondition B (the secret hooks must actually fire): this template uses the
# `pre-commit` framework, so the whole suite SKIPs loud (never false-greens) if
# `pre-commit` is not installed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(cd "$HERE/.." && pwd)"

FAILED=0
pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1 — $2"
  FAILED=$((FAILED + 1))
}
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_ok() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected rc 0, got $2"; fi; }
assert_nz() { if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "expected non-zero rc, got 0"; fi; }
yn() { if [ "$1" -eq 0 ]; then echo yes; else echo no; fi; }

command -v git >/dev/null 2>&1 || {
  echo "SKIP all — git not on PATH"
  exit 0
}
command -v pre-commit >/dev/null 2>&1 || {
  echo "SKIP all — pre-commit not on PATH (Precondition B: secret hooks can't fire)"
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  echo "SKIP all — python3 not on PATH (setup.sh needs it)"
  exit 0
}

# Make commits work without relying on the host's global git identity / slug.
export USER_SLUG="${USER_SLUG:-luna-test}"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-luna-test}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-luna-test@example.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-luna-test}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-luna-test@example.com}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a faithful-enough vault fixture at $1 (NO .git — setup bootstraps it).
make_vault() {
  local v="$1"
  mkdir -p "$v"
  cp "$TEMPLATE_ROOT/.gitignore" "$TEMPLATE_ROOT/.gitattributes" \
    "$TEMPLATE_ROOT/.pre-commit-config.yaml" "$TEMPLATE_ROOT/.gitleaks.toml" \
    "$TEMPLATE_ROOT/.env.example" "$TEMPLATE_ROOT/.vault-template.json" "$v/"
  cp "$TEMPLATE_ROOT/README.md" "$TEMPLATE_ROOT/_CLAUDE.md" \
    "$TEMPLATE_ROOT/index.md" "$TEMPLATE_ROOT/log.md" "$TEMPLATE_ROOT/Welcome.md" "$v/"
  cp -r "$TEMPLATE_ROOT/scripts" "$v/scripts"
  mkdir -p "$v"/00-Inbox "$v"/10-Projects "$v"/20-Areas "$v"/30-Resources \
    "$v"/40-Archive "$v"/50-Journal "$v"/60-Maps "$v"/_Templates
}

# Run the fixture's OWN copy of setup.sh, quietly (so its not-a-repo branch
# roots itself at the fixture via `dirname "$0"`, not the real template dir).
# HANDOVER_DIR points at a temp subdir so Mode A doesn't touch a real root.
run_setup() { (cd "$1" && HANDOVER_DIR="$1/handovers" bash "$1/scripts/setup.sh" >/dev/null 2>&1); }
git_in() { git -C "$1" "${@:2}"; }

# ===========================================================================
# Phase A — gate test: setup bootstraps a non-repo, marker gates on-main commits.
# ===========================================================================
VA="$TMP/gate"
make_vault "$VA"
run_setup "$VA"
assert_ok "A0 setup bootstraps a non-repo cleanly" "$?"
git_in "$VA" rev-parse HEAD >/dev/null 2>&1
assert_ok "A1 bootstrap commit exists (Precondition A: past unborn-HEAD exemption)" "$?"

if [ ! -f "$VA/.git/hooks/pre-commit" ]; then
  echo "SKIP A2-A7 — .git/hooks/pre-commit absent (Precondition B)"
else
  assert_eq "A2 .single-writer created for a local (no-remote) vault" "yes" \
    "$(yn "$([ -f "$VA/.single-writer" ] && echo 0 || echo 1)")"
  assert_eq "A3 .single-writer excluded from git (gitignored)" "0" \
    "$(git_in "$VA" ls-files | grep -c '^\.single-writer$' || true)"

  # Positive control: WITHOUT the marker, an on-main commit must be REJECTED
  # (proves the gate is live, so A5's "allowed" isn't a false-negative).
  mv "$VA/.single-writer" "$VA/.single-writer.bak"
  printf 'note one\n' >"$VA/00-Inbox/n1.md"
  # Stage on its own line + assert success, so A4's "blocked" can only come from
  # the commit gate, never a staging failure (no compound-&& false-green).
  (cd "$VA" && git add 00-Inbox/n1.md) >/dev/null 2>&1
  assert_ok "A4a positive control: staging the change succeeds" "$?"
  (cd "$VA" && git commit -q -m "chore: positive control") >/dev/null 2>&1
  assert_nz "A4 positive control: on-main commit without marker is blocked" "$?"

  # Marker present: a conventional on-main commit (NO --no-verify) must pass ALL
  # template hooks (worktree-isolation, gitleaks, shellcheck, commit-msg).
  mv "$VA/.single-writer.bak" "$VA/.single-writer"
  (cd "$VA" && git commit -q -m "chore: marker present allows commit") >/dev/null 2>&1
  assert_ok "A5 marker present: on-main commit allowed through all hooks" "$?"
  assert_eq "A6 commit count >= 2 (bootstrap + marker commit)" "yes" \
    "$(yn "$([ "$(git_in "$VA" rev-list --count HEAD)" -ge 2 ] && echo 0 || echo 1)")"

  # Remove marker → next on-main commit blocked again.
  rm -f "$VA/.single-writer"
  printf 'note two\n' >"$VA/00-Inbox/n2.md"
  (cd "$VA" && git add 00-Inbox/n2.md && git commit -q -m "chore: blocked again") >/dev/null 2>&1
  assert_nz "A7 marker removed: on-main commit blocked again" "$?"
fi

# ===========================================================================
# Phase B — repo + remote → setup leaves it as-is (no .single-writer imposed).
# ===========================================================================
git init --bare "$TMP/preexist.git" >/dev/null 2>&1
VB="$TMP/remote"
make_vault "$VB"
(cd "$VB" && git init -b main >/dev/null 2>&1 && git remote add origin "$TMP/preexist.git")
run_setup "$VB"
assert_eq "B1 repo+remote: setup does NOT auto-create .single-writer" "no" \
  "$(yn "$([ -f "$VB/.single-writer" ] && echo 0 || echo 1)")"

# ===========================================================================
# Phase C — opt-in autosync (vault-autosync.sh) flag matrix.
# ===========================================================================
VC="$TMP/sync"
make_vault "$VC"
run_setup "$VC"

if [ ! -f "$VC/.git/hooks/pre-commit" ]; then
  echo "SKIP C/D — .git/hooks/pre-commit absent (Precondition B)"
else
  # A dummy per-operator secret (gitignored) + a real content change to sync.
  printf 'TOKEN_VALUE=x\n' >"$VC/.env"
  printf 'autosync content\n' >"$VC/00-Inbox/sync-note.md"
  base=$(git_in "$VC" rev-list --count HEAD)

  (cd "$VC" && LUNA_VAULT_AUTOSYNC='' bash "$VC/scripts/vault-autosync.sh") >/dev/null 2>&1
  assert_ok "C1 flag unset: exit 0 (no commit/push/network)" "$?"
  assert_eq "C1b flag unset: no new commit" "$base" "$(git_in "$VC" rev-list --count HEAD)"

  (cd "$VC" && LUNA_VAULT_AUTOSYNC=1 bash "$VC/scripts/vault-autosync.sh") >/dev/null 2>&1
  assert_ok "C2 flag set + no remote: exit 0 (logged no-op)" "$?"
  assert_eq "C2b no remote: no new commit" "$base" "$(git_in "$VC" rev-list --count HEAD)"
  assert_eq "C2c no remote no-op: working tree still dirty (nothing staged/discarded)" "yes" \
    "$(yn "$([ -n "$(git_in "$VC" status --porcelain)" ] && echo 0 || echo 1)")"

  BARE="$TMP/sync-bare.git"
  git init --bare -b main "$BARE" >/dev/null 2>&1
  (cd "$VC" && git remote add origin "$BARE")
  (cd "$VC" && LUNA_VAULT_AUTOSYNC=1 bash "$VC/scripts/vault-autosync.sh") >/dev/null 2>&1
  assert_ok "C3 flag set + bare remote: exit 0" "$?"
  assert_eq "C3b autosync commit landed" "yes" \
    "$(yn "$([ "$(git_in "$VC" rev-list --count HEAD)" -gt "$base" ] && echo 0 || echo 1)")"
  assert_eq "C3c .env NOT in committed tree (.gitignore layer)" "0" \
    "$(git_in "$VC" ls-tree -r HEAD --name-only | grep -c '^\.env$' || true)"
  assert_eq "C3d .single-writer NOT in committed tree" "0" \
    "$(git_in "$VC" ls-tree -r HEAD --name-only | grep -c single-writer || true)"
  assert_eq "C3e sync-note IS committed" "1" \
    "$(git_in "$VC" ls-tree -r HEAD --name-only | grep -c 'sync-note' || true)"
  git_in "$BARE" rev-parse --verify main >/dev/null 2>&1
  assert_ok "C3f bare remote received the pushed main" "$?"

  # =========================================================================
  # Phase D — secret-block: a planted key trips gitleaks; nothing is committed
  # or pushed. The egress proof: autosync runs THROUGH pre-commit, never
  # --no-verify. (Key assembled at runtime so this test's source stays clean.)
  # =========================================================================
  local_before=$(git_in "$VC" rev-parse HEAD)
  bare_before=$(git_in "$BARE" rev-parse main)
  _akp="AKIA"
  _aks="1234567890ABCDEF"
  printf 'aws_key = "%s%s"\n' "$_akp" "$_aks" >"$VC/30-Resources/leak.md"
  d_out=$(cd "$VC" && LUNA_VAULT_AUTOSYNC=1 bash "$VC/scripts/vault-autosync.sh" 2>&1)
  d_rc=$?
  assert_nz "D1 planted-secret autosync commit is blocked (non-zero)" "$d_rc"
  case "$d_out" in
  *gitleaks* | *Secret* | *secret*) pass "D2 gitleaks (secret hook) is the blocker" ;;
  *) fail "D2 gitleaks (secret hook) is the blocker" "no leak evidence in output" ;;
  esac
  assert_eq "D3 local HEAD unchanged (nothing committed)" "$local_before" "$(git_in "$VC" rev-parse HEAD)"
  assert_eq "D4 bare remote unchanged (nothing pushed)" "$bare_before" "$(git_in "$BARE" rev-parse main)"
  assert_eq "D5 planted key NOT in committed tree" "0" \
    "$(git_in "$VC" ls-tree -r HEAD --name-only | grep -c 'leak\.md' || true)"

  # =========================================================================
  # Phase E — clone-with-remote (no marker, PAST unborn HEAD): autosync must
  # ensure .single-writer itself so its on-main commit clears worktree-isolation
  # (the flag is the operator's opt-in). Simulated by bootstrapping, then
  # removing the marker and adding a remote — exactly "a repo with a remote and
  # no marker" as setup leaves a clone.
  # =========================================================================
  VE="$TMP/clone"
  make_vault "$VE"
  run_setup "$VE"
  if [ -f "$VE/.git/hooks/pre-commit" ]; then
    rm -f "$VE/.single-writer" # a clone keeps no marker (setup leaves it as-is)
    BARE_E="$TMP/clone-bare.git"
    git init --bare -b main "$BARE_E" >/dev/null 2>&1
    (cd "$VE" && git remote add origin "$BARE_E")
    e_base=$(git_in "$VE" rev-list --count HEAD)
    printf 'clone content\n' >"$VE/00-Inbox/clone-note.md"
    (cd "$VE" && LUNA_VAULT_AUTOSYNC=1 bash "$VE/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_ok "E1 clone+remote autosync: exit 0" "$?"
    assert_eq "E2 autosync recreated .single-writer (its opt-in)" "yes" \
      "$(yn "$([ -f "$VE/.single-writer" ] && echo 0 || echo 1)")"
    assert_eq "E3 autosync commit landed past unborn HEAD" "yes" \
      "$(yn "$([ "$(git_in "$VE" rev-list --count HEAD)" -gt "$e_base" ] && echo 0 || echo 1)")"
    git_in "$BARE_E" rev-parse --verify main >/dev/null 2>&1
    assert_ok "E4 clone autosync pushed to remote" "$?"
  fi

  # =========================================================================
  # Phase F — commit succeeds but the push is REJECTED: autosync must exit
  # non-zero (the "thought it synced but didn't" footgun). Remote = a non-bare
  # repo with main checked out (receive.denyCurrentBranch=refuse by default) and
  # an unrelated history, so the push is refused while the commit lands locally.
  # =========================================================================
  VF="$TMP/pushfail"
  make_vault "$VF"
  run_setup "$VF"
  if [ -f "$VF/.git/hooks/pre-commit" ]; then
    SEED="$TMP/seedF"
    git init -b main "$SEED" >/dev/null 2>&1
    (cd "$SEED" && git commit -q --allow-empty -m "seed commit")
    (cd "$VF" && git remote add origin "$SEED")
    f_local_before=$(git_in "$VF" rev-parse HEAD)
    seed_before=$(git_in "$SEED" rev-parse HEAD)
    printf 'push fail content\n' >"$VF/00-Inbox/pf-note.md"
    (cd "$VF" && LUNA_VAULT_AUTOSYNC=1 bash "$VF/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_nz "F1 push rejected: autosync exits non-zero" "$?"
    assert_eq "F2 commit DID land locally (HEAD advanced)" "yes" \
      "$(yn "$([ "$(git_in "$VF" rev-parse HEAD)" != "$f_local_before" ] && echo 0 || echo 1)")"
    assert_eq "F3 remote unchanged (push refused, nothing leaked)" "$seed_before" "$(git_in "$SEED" rev-parse HEAD)"
  fi
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All vault-git C4 tests passed."
else
  echo "$FAILED test(s) failed."
  exit 1
fi
