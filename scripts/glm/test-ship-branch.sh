#!/usr/bin/env bash
# Smoke test for scripts/glm/ship-branch.sh (HIMMEL-750). Bash 3.2 safe.
# Hermetic: every repo + bare "origin" lives under mktemp; never touches the
# real $HOME or the real remote.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ship-branch.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# make_repo <dir> : repo with bare origin sibling, main pushed, glm/x committed.
make_repo() {
    local d="$1"
    git -c init.defaultBranch=main init -q "$d"
    (
        cd "$d" || exit 1
        git config user.email t@t.test
        git config user.name tester
        echo base > f.txt
        git add f.txt
        git commit -q -m init
        git init -q --bare "$d.origin.git"
        git remote add origin "$d.origin.git"
        git push -q -u origin main
        git checkout -q -b glm/x
        echo change >> f.txt
        git commit -q -am change
    )
}

write_meta() {
    # $1 = session dir, $2 = verdict string (empty = omit external_cr_verdict)
    mkdir -p "$1"
    if [ -n "$2" ]; then
        printf '{"status":"done","lane":"glm","task_name":"x","external_cr_verdict":"%s"}\n' "$2" > "$1/meta.json"
    else
        printf '{"status":"done","lane":"glm","task_name":"x"}\n' > "$1/meta.json"
    fi
}

# ============================================================================

# --- T1: happy path pushes to origin + clears marker on SHA match -----------
repo="$tmp/r1"; make_repo "$repo"
tip_full="$(cd "$repo" && git rev-parse glm/x)"
sd="$tmp/s1"; write_meta "$sd" "pass (sha=$tip_full; critics=2)"
# Marker with the matching full SHA (as check-cr-before-push.sh writes it).
mkdir -p "$repo/.git/cr-pending/glm"
printf '%s | %s | full\n' "2026-07-07T00:00:00+00:00" "$tip_full" > "$repo/.git/cr-pending/glm/x"
if (cd "$repo" && bash "$SCRIPT" glm/x --session-dir "$sd" >/dev/null 2>&1); then
    ok "T1 happy path exit 0"
else
    bad "T1: happy path should exit 0"
fi
pushed="$(git -C "$repo.origin.git" rev-parse glm/x 2>/dev/null || true)"
if [ "$pushed" = "$tip_full" ]; then ok "T1 branch pushed to origin"; else bad "T1: branch not on origin (got: $pushed)"; fi
if [ ! -f "$repo/.git/cr-pending/glm/x" ]; then ok "T1 marker cleared on SHA match"; else bad "T1: marker should be cleared"; fi

# --- T2: missing verdict -> refuse (exit 2) ----------------------------------
repo="$tmp/r2"; make_repo "$repo"
sd="$tmp/s2"; write_meta "$sd" ""
rc=0; (cd "$repo" && bash "$SCRIPT" glm/x --session-dir "$sd" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "T2 missing verdict refused (exit 2)"; else bad "T2: missing verdict should exit 2 (got $rc)"; fi

# --- T3: verdict SHA != tip -> refuse ----------------------------------------
repo="$tmp/r3"; make_repo "$repo"
sd="$tmp/s3"; write_meta "$sd" "pass (sha=deadbee; critics=2)"
rc=0; (cd "$repo" && bash "$SCRIPT" glm/x --session-dir "$sd" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "T3 verdict-sha != tip refused (exit 2)"; else bad "T3: sha mismatch should exit 2 (got $rc)"; fi

# --- T4: run from a .claude/worktrees/ path -> refuse ------------------------
wt="$tmp/.claude/worktrees/glm+x"
mkdir -p "$wt"
make_repo "$wt"
tips="$(cd "$wt" && git rev-parse --short glm/x)"
sd="$tmp/s4"; write_meta "$sd" "pass (sha=$tips; critics=2)"
rc=0; (cd "$wt" && bash "$SCRIPT" glm/x --session-dir "$sd" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "T4 run-from-worktree refused (exit 2)"; else bad "T4: worktree path should exit 2 (got $rc)"; fi

# --- T5: non-glm branch without --allow-any-branch -> refuse -----------------
repo="$tmp/r5"; make_repo "$repo"
sd="$tmp/s5"; write_meta "$sd" "pass (sha=abcdef0; critics=2)"
rc=0; (cd "$repo" && bash "$SCRIPT" feat/x --session-dir "$sd" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "T5 non-glm branch refused (exit 2)"; else bad "T5: non-glm branch should exit 2 (got $rc)"; fi

# --- T6: marker with WRONG sha is NOT cleared (bind clear to pushed SHA) -----
repo="$tmp/r6"; make_repo "$repo"
tip_full="$(cd "$repo" && git rev-parse glm/x)"
sd="$tmp/s6"; write_meta "$sd" "pass (sha=$tip_full; critics=2)"
mkdir -p "$repo/.git/cr-pending/glm"
printf '%s | %s | full\n' "2026-07-07T00:00:00+00:00" "0000000000000000000000000000000000000000" > "$repo/.git/cr-pending/glm/x"
rc=0; (cd "$repo" && bash "$SCRIPT" glm/x --session-dir "$sd" >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok "T6 push succeeds"; else bad "T6: push should succeed (got $rc)"; fi
if [ -f "$repo/.git/cr-pending/glm/x" ]; then ok "T6 mismatched marker retained"; else bad "T6: mismatched marker should be retained"; fi

if [ "$fail" -eq 0 ]; then echo "PASS test-ship-branch"; else echo "FAILURES in test-ship-branch"; exit 1; fi
