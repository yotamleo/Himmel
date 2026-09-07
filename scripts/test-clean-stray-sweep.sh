#!/usr/bin/env bash
# Hermetic test for clean-garden's de-registered worktree husk sweep
# (HIMMEL-970). Temp git repos + direct .claude/worktrees children.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""
TMP_ROOT_UNIX=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT_UNIX" ] && [ -d "$TMP_ROOT_UNIX" ]; then
        rm -rf "$TMP_ROOT_UNIX" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

make_repo() {
    local name="$1" repo
    repo="$TMP_ROOT/$name"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"
        git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m "base"
    git -C "$repo" branch -m main 2>/dev/null || true
    printf '%s\n' "$repo"
}

# Age a husk RECURSIVELY: the sweep's freshness gate treats ANY entry modified
# in the last 24h as in-flight, so fixtures must age the dir and its contents.
touch_old() {
    local entry
    while IFS= read -r entry; do
        touch -d '2 days ago' "$entry" 2>/dev/null || touch -t 202001010000 "$entry"
    done < <(find "$1" -print 2>/dev/null)
}

run_clean() {
    local repo="$1"; shift
    (
        cd "$repo" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

echo "RUN A: old de-registered husk is swept"
REPO_A=$(make_repo repo-a)
HUSK_A="$REPO_A/.claude/worktrees/feat+old-husk"
mkdir -p "$HUSK_A"
printf 'stray\n' > "$HUSK_A/file.txt"
touch_old "$HUSK_A"
out_a=$(run_clean "$REPO_A") || fail "run_clean exited nonzero (repo-a)" "$out_a"
if [ ! -d "$HUSK_A" ]; then
    pass "old husk swept"
else
    fail "old husk still exists" "$out_a"
fi
case "$out_a" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed, 0 refused ("*" reclaimed)"*) pass "old husk summary counts sweep and size" ;;
    *) fail "expected stray-sweep summary for old husk" "$out_a" ;;
esac

echo "RUN B: fresh de-registered husk is skipped"
REPO_B=$(make_repo repo-b)
HUSK_B="$REPO_B/.claude/worktrees/feat+fresh-husk"
mkdir -p "$HUSK_B"
printf 'fresh\n' > "$HUSK_B/file.txt"
out_b=$(run_clean "$REPO_B") || fail "run_clean exited nonzero (repo-b)" "$out_b"
if [ -d "$HUSK_B" ]; then
    pass "fresh husk kept"
else
    fail "fresh husk was swept" "$out_b"
fi
case "$out_b" in
    *"stray-sweep"*) fail "fresh-only run printed stray-sweep summary" "$out_b" ;;
    *) pass "fresh-only run stays quiet" ;;
esac

echo "RUN C: registered worktree under .claude/worktrees is never swept"
REPO_C=$(make_repo repo-c)
mkdir -p "$REPO_C/.claude/worktrees"
WT_C="$REPO_C/.claude/worktrees/feat+registered"
git -C "$REPO_C" worktree add -q "$WT_C" -b feat/registered >/dev/null 2>&1
touch_old "$WT_C"
out_c=$(run_clean "$REPO_C") || fail "run_clean exited nonzero (repo-c)" "$out_c"
if [ -d "$WT_C" ] && git -C "$REPO_C" worktree list --porcelain | grep -Fq "worktree $WT_C"; then
    pass "registered worktree kept"
else
    fail "registered worktree was swept or de-registered" "$out_c"
fi
case "$out_c" in
    *"stray-sweep"*) fail "registered-only run printed stray-sweep summary" "$out_c" ;;
    *) pass "registered-only run stays quiet" ;;
esac

echo "RUN D: dry-run reports would-sweep and removes nothing"
REPO_D=$(make_repo repo-d)
HUSK_D="$REPO_D/.claude/worktrees/feat+dry-husk"
mkdir -p "$HUSK_D"
printf 'dry\n' > "$HUSK_D/file.txt"
touch_old "$HUSK_D"
out_d=$(run_clean "$REPO_D" --dry-run) || fail "run_clean exited nonzero (repo-d)" "$out_d"
# Match by dir basename, not the full $HUSK_D: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_d" in
    *"DRY clean-garden: would sweep stray husk "*"/feat+dry-husk"*) pass "dry-run reports would-sweep" ;;
    *) fail "dry-run did not report would-sweep" "$out_d" ;;
esac
if [ -d "$HUSK_D" ]; then
    pass "dry-run removes nothing"
else
    fail "dry-run removed husk" "$out_d"
