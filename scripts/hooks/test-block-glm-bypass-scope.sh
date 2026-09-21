#!/usr/bin/env bash
# HIMMEL-3396: HIMMEL_HOOK_INTEGRITY_BYPASS_OK is honoured by the two
# command-text fences of block-glm-external-writes.sh (the HIMMEL-2085 pin-dir
# fence and the HIMMEL-2528 anchor fence) only where HIMMEL-3384 honours it for
# the launcher: session cwd inside CLAUDE_PROJECT_DIR, the session's RECORDED repo
# lists that directory as a LINKED worktree, the hook script resolves inside it,
# and the use is audited. Everything else keeps both fences ON.
#
# The suite builds a real primary checkout + linked worktrees in a temp dir; the
# hook copy inside the worktree is the one under test (the hook must be inside
# the worktree for the bypass to be honoured, exactly as the launcher requires).
#
# Usage: bash scripts/hooks/test-block-glm-bypass-scope.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="$HOOKS_DIR/block-glm-external-writes.sh"

# A console leg's shell exports guard overrides; clear them so a case that means
# "override UNSET" is not flipped (HIMMEL-3092). Cases set what they need.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/override-env.sh"
scrub_override_env

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

# shellcheck source=../lib/canon-path.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/canon-path.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-bypass-scope.XXXXXX")"
T="$(canon_path "$T")" || { echo "setup: canon_path failed for the fixture root" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

git_t() { git -c user.email=t@t -c user.name=t "$@"; }

# ---- fixture: a primary checkout that tracks the hook, one remote, two linked worktrees
PRIMARY="$T/primary"
PINS="$T/pins"
mkdir -p "$PRIMARY/scripts/hooks" "$PINS"
cp "$HOOK_SRC" "$PRIMARY/scripts/hooks/block-glm-external-writes.sh"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" remote add origin https://example.invalid/anchor.git
git_t -C "$PRIMARY" add -A
git_t -C "$PRIMARY" commit -q -m init
WT="$T/wt"
WT2="$T/wt2"
git -C "$PRIMARY" worktree add -q -b bypass-wt "$WT"
git -C "$PRIMARY" worktree add -q -b bypass-wt2 "$WT2"
COMMON="$PRIMARY/.git"
AUDIT="$COMMON/hook-integrity-bypass.jsonl"

# Records as record-hook-integrity.sh writes them: `git_dir` is the recorded repo.
printf '{"git_dir":"%s","pins":{}}\n' "$COMMON" > "$PINS/sess-ok.json"
printf '{"pins":{}}\n' > "$PINS/sess-legacy.json"

PIN_CMD="echo pwned > $PINS/forged.json"
ANCHOR_CMD='git remote set-url origin /tmp/evil.git'

audit_count() { if [ -f "$AUDIT" ]; then wc -l < "$AUDIT" | tr -d ' '; else echo 0; fi; }

# run <cwd> <hook> <project> <session_id> <command> [VAR=val ...] -> prints rc
run() {
  local cwd="$1" hook="$2" project="$3" sid="$4" cmd="$5"; shift 5
  local payload
  payload=$(jq -cn --arg sid "$sid" --arg cmd "$cmd" '{session_id:$sid,tool_name:"Bash",tool_input:{command:$cmd}}')
  (cd "$cwd" && printf '%s' "$payload" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK \
      -u CLAUDE_PID HIMMEL_WORKER=1 HIMMEL_HOOK_INTEGRITY_DIR="$PINS" CLAUDE_PROJECT_DIR="$project" "$@" \
      bash "$hook" >/dev/null 2>&1)
  echo "$?"
}
expect_rc() { # <label> <expected> <actual>
  if [ "$3" = "$2" ]; then ok "$1 (rc=$3)"; else bad "$1 — expected rc=$2, got rc=$3"; fi
}
# A refused bypass is never audited: the count must not move.
expect_refused() { # <label> <cmd> <cwd> <hook> <project> <sid> [VAR=val ...]
  local label="$1" cmd="$2" cwd="$3" hook="$4" project="$5" sid="$6"; shift 6
  local before rc
  before=$(audit_count)
  rc=$(run "$cwd" "$hook" "$project" "$sid" "$cmd" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 "$@")
  if [ "$rc" = 2 ] && [ "$(audit_count)" = "$before" ]; then ok "$label (rc=2, no audit line)"
  else bad "$label — expected rc=2 and no audit line, got rc=$rc audit $before->$(audit_count)"; fi
}

PH="$PRIMARY/scripts/hooks/block-glm-external-writes.sh"
WH="$WT/scripts/hooks/block-glm-external-writes.sh"
WH2="$WT2/scripts/hooks/block-glm-external-writes.sh"

# ---- (a) RED at base: the bypass in the PRIMARY checkout no longer disables either fence
expect_refused "primary checkout: bypass does NOT disable the pin-dir fence" "$PIN_CMD" "$PRIMARY" "$PH" "$PRIMARY" sess-ok
expect_refused "primary checkout: bypass does NOT disable the anchor fence (remote set-url)" "$ANCHOR_CMD" "$PRIMARY" "$PH" "$PRIMARY" sess-ok
expect_refused "primary checkout, GLM lane: bypass does NOT disable the pin-dir fence" "$PIN_CMD" "$PRIMARY" "$PH" "$PRIMARY" sess-ok ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic HIMMEL_WORKER=0

# ---- controls: the fences still work without the bypass, and the bypass still works where intended
expect_rc "control: no bypass, linked worktree — pin-dir fence still fires" 2 "$(run "$WT" "$WH" "$WT" sess-ok "$PIN_CMD")"
expect_rc "control: no bypass, linked worktree — anchor fence still fires" 2 "$(run "$WT" "$WH" "$WT" sess-ok "$ANCHOR_CMD")"
expect_refused "bypass=true (not exactly 1) is not the bypass" "$PIN_CMD" "$WT" "$WH" "$WT" sess-ok HIMMEL_HOOK_INTEGRITY_BYPASS_OK=true

before=$(audit_count)
expect_rc "linked worktree + recorded repo + hook inside it: pin-dir write allowed under the bypass" 0 \
  "$(run "$WT" "$WH" "$WT" sess-ok "$PIN_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"
expect_rc "linked worktree + recorded repo + hook inside it: remote set-url allowed under the bypass" 0 \
  "$(run "$WT" "$WH" "$WT" sess-ok "$ANCHOR_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"
after=$(audit_count)
if [ "$after" = "$((before + 2))" ]; then ok "each honoured call appended exactly one audit line ($before->$after)"
else bad "audit lines: expected $((before + 2)), got $after"; fi
last=$(tail -n 1 "$AUDIT" 2>/dev/null || true)
if [ "$(printf '%s' "$last" | jq -r '.worktree // empty' 2>/dev/null)" = "$WT" ] \
   && [ "$(printf '%s' "$last" | jq -r '.session_id // empty' 2>/dev/null)" = "sess-ok" ] \
   && [ "$(printf '%s' "$last" | jq -r '.cwd // empty' 2>/dev/null)" = "$WT" ] \
   && [ -n "$(printf '%s' "$last" | jq -r '.ts // empty' 2>/dev/null)" ]; then
  ok "audit line is JSON naming worktree, cwd, session_id and ts"
else
  bad "audit line malformed: $last"
fi
expect_rc "cwd in a subdirectory of the worktree is still inside it" 0 \
  "$(mkdir -p "$WT/sub" && run "$WT/sub" "$WH" "$WT" sess-ok "$PIN_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"

# ---- each predicate leg, varied on its own (same env otherwise)
expect_refused "legacy record (no git_dir): refused even in a linked worktree" "$PIN_CMD" "$WT" "$WH" "$WT" sess-legacy
expect_refused "no record for the session: refused" "$PIN_CMD" "$WT" "$WH" "$WT" sess-missing
expect_refused "empty session id: refused" "$PIN_CMD" "$WT" "$WH" "$WT" ""
expect_refused "unsafe session id (path traversal) is never used to find a record: refused" "$PIN_CMD" "$WT" "$WH" "$WT" "../pins/sess-ok"
expect_refused "cwd outside CLAUDE_PROJECT_DIR: refused" "$PIN_CMD" "$T" "$WH" "$WT" sess-ok
expect_refused "hook script outside the worktree (the primary's copy): refused" "$PIN_CMD" "$WT" "$PH" "$WT" sess-ok
expect_refused "CLAUDE_PROJECT_DIR is the primary although cwd is a worktree: refused" "$PIN_CMD" "$WT" "$WH" "$PRIMARY" sess-ok
expect_refused "CLAUDE_PROJECT_DIR unset: refused" "$PIN_CMD" "$WT" "$WH" "" sess-ok

# A decoy repo the record can be pointed at: it does not list $WT2 as a worktree.
DECOY="$T/decoy"
mkdir -p "$DECOY"
git -C "$DECOY" init -q
git_t -C "$DECOY" commit -q --allow-empty -m init
printf '{"git_dir":"%s","pins":{}}\n' "$DECOY/.git" > "$PINS/sess-decoy.json"
expect_refused "record names a repo that does not list the worktree: refused" "$PIN_CMD" "$WT2" "$WH2" "$WT2" sess-decoy

# A worker can rewrite the `.git` pointer file; the predicate reads the RECORDED repo,
# so a pointer rewritten to a decoy is still refused.
cp "$WT2/.git" "$T/wt2.git.orig"
printf 'gitdir: %s\n' "$DECOY/.git" > "$WT2/.git"
expect_refused "rewritten .git pointer (into another repo): refused" "$PIN_CMD" "$WT2" "$WH2" "$WT2" sess-ok
cp "$T/wt2.git.orig" "$WT2/.git"
expect_rc "control: restoring the pointer restores the bypass" 0 \
  "$(run "$WT2" "$WH2" "$WT2" sess-ok "$PIN_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"
rm -f "$WT2/.git"
mkdir "$WT2/.git"
expect_refused "a .git DIRECTORY (not a pointer file) in the worktree: refused" "$PIN_CMD" "$WT2" "$WH2" "$WT2" sess-ok
rmdir "$WT2/.git"
cp "$T/wt2.git.orig" "$WT2/.git"

# The audit sink: an override that cannot be recorded is not granted.
[ -f "$AUDIT" ] || : > "$AUDIT"
mv "$AUDIT" "$T/audit.saved"
ln -s /dev/null "$AUDIT"
before_rc=$(run "$WT" "$WH" "$WT" sess-ok "$PIN_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)
expect_rc "audit sink is a symlink: bypass refused (an unrecordable override is not granted)" 2 "$before_rc"
rm -f "$AUDIT"
mkdir "$AUDIT"
expect_rc "audit sink is a directory: bypass refused" 2 "$(run "$WT" "$WH" "$WT" sess-ok "$PIN_CMD" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"
rmdir "$AUDIT"
mv "$T/audit.saved" "$AUDIT"

# ---- the other shell fences' verdicts are unchanged by a bypass that is honoured
expect_rc "an unrelated worker command is unaffected under an honoured bypass" 0 \
  "$(run "$WT" "$WH" "$WT" sess-ok 'echo hello' HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
