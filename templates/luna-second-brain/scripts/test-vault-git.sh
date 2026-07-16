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

  # D6-D9 — regression test for the local-proxy allowlist entry (HIMMEL-1055):
  # the anchored regex (`^himmel-local-claudex$`) in .gitleaks.toml must let
  # the exact constant through but still block a suffixed near-miss, guarding
  # the anti-bypass rationale documented there.
  rm -f "$VC/30-Resources/leak.md"
  printf 'curl -H "Authorization: Bearer himmel-local-claudex"\n' >"$VC/30-Resources/proxy-token.md"
  (cd "$VC" && LUNA_VAULT_AUTOSYNC=1 bash "$VC/scripts/vault-autosync.sh") >/dev/null 2>&1
  assert_ok "D6 allowlisted local-proxy token: autosync commits (exit 0)" "$?"
  assert_eq "D7 allowlisted token IS in committed tree" "1" \
    "$(git_in "$VC" ls-tree -r HEAD --name-only | grep -c 'proxy-token\.md' || true)"

  d8_before=$(git_in "$VC" rev-parse HEAD)
  printf 'curl -H "Authorization: Bearer himmel-local-claudex-extra"\n' >"$VC/30-Resources/proxy-token-extra.md"
  # Capture the output so the block can be attributed to the SECRET SCANNER, not
  # an unrelated hook/setup failure that also exits non-zero (CR #1239). autosync
  # runs `git commit` without muting the hooks, so gitleaks' own "leaks found"
  # reaches this stream on a real secret block.
  d8_out=$( (cd "$VC" && LUNA_VAULT_AUTOSYNC=1 bash "$VC/scripts/vault-autosync.sh") 2>&1 ); d8_rc=$?
  assert_nz "D8 near-miss token (suffixed) still blocked (non-zero)" "$d8_rc"
  # Attribute the block to a REAL finding, not to any output that merely mentions
  # gitleaks: an unavailable scanner also exits non-zero and prints the word, which
  # would green D8b on a scan that never ran (CR #1243). gitleaks reports findings
  # as `leaks found: <N>` and a clean scan as `no leaks found`, so the count is what
  # separates them. Scanner-unavailable is reported distinctly from "not a finding".
  # Both halves must name gitleaks: a bare "command not found" can come from an
  # unrelated tool in the hook chain, and misreporting that as "scanner missing"
  # would be its own wrong diagnosis.
  case "$d8_out" in
  *gitleaks*"command not found"* | *gitleaks*"executable file not found"* | *"command not found"*gitleaks* | *Executable*gitleaks*not?found*)
    fail "D8b near-miss block attributable to gitleaks (secret scan)" \
      "gitleaks unavailable — the secret scan never ran"
    ;;
  *)
    printf '%s\n' "$d8_out" | grep -qE 'leaks found: *[1-9][0-9]*'
    assert_ok "D8b near-miss block attributable to gitleaks (secret scan)" "$?"
    ;;
  esac
  assert_eq "D9 near-miss token NOT in committed tree" "$d8_before" "$(git_in "$VC" rev-parse HEAD)"

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

  # =========================================================================
  # Phase G — auto-fixer resilience (HIMMEL-501: "autosync blocked so much").
  # G1-G3: a churny .md note (Markdown hard-break = two trailing spaces, no
  #        final newline) is committed UNMODIFIED — pre-commit no longer
  #        rewrites prose, so the unattended commit isn't aborted and the
  #        note's line breaks survive.
  # G4-G7: an allowlisted code/config file a fixer DOES rewrite still lands —
  #        the first commit aborts when the hook modifies it, and autosync
  #        re-stages + retries instead of skipping the push. (Vault notes/sources
  #        are off the fixer allowlist, so a `.toml` is used to force a rewrite.)
  # =========================================================================
  VG="$TMP/fixer"
  make_vault "$VG"
  run_setup "$VG"
  if [ -f "$VG/.git/hooks/pre-commit" ]; then
    BARE_G="$TMP/fixer-bare.git"
    git init --bare -b main "$BARE_G" >/dev/null 2>&1
    (cd "$VG" && git remote add origin "$BARE_G")
    g_base=$(git_in "$VG" rev-list --count HEAD)

    printf 'first line  \nsecond line' >"$VG/00-Inbox/md-fixer.md" # 2 trailing spaces + NO final newline
    cp "$VG/00-Inbox/md-fixer.md" "$TMP/md-fixer.orig"
    (cd "$VG" && LUNA_VAULT_AUTOSYNC=1 bash "$VG/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_ok "G1 autosync with a churny .md note: exit 0 (not blocked)" "$?"
    assert_eq "G2 autosync commit landed" "yes" \
      "$(yn "$([ "$(git_in "$VG" rev-list --count HEAD)" -gt "$g_base" ] && echo 0 || echo 1)")"
    cmp -s "$VG/00-Inbox/md-fixer.md" "$TMP/md-fixer.orig"
    assert_ok "G3 .md left UNMODIFIED by pre-commit (hard-breaks + no-final-newline preserved)" "$?"

    g2_base=$(git_in "$VG" rev-list --count HEAD)
    printf 'key = "value"   \n' >"$VG/00-Inbox/data.toml" # allowlisted → a fixer WILL rewrite it
    (cd "$VG" && LUNA_VAULT_AUTOSYNC=1 bash "$VG/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_ok "G4 autosync recovers from a fixer-modified allowlisted file: exit 0" "$?"
    assert_eq "G5 retry committed after the fixer ran (HEAD advanced)" "yes" \
      "$(yn "$([ "$(git_in "$VG" rev-list --count HEAD)" -gt "$g2_base" ] && echo 0 || echo 1)")"
    assert_eq "G6 data.toml landed in the committed tree" "1" \
      "$(git_in "$VG" ls-tree -r HEAD --name-only | grep -c 'data\.toml' || true)"
    git_in "$BARE_G" rev-parse --verify main >/dev/null 2>&1
    assert_ok "G7 fixer-retry result pushed to remote" "$?"

    # G8-G10: the retry must NOT weaken the egress guard. An allowlisted file
    # with BOTH a fixer defect (trailing whitespace) AND a planted secret: pass 1
    # aborts, the re-stage pass re-runs gitleaks on the same secret, and the
    # commit stays blocked — nothing committed, nothing pushed. (Key assembled
    # at runtime so this test's source stays clean.)
    g8_local_before=$(git_in "$VG" rev-parse HEAD)
    g8_bare_before=$(git_in "$BARE_G" rev-parse main)
    _akp="AKIA"
    _aks="1234567890ABCDEF"
    printf 'note = "leaky data"   \naws_key = "%s%s"\n' "$_akp" "$_aks" >"$VG/30-Resources/leak.toml"
    (cd "$VG" && LUNA_VAULT_AUTOSYNC=1 bash "$VG/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_nz "G8 fixer-defect + secret (allowlisted): autosync blocked through the retry" "$?"
    assert_eq "G9 local HEAD unchanged (retry did not commit the secret)" "$g8_local_before" "$(git_in "$VG" rev-parse HEAD)"
    assert_eq "G10 bare remote unchanged (nothing pushed)" "$g8_bare_before" "$(git_in "$BARE_G" rev-parse main)"

    # =========================================================================
    # Phase H (HIMMEL-615) — a non-ASCII (Hebrew) source-note name must NOT
    # crash the trailing-whitespace fixer (on Windows it prints the path to a
    # cp1252 stdout → UnicodeEncodeError, after rewriting the file → silent
    # whitespace mangling) NOR get rewritten. The allowlist keeps both fixers
    # off non-code content, so the note commits byte-for-byte. The filename is
    # built from octal escapes so the construction line carries no literal
    # non-ASCII (a non-ASCII line that also carries a shellcheck finding can
    # crash the linter — see docs/internals/environment-gotchas.md).
    # =========================================================================
    rm -f "$VG/30-Resources/leak.toml" # drop G8's still-uncommitted planted secret
    h_base=$(git_in "$VG" rev-list --count HEAD)
    heb=$'\327\252\327\231\327\247.txt' # octal escapes decode to Hebrew "tik.txt"
    printf 'verbatim line with trailing space   \nsecond line\n' >"$VG/00-Inbox/$heb"
    cp "$VG/00-Inbox/$heb" "$TMP/heb.orig"
    (cd "$VG" && LUNA_VAULT_AUTOSYNC=1 bash "$VG/scripts/vault-autosync.sh") >/dev/null 2>&1
    assert_ok "H1 autosync with a Hebrew-named .txt: exit 0 (no UnicodeEncodeError)" "$?"
    assert_eq "H2 autosync commit landed" "yes" \
      "$(yn "$([ "$(git_in "$VG" rev-list --count HEAD)" -gt "$h_base" ] && echo 0 || echo 1)")"
    cmp -s "$VG/00-Inbox/$heb" "$TMP/heb.orig"
    assert_ok "H3 Hebrew .txt left UNMODIFIED (no silent whitespace mangling)" "$?"
    (cd "$VG" && git ls-files --error-unmatch -- "00-Inbox/$heb") >/dev/null 2>&1
    assert_ok "H4 Hebrew .txt is tracked in the committed tree" "$?"
  fi
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All vault-git C4 tests passed."
else
  echo "$FAILED test(s) failed."
  exit 1
fi