fi
case "$out_d" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed, 0 refused ("*" reclaimed)"*) pass "dry-run summary counts would-sweep" ;;
    *) fail "dry-run summary missing" "$out_d" ;;
esac

echo "RUN E: no husks stays quiet"
REPO_E=$(make_repo repo-e)
out_e=$(run_clean "$REPO_E") || fail "run_clean exited nonzero (repo-e)" "$out_e"
case "$out_e" in
    *"stray-sweep"*) fail "no-husk run printed stray-sweep summary" "$out_e" ;;
    *) pass "no-husk run has no stray-sweep summary" ;;
esac

echo "RUN F: old husk dir with a FRESH nested file is skipped (in-flight)"
REPO_F=$(make_repo repo-f)
HUSK_F="$REPO_F/.claude/worktrees/feat+deep-fresh"
mkdir -p "$HUSK_F/nested"
printf 'old\n' > "$HUSK_F/old.txt"
touch_old "$HUSK_F"
printf 'live\n' > "$HUSK_F/nested/live.txt"   # fresh nested write, top dir aged below
touch -d '2 days ago' "$HUSK_F" 2>/dev/null || touch -t 202001010000 "$HUSK_F"
out_f=$(run_clean "$REPO_F") || fail "run_clean exited nonzero (repo-f)" "$out_f"
if [ -d "$HUSK_F" ]; then
    pass "old-dir/fresh-content husk kept"
else
    fail "old-dir/fresh-content husk was swept (freshness gate not recursive)" "$out_f"
fi

echo "RUN G: real dead worktree with uncommitted work is refused, not swept"
REPO_G=$(make_repo repo-g)
# A real `git worktree add` (unlike the plain mkdir'd husks in RUN A-F) runs
# through this machine's global core.hooksPath, which auto-creates/refreshes
# a per-worktree .tokensave/ dir on every git invocation — re-touching files
# inside the fixture DURING clean-garden's own run and defeating touch_old's
# freshness aging. Disable it for this throwaway repo only.
git -C "$REPO_G" config core.hooksPath ""
mkdir -p "$REPO_G/.claude/worktrees"
WT_G="$REPO_G/.claude/worktrees/feat+dead-wt"
git -C "$REPO_G" worktree add -q "$WT_G" -b feat/dead-wt >/dev/null 2>&1
# Stage real uncommitted work BEFORE de-registering: once the admin record's
# gitdir backpointer is gone, `git -C "$WT_G"` can no longer resolve the repo
# at all (fatal: not a git repository) and even staging would fail.
printf 'uncommitted\n' > "$WT_G/dirty.txt"
git -C "$WT_G" add dirty.txt
# De-register the admin record while leaving the worktree dir + its own .git
# FILE in place, so it looks exactly like the husk shape the sweep sees
# (present on disk, invisible to `git worktree list`). Removing the whole
# admin dir (.git/worktrees/feat+dead-wt) breaks the worktree's `.git` file
# pointer outright, so any git command run from inside it — including
# classify_worktree's own status/ls-files calls — fails with "not a git
# repository" (scanfail), not the "tracked" verdict this case needs. Deleting
# only the "gitdir" backpointer file inside the admin dir is what actually
# reproduces "died mid-`git worktree remove`": `git worktree list` no longer
# lists it, while `git -C "$WT_G"` still resolves fine via the worktree's own
# forward-pointing .git file. Do NOT `git worktree prune` — that would also
# clean up other state this test doesn't want to touch.
rm -f "$REPO_G/.git/worktrees/feat+dead-wt/gitdir"
# HIMMEL-2267: `git ... | grep -q` is unsafe under `set -o pipefail` (line 4)
# — grep exits the instant it matches, git gets SIGPIPE, and the PIPELINE's
# exit status goes non-zero even when git's own output DID contain the match.
# That inverts this precondition exactly when it matters: if the worktree is
# still listed (fixture vacuous), the pipeline can still report "no match"
# and this would silently take the wrong branch. Capture then match instead.
wt_list_g=$(git -C "$REPO_G" worktree list --porcelain)
case "$wt_list_g" in
    *"worktree $WT_G"*) fail "2267-precondition: de-register did not remove feat+dead-wt from worktree list (fixture is vacuous)" ;;
    *) pass "2267-precondition: dead worktree is de-registered but still on disk" ;;
esac
touch_old "$WT_G"
out_g=$(run_clean "$REPO_G") || fail "run_clean exited nonzero (repo-g)" "$out_g"
if [ -d "$WT_G" ]; then
    pass "2267-real dead worktree with uncommitted work is refused"
