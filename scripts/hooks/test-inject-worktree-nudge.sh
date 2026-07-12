#!/usr/bin/env bash
# Smoke test for scripts/hooks/inject-worktree-nudge.sh (gh#230).
#
# The hook is a SessionStart advisory that mirrors block-edit-on-main's fire
# conditions: it must emit a <system-reminder> exactly when that guard WOULD
# block the launched checkout, and stay silent otherwise. Cases build real
# throwaway repos under a sandbox and drive the hook with CLAUDE_PROJECT_DIR
# pointed at each.
#
# Exit codes: 0 all pass; 1 at least one fail.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/inject-worktree-nudge.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# has NAME OUT SUBSTR — assert OUT contains SUBSTR.
has() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (missing '$3')" ;;
    esac
}
# empty NAME OUT — assert OUT is empty.
empty() {
    if [ -z "$2" ]; then pass "$1"; else fail "$1 (got output)"; fi
}
# is0 NAME RC — assert RC is 0.
is0() {
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1 (rc=$2)"; fi
}

SANDBOX=$(mktemp -d)

mkrepo() { # $1=path $2=branch  (unborn HEAD on the given branch, no commit)
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}

# run FLAG PROJECT_DIR [EXTRA_ENV...] — run the hook, echo stdout.
run() {
    local flag="$1" pdir="$2"; shift 2
    env HIMMEL_WORKTREE_NUDGE="$flag" CLAUDE_PROJECT_DIR="$pdir" "$@" \
        bash "$HOOK" </dev/null 2>/dev/null
}

# Repos under the sandbox.
mkrepo "$SANDBOX/mainrepo" main
mkrepo "$SANDBOX/masterrepo" master
mkrepo "$SANDBOX/featrepo" feat/x
mkdir -p "$SANDBOX/plain"

# A real linked worktree on a feature branch (needs a commit to add the worktree).
mkrepo "$SANDBOX/wtrepo" main
git -C "$SANDBOX/wtrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SANDBOX/wtrepo" worktree add -q "$SANDBOX/wtrepo/.claude/worktrees/feat+x" -b feat/x >/dev/null 2>&1

# T1: gate OFF (default) on a main repo → silent.
empty "T1 gate off silent" "$(run off "$SANDBOX/mainrepo")"
empty "T1b empty flag silent" "$(run "" "$SANDBOX/mainrepo")"

# T2: gate ON, primary checkout on main → nudge emitted.
out=$(run 1 "$SANDBOX/mainrepo")
has "T2 main emits system-reminder" "$out" "<system-reminder>"
has "T2b main names /worktree" "$out" "/worktree"
has "T2c main/master framing" "$out" "on main/master"

# T3: gate ON, primary checkout on master → nudge emitted.
has "T3 master emits nudge" "$(run 1 "$SANDBOX/masterrepo")" "<system-reminder>"

# T4: gate ON, feature branch in the PRIMARY checkout → nudge emitted (HIMMEL-507).
out=$(run 1 "$SANDBOX/featrepo")
has "T4 primary feature emits nudge" "$out" "<system-reminder>"
has "T4b primary feature framing" "$out" "PRIMARY checkout"

# T5: gate ON, inside a linked worktree (feature branch) → silent (guard allows it).
empty "T5 linked worktree silent" "$(run 1 "$SANDBOX/wtrepo/.claude/worktrees/feat+x")"

# T6: gate ON, not inside any git repo → silent.
empty "T6 non-repo silent" "$(run 1 "$SANDBOX/plain")"

# T7: gate ON, main repo, EDIT_ON_MAIN_OK=1 → silent (guard bypassed).
empty "T7 EDIT_ON_MAIN_OK bypass silent" "$(run 1 "$SANDBOX/mainrepo" EDIT_ON_MAIN_OK=1)"

# T8: gate ON, main repo with a .single-writer marker → silent (opt-out).
mkrepo "$SANDBOX/swrepo" main
touch "$SANDBOX/swrepo/.single-writer"
empty "T8 single-writer marker silent" "$(run 1 "$SANDBOX/swrepo")"

# T9: hook never blocks session start (fail-open) — exit 0 on both paths.
run 1 "$SANDBOX/mainrepo" >/dev/null 2>&1; is0 "T9 emit path exits 0" "$?"
run 1 "$SANDBOX/plain" >/dev/null 2>&1; is0 "T9b silent path exits 0" "$?"

# Clean up the worktree registration before removing the sandbox.
git -C "$SANDBOX/wtrepo" worktree remove --force "$SANDBOX/wtrepo/.claude/worktrees/feat+x" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then echo "FAIL: $FAILED case(s)"; exit 1; fi
echo "OK"; exit 0