else
    fail "2267-real dead worktree with uncommitted work was swept" "$out_g"
fi
case "$out_g" in
    *"refusing to sweep"*) pass "2267-refusal message printed" ;;
    *) fail "2267-refusal message missing" "$out_g" ;;
esac
# Match by dir basename, not the full $WT_G: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_g" in
    *"refusing to sweep "*"/feat+dead-wt"*) pass "2267-refusal names the dead worktree" ;;
    *) fail "2267-refusal did not name the dead worktree" "$out_g" ;;
esac
case "$out_g" in
    *"clean-garden: stray-sweep — 0 swept, 0 failed, 1 refused ("*" reclaimed)"*) pass "2267-summary reports 1 refused" ;;
    *) fail "2267-summary did not report 1 refused" "$out_g" ;;
esac

echo "RUN H: find failure on the .git presence probe fails CLOSED (refused, not swept)"
# HIMMEL-2267: prove the presence-check distinguishes find FAILING from find
# running and finding nothing. Neither chmod nor icacls can force a real I/O
# failure here portably: icacls is off-limits (himmel's destructive-command
# guardrail refuses permission mutation outright), and chmod is a documented
# no-op under Git-Bash/NTFS, so it can't produce an unreadable directory
# there. Instead this fixture shadows PATH with a `find` wrapper that fails
# ONLY for the exact `-maxdepth 1 -name .git` presence-check call on this husk
# (matched by basename, per the RUN D/RUN G cygpath-mixed-vs-POSIX precedent)
# and delegates every other find call (freshness scan, enumeration, other
# husks) to the real find unchanged — portable because it works identically
# whether or not chmod has real semantics on this platform. Vacuity is
# guarded separately by the `.invoked` marker assertion below, which proves
# the wrapper was actually exercised.
REPO_H=$(make_repo repo-h)
HUSK_H="$REPO_H/.claude/worktrees/feat+find-fail"
mkdir -p "$HUSK_H"
printf 'stray\n' > "$HUSK_H/file.txt"
touch_old "$HUSK_H"

REAL_FIND_H=$(command -v find)
FAKE_BIN_H=$(mktemp -d)
cat > "$FAKE_BIN_H/find" <<EOF
#!/usr/bin/env bash
base="\${1##*/}"
if [ "\$base" = "feat+find-fail" ] && [ "\$2" = "-maxdepth" ] && [ "\$3" = "1" ] && [ "\$4" = "-name" ] && [ "\$5" = ".git" ]; then
    echo x >> "$FAKE_BIN_H/.invoked"
    echo "find: simulated I/O failure (HIMMEL-2267 test fixture)" >&2
    exit 1
fi
exec "$REAL_FIND_H" "\$@"
EOF
chmod +x "$FAKE_BIN_H/find"

out_h=$(PATH="$FAKE_BIN_H:$PATH" run_clean "$REPO_H") || fail "run_clean exited nonzero (repo-h)" "$out_h"
if [ -f "$FAKE_BIN_H/.invoked" ]; then
    invoked_h=1
else
    invoked_h=0
fi
rm -rf "$FAKE_BIN_H" 2>/dev/null || true

if [ "$invoked_h" -eq 1 ]; then
    pass "2267-precondition: find wrapper intercepted the .git presence probe"
else
    fail "2267-precondition: find wrapper never saw the presence-probe call (fixture is vacuous)" "$out_h"
fi

if [ -d "$HUSK_H" ]; then
    pass "2267-husk survives when find itself fails (fail-closed)"
else
    fail "2267-husk was swept despite find failure (fail-open regression)" "$out_h"
fi
case "$out_h" in
    *"presence check could not be completed"*"refusing to sweep"*) pass "2267-refusal took the probefail (presence-check-could-not-complete) arm" ;;
    *) fail "2267-refusal did not take the probefail arm" "$out_h" ;;
esac
# Match by dir basename, not the full $HUSK_H: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_h" in
    *"refusing to sweep "*"/feat+find-fail"*) pass "2267-refusal names the uninspectable husk" ;;
    *) fail "2267-refusal did not name the uninspectable husk" "$out_h" ;;
esac
case "$out_h" in
    *"clean-garden: stray-sweep — 0 swept, 0 failed, 1 refused ("*" reclaimed)"*) pass "2267-summary reports 1 refused" ;;
    *) fail "2267-summary did not report 1 refused" "$out_h" ;;
esac

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
